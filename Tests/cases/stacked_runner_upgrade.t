#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SYSTEM_PATH="$PATH"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$1' to equal '$2'"
}

assert_file_equal() {
  cmp -s "$1" "$2" || fail "expected files to match: $1 and $2"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "expected $1 to contain '$2'"
}

setup_fixture() {
  unset MOCK_BUSY MOCK_TART_JSON MOCK_HELPER_FAIL MOCK_VALIDATE_FAIL \
    MOCK_BOOTSTRAP_FAIL MOCK_BOOTSTRAP_FAIL_ONCE MOCK_BOOTOUT_FAIL MOCK_GIT_FAIL \
    MOCK_MUTATE_PLIST
  TEST_ROOT="$(mktemp -d)"
  HOME="$TEST_ROOT/home"
  INSTALL_DIR="$TEST_ROOT/install"
  MOCK_BIN="$TEST_ROOT/mock-bin"
  SAND_REPO="$TEST_ROOT/sand"
  SETUP_SCRIPT="$TEST_ROOT/setup_sand_macos_runner.sh"
  TARGET="$INSTALL_DIR/sand"
  CONFIG="$TEST_ROOT/sand.yml"
  PLIST="$TEST_ROOT/com.stacked.sand.runner.plist"
  LOG="$TEST_ROOT/sand.log"
  STATE="$TEST_ROOT/launchctl.state"
  MOCK_LOG="$TEST_ROOT/mock.log"
  UPGRADE_STUB="$TEST_ROOT/upgrade-stub"
  REVISION="0123456789abcdef0123456789abcdef01234567"
  mkdir -p "$HOME" "$INSTALL_DIR" "$MOCK_BIN" "$SAND_REPO"

  printf 'old-binary\n' >"$TARGET"
  chmod 755 "$TARGET"
  printf 'old-revision old-sha\n' >"$TARGET.provenance"
  printf 'active-config\n' >"$CONFIG"
  printf 'existing-log\n' >"$LOG"
  cat >"$PLIST" <<EOF_PLIST
<plist>
  <string>$TARGET</string>
  <string>$CONFIG</string>
  <string>$LOG</string>
</plist>
EOF_PLIST
  printf 'loaded\n' >"$STATE"
  : >"$MOCK_LOG"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$UPGRADE_STUB"
  chmod 755 "$UPGRADE_STUB"
  MOCK_PLIST="$PLIST"

  cat >"$SETUP_SCRIPT" <<'EOF_SETUP'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == update-sand && "${2:-}" == --apply ]]
printf 'helper %s %s\n' "$*" >>"$MOCK_LOG"
if [[ "${MOCK_HELPER_FAIL:-0}" == 1 ]]; then
  exit 1
fi
cat >"$SAND_INSTALL_PATH" <<'EOF_BINARY'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == validate ]]; then
  exit "${MOCK_VALIDATE_FAIL:-0}"
fi
EOF_BINARY
chmod 755 "$SAND_INSTALL_PATH"
staged_sha="$(shasum -a 256 "$SAND_INSTALL_PATH")"
staged_sha="${staged_sha%% *}"
printf '%s %s\n' "$SAND_REVISION" "$staged_sha" >"$SAND_INSTALL_PATH.provenance"
EOF_SETUP
  chmod 755 "$SETUP_SCRIPT"

  cat >"$MOCK_BIN/gh" <<'EOF_GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$MOCK_LOG"
if [[ "${MOCK_BUSY:-0}" == 1 ]]; then
  printf '{"total_count":1,"runners":[{"name":"stacked-macos","busy":true,"status":"online"}]}\n'
else
  printf '{"total_count":0,"runners":[]}\n'
fi
EOF_GH

  cat >"$MOCK_BIN/tart" <<'EOF_TART'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${MOCK_TART_JSON:-[]}"
EOF_TART

  cat >"$MOCK_BIN/git" <<'EOF_GIT'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >>"$MOCK_LOG"
if [[ "${MOCK_GIT_FAIL:-0}" == 1 ]]; then
  exit 1
fi
if [[ "$*" == *' fetch '* ]]; then
  exit 0
fi
if [[ "$*" == *' rev-parse '* ]]; then
  printf '%s\n' "$MOCK_REVISION"
  exit 0
fi
exit 1
EOF_GIT

  cat >"$MOCK_BIN/launchctl" <<'EOF_LAUNCHCTL'
