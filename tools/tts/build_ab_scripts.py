# -*- coding: utf-8 -*-
"""LLM narration vs 서버 조립 narration A/B 스크립트 + 예측 길이 생성. (API 호출 없음)"""

import json
import re
import statistics
from pathlib import Path

from shindang.domain.narration import compose_narration

ROOT = Path(__file__).resolve().parents[2]
KIT = ROOT / "docs" / "reports" / "tts" / "ab-kit"
REPORT = ROOT / "docs" / "reports" / "tts" / "ab-comparison.md"
samples = json.loads(
    (ROOT / "contracts" / "fortune" / "fortune-samples.v1.json").read_text(
        encoding="utf-8"
    )
)["samples"]

RATE_SLOW, RATE_NORM, PAUSE = 4.5, 5.0, 0.4
TTS_PER_MIN = 0.015


def syl(t):
    return len(re.findall(r"[가-힣]", t))


def dur(narr, rate):
    s = sum(syl(seg["text"]) for seg in narr)
    return s / rate + PAUSE * len(narr)


def fresh_sec(narr, rate):  # cache miss 시 합성분(personalized+semi)
    s = sum(syl(seg["text"]) for seg in narr if seg["type"] != "presynth")
    return s / rate


# 주제별 1개씩 5개 선택
pick, seen = [], set()
for s in samples:
    tp = s["meta"]["topic"]
    if tp not in seen:
        seen.add(tp)
        pick.append(s)
pick = pick[:5]

ab = []
for s in pick:
    llm_narr = s["narration"]
    fields = {k: s[k] for k in ("scores", "summary", "advice", "lucky", "avoid")}
    if "scores_line" in s:
        fields["scores_line"] = s["scores_line"]
    asm_narr = compose_narration(fields)
    ab.append(
        {
            "seed": s["meta"]["seed_hash"],
            "topic": s["meta"]["topic"],
            "A_llm": llm_narr,
            "B_assembled": asm_narr,
            "pred": {
                "A_full_sec_slow": round(dur(llm_narr, RATE_SLOW), 1),
                "B_full_sec_slow": round(dur(asm_narr, RATE_SLOW), 1),
                "A_fresh_sec_slow": round(fresh_sec(llm_narr, RATE_SLOW), 1),
                "B_fresh_sec_slow": round(fresh_sec(asm_narr, RATE_SLOW), 1),
            },
        }
    )

(KIT / "ab_scripts.json").write_text(
    json.dumps({"rate_slow": RATE_SLOW, "items": ab}, ensure_ascii=False, indent=2),
    encoding="utf-8",
)


# markdown 비교 문서
def seg_block(narr):
    return "\n".join(f"  - [{x['type']}] {x['segment']}: {x['text']}" for x in narr)


L = []
L.append("# TTS A/B 비교: LLM narration vs 서버 조립 narration\n")
L.append("생성일: 2026-05-22 / 합성 전 텍스트·예측 비교 (실제 오디오 아님)\n")
L.append(
    "대상: 주제별 1개씩 5개 샘플. A=현재 LLM 출력 narration, B=`narration_composer.py` 서버 조립.\n"
)
L.append(
    "> 핵심: **TTS 오디오 길이/요금은 두 버전이 거의 같다**(아래 예측표). 비용 이득은 LLM **출력 토큰** 절감(별도 리포트)에서 나온다. 이 A/B는 **자연스러움(특히 scores 문장과 연결)** 이 유지되는지를 귀로 판정하기 위한 것이다.\n"
)

# 예측표
L.append("## 예측 오디오 길이 (4.5음절/초 + 세그먼트 0.4초 휴지)\n")
L.append("| 샘플 | 주제 | A 전체(초) | B 전체(초) | A 신규합성(초) | B 신규합성(초) |")
L.append("| --- | --- | --- | --- | --- | --- |")
for x in ab:
    p = x["pred"]
    L.append(
        f"| {x['seed']} | {x['topic']} | {p['A_full_sec_slow']} | {p['B_full_sec_slow']} | {p['A_fresh_sec_slow']} | {p['B_fresh_sec_slow']} |"
    )


# TTS 요금 메모
def cost(sec):
    return sec / 60 * TTS_PER_MIN


aA = statistics.mean(x["pred"]["A_fresh_sec_slow"] for x in ab)
aB = statistics.mean(x["pred"]["B_fresh_sec_slow"] for x in ab)
L.append(
    f"\nTTS 신규합성 평균: A {aA:.1f}초(≈${cost(aA):.4f}/건), B {aB:.1f}초(≈${cost(aB):.4f}/건). 차이는 미미 → **TTS 원가는 사실상 동일**.\n"
)

L.append("## 스크립트 대조 (A=LLM / B=서버 조립)\n")
for x in ab:
    L.append(f"### {x['seed']} ({x['topic']})\n")
    L.append("**A. LLM narration**\n")
    L.append(seg_block(x["A_llm"]))
    L.append("\n**B. 서버 조립 narration**\n")
    L.append(seg_block(x["B_assembled"]))
    L.append("")
    # 차이 강조: scores/lucky 위주
    a_sc = next(s["text"] for s in x["A_llm"] if s["segment"] == "scores")
    b_sc = next(s["text"] for s in x["B_assembled"] if s["segment"] == "scores")
    L.append(f'> scores 차이 → A: "{a_sc}"  /  B: "{b_sc}"\n')

L.append("## 관찰 (텍스트 단계, 합성 전)\n")
L.append("- greeting/blessing/ending/lucky: A·B 동일(풀·템플릿). 차이 없음.\n")
L.append("- summary/advice/avoid: B는 LLM 필드를 그대로 재사용 → 텍스트 동일.\n")
L.append(
    "- **scores 세그먼트만 실질 차이**: A는 LLM이 문맥에 맞춰 쓴 문장, B는 최고/최저 점수 기반 템플릿. 청취 QA의 핵심 포인트.\n"
)
L.append(
    '- 따라서 v1.1 결정은 사실상 "scores 문장을 템플릿으로 대체해도 자연스러운가"로 좁혀진다. 중간안: scores만 LLM이 짧은 한 문장(`scores_line`) 출력(출력 토큰 소폭 증가, 자연스러움 보존).\n'
)

REPORT.parent.mkdir(parents=True, exist_ok=True)
REPORT.write_text("\n".join(L), encoding="utf-8")
print("wrote ab_scripts.json, docs/reports/tts/ab-comparison.md")
print(f"A fresh avg {aA:.1f}s, B fresh avg {aB:.1f}s")
for x in ab:
    print(
        x["topic"],
        x["seed"],
        "A",
        x["pred"]["A_full_sec_slow"],
        "B",
        x["pred"]["B_full_sec_slow"],
    )
