#!/usr/bin/env bats
# tests/check-scope-omission.bats — check_scope_omission.sh 회귀 테스트 (T050)
#
# 격리: 각 테스트는 mktemp -d 임시 디렉터리에서 독립 실행.
# git 의존 없이 --changed-files 옵션으로 완전 격리.

SCRIPT_PATH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/check_scope_omission.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ── 1. 명시 산출물 scripts/foo.sh가 changed-files에 있음 → exit 0 ────────────
@test "check_scope_omission: explicit deliverable present in changed-files → exit 0" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## Acceptance Criteria

- [ ] `scripts/foo.sh` 생성 및 실행 가능
EOF
  printf 'scripts/foo.sh\n' > "$TEST_DIR/changed.txt"
  run "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
}

# ── 2. 명시 산출물 tests/bar.bats가 changed-files에 없음 → exit 1 + 진단 ────
@test "check_scope_omission: explicit deliverable absent from changed-files → exit 1 with diagnostic" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## Acceptance Criteria

- [ ] `tests/bar.bats` 6개 이상 PASS
EOF
  printf 'docs/other.md\n' > "$TEST_DIR/changed.txt"
  run "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing deliverable"* ]]
  [[ "$output" == *"tests/bar.bats"* ]]
}

# ── 3. glob docs/decisions/0015-*.md prefix 매칭 → 매칭 시 exit 0 ──────────
@test "check_scope_omission: glob pattern prefix matching → exit 0 when prefix file exists in changed" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## Acceptance Criteria

- [ ] `docs/decisions/0015-*.md` 존재
EOF
  printf 'docs/decisions/0015-foo.md\n' > "$TEST_DIR/changed.txt"
  run "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
}

# ── 4. spec_ref: 참조 경로는 산출물로 오탐하지 않음 → exit 0 ────────────────
@test "check_scope_omission: spec_ref line paths not treated as deliverables → exit 0" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## Acceptance Criteria

- [ ] 동작이 올바르다 (spec_ref: docs/decisions/0014-v0.10-auto-merge-policy.md 참조)
- [ ] `docs/decisions/0014-v0.10-auto-merge-policy.md` 참고하여 구현
EOF
  printf 'scripts/other.sh\n' > "$TEST_DIR/changed.txt"
  run "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
}

# ── 5. 명시 경로 0개 ticket → exit 0 + PARTIAL boundary NOTE ────────────────
@test "check_scope_omission: zero explicit paths → exit 0 with PARTIAL boundary NOTE" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## Acceptance Criteria

- [ ] 동작이 올바르다
- [ ] 테스트가 통과한다
EOF
  printf 'docs/other.md\n' > "$TEST_DIR/changed.txt"
  run "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PARTIAL boundary"* ]]
}

# ── 6. --changed-files 옵션으로 git 없이 격리 테스트 가능 ─────────────────
@test "check_scope_omission: --changed-files option enables git-free isolated test" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## Acceptance Criteria

- [ ] `scripts/check_scope_omission.sh` 존재 + executable
EOF
  printf 'scripts/check_scope_omission.sh\n' > "$TEST_DIR/changed.txt"
  run bash -c "cd '$TEST_DIR' && '$SCRIPT_PATH' '$TEST_DIR/ticket.md' --changed-files '$TEST_DIR/changed.txt'"
  [ "$status" -eq 0 ]
}

# ── 7. non-glob 경로는 changed-files 한 줄과 정확히 일치해야 함 ────────────
@test "check_scope_omission: explicit deliverable requires exact changed-file match" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## Acceptance Criteria

- [ ] `scripts/foo.sh` 생성
EOF
  printf 'scripts/foo.sh.bak\n' > "$TEST_DIR/changed.txt"
  run "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scripts/foo.sh"* ]]
}

# ── 8. acceptance criteria 외부 섹션의 경로는 산출물로 취급하지 않음 ─────────
@test "check_scope_omission: paths outside acceptance criteria section ignored" {
  cat > "$TEST_DIR/ticket.md" <<'EOF'
## 배경

- `scripts/external.sh` 이 파일은 참조용 경로

## Acceptance Criteria

- [ ] 동작이 올바르다

## 참고

- `docs/other/guide.md` 도 참조
EOF
  printf 'docs/other.md\n' > "$TEST_DIR/changed.txt"
  run "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
}
