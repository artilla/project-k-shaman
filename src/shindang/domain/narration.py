# -*- coding: utf-8 -*-
"""오늘신당 narration 서버 조립기 (v1.1 중간안 로직).

목적: LLM이 narration 배열을 출력하지 않고 구조화 필드만 출력하면,
서버가 presynth 풀 + 템플릿으로 narration(TTS 재생 스크립트)을 조립한다.
이 모듈은 그 서버 측 로직의 참조 구현이다.

LLM이 출력해야 하는 최소 필드(조립 입력):
  scores{love,money,work,relationship,condition}, scores_line, summary[2], advice, lucky{color,item}, avoid
서버가 채우는 부분:
  greeting/blessing/ending(presynth 풀), lucky 문장(템플릿)

사용:
  from shindang.domain.narration import compose_narration
  narration = compose_narration(fortune_fields)     # list[ {segment,type,text} ]
CLI:
  이 모듈은 library 전용이며 오프라인 검증은 tools/fortune/을 사용한다.
"""

import re

PRESYNTH = {
    "greeting": "오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.",
    "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    "ending": "내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.",
}
FIELD_KO = {
    "love": "연애운",
    "money": "금전운",
    "work": "일과 학업운",
    "relationship": "인간관계운",
    "condition": "컨디션",
}


def has_batchim(word: str) -> bool:
    """단어 마지막 한글 음절에 받침이 있으면 True."""
    m = re.findall(r"[가-힣]", word)
    if not m:
        return False
    return (ord(m[-1]) - 0xAC00) % 28 != 0


def josa(word: str, with_b: str, without_b: str) -> str:
    return word + (with_b if has_batchim(word) else without_b)


def lucky_line(color: str, item: str) -> str:
    # 행운 색은 ~, 행운 아이템은 ~이에요/예요
    tail = "이에요" if has_batchim(item) else "예요"
    return f"오늘의 행운 색은 {color}, 행운 아이템은 {item}{tail}."


def scores_line(scores: dict) -> str:
    """가장 높은/낮은 영역을 골라 한 문장으로. (템플릿 — 청취 QA 대상)"""
    top = max(scores, key=scores.get)
    low = min(scores, key=scores.get)
    top_ko, low_ko = FIELD_KO[top], FIELD_KO[low]
    hi = scores[top]
    high_phrase = "아주 좋아요" if hi >= 80 else "좋은 편이에요"
    if scores[low] >= 60:
        # 전반적으로 고른 경우
        return f"{josa(top_ko, '이', '가')} {high_phrase[:-2]}고, 전반적으로 고르게 안정적이에요."
    else:
        return (
            f"{josa(top_ko, '이', '가')} {high_phrase[:-2]}고, "
            f"{josa(low_ko, '은', '는')} 조금 낮으니 무리하진 마세요."
        )


def compose_narration(f: dict) -> list:
    """구조화 필드 dict → narration 배열(스키마 narration 형식)."""
    summary_text = " ".join(f["summary"])  # 2문장 연결
    score_text = f.get("scores_line") or scores_line(f["scores"])
    return [
        {"segment": "greeting", "type": "presynth", "text": PRESYNTH["greeting"]},
        {"segment": "summary", "type": "personalized", "text": summary_text},
        {"segment": "scores", "type": "personalized", "text": score_text},
        {"segment": "advice", "type": "personalized", "text": f["advice"]},
        {
            "segment": "lucky",
            "type": "semi",
            "text": lucky_line(f["lucky"]["color"], f["lucky"]["item"]),
        },
        {"segment": "avoid", "type": "personalized", "text": f["avoid"]},
        {"segment": "blessing", "type": "presynth", "text": PRESYNTH["blessing"]},
        {"segment": "ending", "type": "presynth", "text": PRESYNTH["ending"]},
    ]
