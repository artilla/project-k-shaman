# -*- coding: utf-8 -*-
"""gpt-4o-mini-tts A/B 합성 스크립트 (실행 대기 — API 키 필요).

이 스크립트는 Claude 환경에서 실행되지 않았다. 사용자가 OpenAI API 키를 넣고 직접 실행한다.

준비:
  pip install openai mutagen
  export OPENAI_API_KEY=sk-...

실행:
  # 전체 합성(버전별 1개 mp3, 청취용) + 실측 길이/요금 비교
  python synthesize_tts.py --voice coral
  # 세그먼트 단위까지 합성(presynth 캐시 테스트용)
  python synthesize_tts.py --voice coral --segments
  # 이미 만든 full mp3는 재사용하고, 빠진 세그먼트 mp3만 합성
  python synthesize_tts.py --voice coral --segments-only
  # 다른 음색 후보 비교
  python synthesize_tts.py --voice sage

출력:
  ./out/<seed>_A.mp3, <seed>_B.mp3 (+ --segments 시 세그먼트별 mp3)
  ./out/results.json  (예측 vs 실측 길이, 실측 TTS 요금)

주의:
  - voice 후보(예: coral, sage, alloy 등)는 OpenAI 문서에서 한국어 적합 음색을 확인해 고른다.
  - 합성음 고지(§21) 및 음색 사용 범위는 별도 검토.
"""
import argparse
import json
import os
import sys
from pathlib import Path

TTS_PER_MIN = 0.015          # gpt-4o-mini-tts 공개가(추정)
MODEL = "gpt-4o-mini-tts"
KIT = Path(__file__).parent
OUT = KIT / "out"

def die(msg):
    print(f"[중단] {msg}")
    sys.exit(1)

def mp3_seconds(path: Path) -> float:
    try:
        from mutagen.mp3 import MP3
        return float(MP3(str(path)).info.length)
    except Exception as e:
        print(f"  (길이 측정 실패: {e} — ffprobe 등으로 수동 확인 필요)")
        return 0.0

def synth(client, text: str, voice: str, path: Path):
    # OpenAI Python SDK v1 스트리밍 저장
    with client.audio.speech.with_streaming_response.create(
        model=MODEL, voice=voice, input=text
    ) as resp:
        resp.stream_to_file(str(path))

def synth_if_missing(client, text: str, voice: str, path: Path):
    if not path.exists():
        synth(client, text, voice, path)
    return mp3_seconds(path)

def full_text(narr):  # 세그먼트를 한 호흡으로 연결
    return " ".join(seg["text"] for seg in narr)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="coral", help="gpt-4o-mini-tts 음색 후보")
    ap.add_argument("--segments", action="store_true", help="세그먼트별로도 합성(presynth 캐시 테스트)")
    ap.add_argument("--segments-only", action="store_true", help="기존 full mp3는 재사용하고 세그먼트 mp3만 합성")
    args = ap.parse_args()
    if args.segments_only:
        args.segments = True

    if not os.getenv("OPENAI_API_KEY"):
        die("OPENAI_API_KEY 환경변수가 없다. export 후 다시 실행.")
    try:
        from openai import OpenAI
    except ImportError:
        die("openai 패키지가 없다. pip install openai mutagen")
    client = OpenAI()

    data = json.loads((KIT/"ab_scripts.json").read_text(encoding="utf-8"))
    OUT.mkdir(exist_ok=True)
    results = []
    for item in data["items"]:
        seed = item["seed"]
        for ver, key in (("A", "A_llm"), ("B", "B_assembled")):
            narr = item[key]
            full = full_text(narr)
            fpath = OUT/f"{seed}_{ver}.mp3"
            if args.segments_only:
                print(f"full 재사용: {seed} {ver} ({len(full)}자) -> {fpath.name}", flush=True)
                sec = mp3_seconds(fpath) if fpath.exists() else 0.0
            else:
                print(f"합성: {seed} {ver} ({len(full)}자) -> {fpath.name}", flush=True)
                sec = synth_if_missing(client, full, args.voice, fpath)
            seg_secs = {}
            if args.segments:
                for i, seg in enumerate(narr):
                    sp = OUT/f"{seed}_{ver}_{i}_{seg['segment']}.mp3"
                    seg_sec = synth_if_missing(client, seg["text"], args.voice, sp)
                    seg_secs[seg["segment"]] = {
                        "type": seg["type"],
                        "sec": round(seg_sec, 2),
                        "cost_usd": round(seg_sec/60*TTS_PER_MIN, 5),
                    }
            pred = item["pred"][f"{ver}_full_sec_slow"]
            results.append({
                "seed": seed, "topic": item["topic"], "version": ver, "voice": args.voice,
                "pred_sec_slow": pred, "actual_sec": round(sec,2),
                "actual_cost_usd": round(sec/60*TTS_PER_MIN, 5),
                "segments": seg_secs,
            })
            print(f"  예측 {pred}s / 실측 {sec:.1f}s / 요금 ${sec/60*TTS_PER_MIN:.5f}", flush=True)

    out_name = "segment_results.json" if args.segments_only else "results.json"
    (OUT/out_name).write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    # 요약
    import statistics
    for ver in ("A","B"):
        rs=[r for r in results if r["version"]==ver]
        if rs:
            print(f"[{ver}] 실측 평균 {statistics.mean(r['actual_sec'] for r in rs):.1f}s, "
                  f"평균 요금 ${statistics.mean(r['actual_cost_usd'] for r in rs):.5f}")
    print(f"\n결과: {OUT/out_name} / 청취용 mp3는 {OUT}/ 에 저장됨. listening-qa-rubric.md로 평가.")

if __name__ == "__main__":
    main()