#!/usr/bin/env bash
set -euo pipefail
command_name="${1:-}"
shift || true
printf 'launchctl %s %s\n' "$command_name" "$*" >>"$MOCK_LOG"
case "$command_name" in
  print)
    [[ -f "$MOCK_STATE" && "$(<"$MOCK_STATE")" == loaded ]] || exit 1
    printf 'state = running\n'
    ;;
  bootout)
    [[ "${MOCK_BOOTOUT_FAIL:-0}" == 1 ]] && exit 1
    printf 'unloaded\n' >"$MOCK_STATE"
    if [[ "${MOCK_MUTATE_PLIST:-0}" == 1 ]]; then
      printf '<!-- changed while Sand was stopped -->\n' >>"$MOCK_PLIST"
    fi
    ;;
  bootstrap)
    bootstrap_count=0
    if [[ -f "$MOCK_BOOTSTRAP_COUNT" ]]; then
      bootstrap_count="$(<"$MOCK_BOOTSTRAP_COUNT")"
    fi
    bootstrap_count=$((bootstrap_count + 1))
    printf '%s\n' "$bootstrap_count" >"$MOCK_BOOTSTRAP_COUNT"
    if [[ "${MOCK_BOOTSTRAP_FAIL:-0}" == 1 ]]; then
      exit 1
    fi
    if [[ "${MOCK_BOOTSTRAP_FAIL_ONCE:-0}" == 1 && "$bootstrap_count" == 1 ]]; then
      exit 1
    fi
    printf 'loaded\n' >"$MOCK_STATE"
    ;;
  *)
    exit 1
    ;;
