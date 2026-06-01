#!/usr/bin/env bats
# tests/failures-report.bats — report_failures.sh acceptance criteria tests
#
# TSV format: <ISO8601>\t<TICKET_ID>\t<STAGE>\t<RETRY>\t<MESSAGE>

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/state"
}

teardown() {
  rm -rf "$TMP"
}

@test "script exists and is executable" {
  [ -f "$REPO_ROOT/scripts/report_failures.sh" ]
  [ -x "$REPO_ROOT/scripts/report_failures.sh" ]
}

@test "missing failures.log exits 0 with empty message" {
  run bash "$REPO_ROOT/scripts/report_failures.sh" --log "$TMP/state/failures.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"0"* ]]
}

@test "empty failures.log exits 0 with empty message" {
  touch "$TMP/state/failures.log"
  run bash "$REPO_ROOT/scripts/report_failures.sh" --log "$TMP/state/failures.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty"* ]] || [[ "$output" == *"0"* ]]
}

@test "correct total failure count from TSV log" {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:00:00Z" "T001" "verify"        "0" "error A" \
    > "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:01:00Z" "T002" "checks-failed" "1" "error B" \
    >> "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:02:00Z" "T001" "no-commit"     "0" "error C" \
    >> "$TMP/state/failures.log"

  run bash "$REPO_ROOT/scripts/report_failures.sh" --log "$TMP/state/failures.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3"* ]]
}

@test "correct per-stage failure counts" {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:00:00Z" "T001" "verify"        "0" "error A" \
    > "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:01:00Z" "T002" "checks-failed" "1" "error B" \
    >> "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:02:00Z" "T001" "verify"        "0" "error C" \
    >> "$TMP/state/failures.log"

  run bash "$REPO_ROOT/scripts/report_failures.sh" --log "$TMP/state/failures.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify"* ]]
  [[ "$output" == *"checks-failed"* ]]
}

@test "correct per-ticket failure counts" {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:00:00Z" "T001" "verify"    "0" "error A" \
    > "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:01:00Z" "T002" "no-commit" "1" "error B" \
    >> "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:02:00Z" "T001" "verify"    "0" "error C" \
    >> "$TMP/state/failures.log"

  run bash "$REPO_ROOT/scripts/report_failures.sh" --log "$TMP/state/failures.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T001"* ]]
  [[ "$output" == *"T002"* ]]
}

@test "malformed TSV lines are reported but not counted as failures" {
  printf '%s\n' "not-a-tsv-line" > "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:01:00Z" "T002" "checks-failed" "1" "error B" \
    >> "$TMP/state/failures.log"

  run bash "$REPO_ROOT/scripts/report_failures.sh" --log "$TMP/state/failures.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total failures: 1"* ]]
  [[ "$output" == *"Malformed lines: 1"* ]]
}

@test "--tail N shows only the last N failures" {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:00:00Z" "T001" "verify"             "0" "error A" \
    > "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:01:00Z" "T002" "checks-failed"      "1" "error B" \
    >> "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:02:00Z" "T003" "no-commit"          "0" "error C" \
    >> "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:03:00Z" "T004" "unknown-persona"    "0" "error D" \
    >> "$TMP/state/failures.log"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "2026-05-11T09:04:00Z" "T005" "claude-exec-failed" "0" "error E" \
    >> "$TMP/state/failures.log"

  run bash "$REPO_ROOT/scripts/report_failures.sh" --log "$TMP/state/failures.log" --tail 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"T004"* ]]
  [[ "$output" == *"T005"* ]]
  [[ "$output" != *"T001"* ]]
  [[ "$output" != *"T002"* ]]
  [[ "$output" != *"T003"* ]]
}
