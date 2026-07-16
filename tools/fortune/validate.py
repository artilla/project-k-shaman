#!/usr/bin/env python3
"""fortune-samples.v1.1.json 을 fortune-schema.v1.1.json 에 대해 검증한다."""

import json
import sys
from pathlib import Path

import jsonschema

_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = _ROOT / "contracts" / "fortune" / "fortune-schema.v1.1.json"
SAMPLES_PATH = _ROOT / "contracts" / "fortune" / "fortune-samples.v1.1.json"


def validate_samples(
    schema_path: Path = SCHEMA_PATH, samples_path: Path = SAMPLES_PATH
) -> int:
    """샘플 파일을 스키마로 검증한다. 실패 건수를 반환한다."""
    with schema_path.open() as f:
        schema = json.load(f)
    with samples_path.open() as f:
        data = json.load(f)

    validator = jsonschema.Draft202012Validator(schema)
    failed = 0
    for i, sample in enumerate(data["samples"]):
        errors = list(validator.iter_errors(sample))
        if errors:
            print(f"FAIL sample[{i}]: {errors[0].message}", file=sys.stderr)
            failed += 1
        else:
            print(f"OK   sample[{i}]")
    return failed


def main() -> None:
    failed = validate_samples()
    total = 0
    with SAMPLES_PATH.open() as f:
        total = len(json.load(f)["samples"])
    if failed:
        print(f"\n{failed}/{total} 샘플 실패", file=sys.stderr)
        sys.exit(1)
    print(f"\n전체 {total}개 샘플 통과")


if __name__ == "__main__":
    main()