esac
EOF_LAUNCHCTL
  chmod 755 "$MOCK_BIN"/*
  export HOME INSTALL_DIR MOCK_BIN SAND_REPO SETUP_SCRIPT TARGET CONFIG PLIST LOG STATE MOCK_LOG REVISION UPGRADE_STUB MOCK_PLIST
  export MOCK_REVISION="$REVISION"
  export MOCK_BOOTSTRAP_COUNT="$TEST_ROOT/bootstrap.count"
  export PATH="$MOCK_BIN:$SYSTEM_PATH"
}

cleanup_fixture() {
  rm -rf "$TEST_ROOT"
}

run_upgrade() {
  env \
    THCYAY_SETUP_SCRIPT="$SETUP_SCRIPT" \
    SAND_SOURCE_DIR="$SAND_REPO" \
    SAND_INSTALL_PATH="$TARGET" \
    SAND_CONFIG_PATH="$CONFIG" \
    SAND_LAUNCH_AGENT_PATH="$PLIST" \
    SAND_LOG_PATH="$LOG" \
    MOCK_STATE="$STATE" \
    MOCK_LOG="$MOCK_LOG" \
    MOCK_REVISION="$REVISION" \
    bash "$ROOT/scripts/stacked-runner-upgrade.sh"
}

test_success_preserves_files() {
  setup_fixture
  cp "$TARGET" "$TEST_ROOT/old-target"
  cp "$TARGET.provenance" "$TEST_ROOT/old-provenance"
  cp "$CONFIG" "$TEST_ROOT/old-config"
  cp "$PLIST" "$TEST_ROOT/old-plist"
  cp "$LOG" "$TEST_ROOT/old-log"
  run_upgrade >/dev/null
  assert_file_contains "$TARGET" 'set -euo pipefail'
  assert_file_contains "$TARGET.provenance" "$REVISION"
  assert_file_equal "$CONFIG" "$TEST_ROOT/old-config"
  assert_file_equal "$PLIST" "$TEST_ROOT/old-plist"
  assert_file_equal "$LOG" "$TEST_ROOT/old-log"
  backup_dir="$(find "$INSTALL_DIR" -maxdepth 1 -type d -name '.sand-upgrade-backup.*' -print -quit)"
  [[ -n "$backup_dir" ]] || fail 'durable rollback backup was not retained'
  assert_file_equal "$backup_dir/sand" "$TEST_ROOT/old-target"
  assert_file_equal "$backup_dir/sand.provenance" "$TEST_ROOT/old-provenance"
  assert_eq "$(<"$STATE")" loaded
  helper_line="$(grep -n '^helper ' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
  bootout_line="$(grep -n '^launchctl bootout ' "$MOCK_LOG" | head -n1 | cut -d: -f1)"
  [[ -n "$helper_line" && -n "$bootout_line" && "$helper_line" -lt "$bootout_line" ]] ||
    fail 'service bootout happened before staged helper completion'
  if grep -Fq kickstart "$MOCK_LOG"; then
    fail 'upgrade must not use forced kickstart'
  fi
  cleanup_fixture
}

test_busy_guard_preserves_files() {
  setup_fixture
  cp "$TARGET" "$TEST_ROOT/old-target"
  cp "$CONFIG" "$TEST_ROOT/old-config"
  MOCK_BUSY=1
  export MOCK_BUSY
  if run_upgrade >/dev/null 2>&1; then
    fail 'busy runner guard unexpectedly succeeded'
  fi
  assert_file_equal "$TARGET" "$TEST_ROOT/old-target"
  assert_file_equal "$CONFIG" "$TEST_ROOT/old-config"
  if grep -Fq 'launchctl bootout' "$MOCK_LOG"; then
    fail 'busy guard must run before service bootout'
  fi
  cleanup_fixture
}

test_vm_guard_preserves_files() {
  setup_fixture
  cp "$TARGET" "$TEST_ROOT/old-target"
  MOCK_TART_JSON='[{"Name":"stacked-macos-2","Running":true,"Source":"OCI"}]'
  export MOCK_TART_JSON
  if run_upgrade >/dev/null 2>&1; then
    fail 'running VM guard unexpectedly succeeded'
  fi
  assert_file_equal "$TARGET" "$TEST_ROOT/old-target"
  if grep -Fq 'launchctl bootout' "$MOCK_LOG"; then
    fail 'VM guard must run before service bootout'
  fi
  cleanup_fixture
}

test_stage_failure_preserves_files() {
  setup_fixture
  cp "$TARGET" "$TEST_ROOT/old-target"
  MOCK_HELPER_FAIL=1
  export MOCK_HELPER_FAIL
  if run_upgrade >/dev/null 2>&1; then
    fail 'staged helper failure unexpectedly succeeded'
  fi
  assert_file_equal "$TARGET" "$TEST_ROOT/old-target"
  if grep -Fq 'launchctl bootout' "$MOCK_LOG"; then
    fail 'stage failure must not stop service'
  fi
  cleanup_fixture
}

test_stage_validation_failure_preserves_files() {
  setup_fixture
  cp "$TARGET" "$TEST_ROOT/old-target"
  MOCK_VALIDATE_FAIL=1
  export MOCK_VALIDATE_FAIL
  if run_upgrade >/dev/null 2>&1; then
    fail 'staged validation failure unexpectedly succeeded'
  fi
  assert_file_equal "$TARGET" "$TEST_ROOT/old-target"
  if grep -Fq 'launchctl bootout' "$MOCK_LOG"; then
    fail 'staged validation failure must not stop service'
  fi
  cleanup_fixture
}

test_bootstrap_failure_rolls_back() {
  setup_fixture
  cp "$TARGET" "$TEST_ROOT/old-target"
  cp "$TARGET.provenance" "$TEST_ROOT/old-provenance"
  cp "$CONFIG" "$TEST_ROOT/old-config"
  cp "$PLIST" "$TEST_ROOT/old-plist"
  cp "$LOG" "$TEST_ROOT/old-log"
  MOCK_BOOTSTRAP_FAIL_ONCE=1
  export MOCK_BOOTSTRAP_FAIL_ONCE
  if run_upgrade >/dev/null 2>&1; then
    fail 'bootstrap failure unexpectedly succeeded'
  fi
  assert_file_equal "$TARGET" "$TEST_ROOT/old-target"
  assert_file_equal "$TARGET.provenance" "$TEST_ROOT/old-provenance"
  assert_file_equal "$CONFIG" "$TEST_ROOT/old-config"
  assert_file_equal "$PLIST" "$TEST_ROOT/old-plist"
  assert_file_equal "$LOG" "$TEST_ROOT/old-log"
  assert_eq "$(<"$STATE")" loaded
  assert_file_contains "$MOCK_LOG" 'launchctl bootstrap'
  cleanup_fixture
}

test_changed_plist_after_bootout_restarts_old_service() {
  setup_fixture
  cp "$TARGET" "$TEST_ROOT/old-target"
  MOCK_MUTATE_PLIST=1
  export MOCK_MUTATE_PLIST
  if run_upgrade >/dev/null 2>&1; then
    fail 'LaunchAgent mutation during stop unexpectedly succeeded'
  fi
  assert_file_equal "$TARGET" "$TEST_ROOT/old-target"
  assert_eq "$(<"$STATE")" loaded
  assert_file_contains "$MOCK_LOG" 'launchctl bootstrap'
  cleanup_fixture
}

test_zsh_dropin_preserves_legacy_cases() {
  setup_fixture
  output="$TEST_ROOT/zsh-output"
  zsh -f -c '
    dropin="$1"
    stacked-runner() { print "legacy:$1"; }
    source "$dropin"
    stacked-runner status
    SAND_UPGRADE_SCRIPT="$UPGRADE_STUB" stacked-runner upgrade
  ' zsh "$ROOT/scripts/stacked-runner.zsh" >"$output"
  assert_file_contains "$output" 'legacy:status'
  cleanup_fixture
}

test_success_preserves_files
test_busy_guard_preserves_files
test_vm_guard_preserves_files
test_stage_failure_preserves_files
test_stage_validation_failure_preserves_files
test_bootstrap_failure_rolls_back
test_changed_plist_after_bootout_restarts_old_service
test_zsh_dropin_preserves_legacy_cases
printf 'stacked runner upgrade tests passed\n'
