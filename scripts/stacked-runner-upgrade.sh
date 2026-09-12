#!/usr/bin/env bash
set -euo pipefail

readonly LABEL="com.stacked.sand.runner"
readonly DOMAIN="gui/$(id -u)"
readonly TARGET_SERVICE="${DOMAIN}/${LABEL}"
readonly GITHUB_OFFLINE_TIMEOUT_SECONDS=60
readonly GITHUB_OFFLINE_POLL_SECONDS=1

runner_repo="${THCYAY_RUNNER_REPO:-$HOME/Github/thcyay}"
sand_repo="${SAND_SOURCE_DIR:-$HOME/Github/sand}"
setup_script="${THCYAY_SETUP_SCRIPT:-$runner_repo/scripts/setup_sand_macos_runner.sh}"
target="${SAND_INSTALL_PATH:-$HOME/.local/bin/sand}"
provenance="${target}.provenance"
config_path="${SAND_CONFIG_PATH:-$HOME/.config/sand/sand.yml}"
plist_path="${SAND_LAUNCH_AGENT_PATH:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
log_path="${SAND_LOG_PATH:-$HOME/Library/Logs/sand.log}"
github_organization="${SAND_GITHUB_ORGANIZATION:-Stacked-Technology}"
runner_name="${SAND_RUNNER_NAME:-stacked-macos}"
pool_min="${SAND_POOL_MIN:-0}"
pool_max="${SAND_POOL_MAX:-2}"
poll_interval="${SAND_POOL_POLL_INTERVAL:-30}"
vm_ram_gb="${SAND_VM_RAM_GB:-8}"

stage_dir=""
backup_dir=""
backup_ready=false
service_was_loaded=false
config_sha=""
plist_sha=""

fail() {
  printf 'stacked-runner upgrade: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
    rm -rf "$stage_dir"
  fi
  if [[ "$backup_ready" == false && -n "$backup_dir" && -d "$backup_dir" ]]; then
    rm -rf "$backup_dir"
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_regular_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a regular file: $path"
}

require_directory() {
  local path="$1"
  local label="$2"
  [[ -d "$path" && ! -L "$path" ]] || fail "$label must be a real directory: $path"
}

check_plist_contract() {
  if ! grep -Fq "<string>${target}</string>" "$plist_path"; then
    printf 'stacked-runner upgrade: LaunchAgent does not point at the configured Sand binary\n' >&2
    return 1
  fi
  if ! grep -Fq "<string>${config_path}</string>" "$plist_path"; then
    printf 'stacked-runner upgrade: LaunchAgent does not point at the configured Sand config\n' >&2
    return 1
  fi
  if ! grep -Fq "<string>${log_path}</string>" "$plist_path"; then
    printf 'stacked-runner upgrade: LaunchAgent does not point at the configured Sand log\n' >&2
    return 1
  fi
}

check_static_inputs_unchanged() {
  local current_config_sha
  local current_plist_sha
  current_config_sha="$(shasum -a 256 "$config_path")" || return 1
  current_plist_sha="$(shasum -a 256 "$plist_path")" || return 1
  current_config_sha="${current_config_sha%% *}"
  current_plist_sha="${current_plist_sha%% *}"
  if [[ "$current_config_sha" != "$config_sha" || "$current_plist_sha" != "$plist_sha" ]]; then
    printf 'stacked-runner upgrade: active Sand config or LaunchAgent changed during staging\n' >&2
    return 1
  fi
  check_plist_contract
}

check_tart_idle() {
  local tart_json
  tart_json="$(tart list --format json)" || {
    printf 'stacked-runner upgrade: could not inspect Tart VM state\n' >&2
    return 1
  }
  if ! python3 -c '
import json
import sys

prefix = sys.argv[1]
entries = json.load(sys.stdin)
for entry in entries:
    name = str(entry.get("Name", ""))
    if name == prefix or name.startswith(prefix + "-"):
        if entry.get("Running") is True or entry.get("Source") != "OCI":
            raise SystemExit(1)
' "$runner_name" <<<"$tart_json"; then
    printf 'stacked-runner upgrade: refusing while a Sand Tart VM is running or stale\n' >&2
    return 1
  fi
}

github_runner_count() {
  local state="$1"
  local runner_json
  runner_json="$(gh api \
    "/orgs/$github_organization/actions/runners" \
    --paginate --slurp)" || return 1
  python3 -c '
import json
import sys

prefix = sys.argv[1]
state = sys.argv[2]
payload = json.load(sys.stdin)
pages = payload if isinstance(payload, list) else [payload]
count = 0
for page in pages:
    for runner in page.get("runners", []):
        name = str(runner.get("name", ""))
        if name != prefix and not name.startswith(prefix + "-"):
            continue
        if state == "busy" and runner.get("busy") is True:
            count += 1
        elif state == "registered" and runner.get("status") != "offline":
            count += 1
print(count)
' "$runner_name" "$state" <<<"$runner_json"
}

check_github_idle() {
  local busy_runners
  busy_runners="$(github_runner_count busy)" || {
    printf 'stacked-runner upgrade: could not check GitHub runner occupancy\n' >&2
    return 1
  }
  if [[ "$busy_runners" != "0" ]]; then
    printf 'stacked-runner upgrade: refusing while %s GitHub runner(s) are busy\n' \
      "$busy_runners" >&2
    return 1
  fi
}

wait_github_offline() {
  local deadline=$((SECONDS + GITHUB_OFFLINE_TIMEOUT_SECONDS))
  local online_runners
  while :; do
    online_runners="$(github_runner_count registered)" || {
      printf 'stacked-runner upgrade: could not check GitHub runner registration state\n' >&2
      return 1
    }
    if [[ "$online_runners" == "0" ]]; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      printf 'stacked-runner upgrade: old GitHub runner registration(s) did not go offline\n' >&2
      return 1
    fi
    sleep "$GITHUB_OFFLINE_POLL_SECONDS"
  done
}

check_idle() {
  check_github_idle && check_tart_idle
}

fetch_revision() {
  git -C "$sand_repo" fetch --quiet origin main || fail "could not fetch Sand origin/main"
  local revision
  revision="$(git -C "$sand_repo" rev-parse --verify 'origin/main^{commit}')" ||
    fail "could not resolve Sand origin/main"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "Sand origin/main is not a full commit SHA"
  printf '%s\n' "$revision"
}

stage_build() {
  local revision="$1"
  local stage_binary="$stage_dir/sand"
  env \
    SAND_SOURCE_DIR="$sand_repo" \
    SAND_REVISION="$revision" \
    SAND_INSTALL_PATH="$stage_binary" \
    SAND_BIN="$stage_binary" \
    SAND_VM_RAM_GB="$vm_ram_gb" \
    SAND_POOL_MIN="$pool_min" \
    SAND_POOL_MAX="$pool_max" \
    SAND_POOL_POLL_INTERVAL="$poll_interval" \
    "$setup_script" update-sand --apply ||
    fail "staged Sand build/install failed"
  require_regular_file "$stage_binary" "staged Sand binary"
  [[ -x "$stage_binary" ]] || fail "staged Sand binary is not executable"
  require_regular_file "${stage_binary}.provenance" "staged Sand provenance"
  verify_provenance "$stage_binary" "$revision"
  "$stage_binary" validate --config "$config_path" >/dev/null 2>&1 ||
    fail "staged Sand binary rejected the active config"
}

verify_provenance() {
  local binary="$1"
  local expected_revision="$2"
  local provenance_path="${binary}.provenance"
  local recorded_revision
  local recorded_sha
  local extra
  local actual_sha
  IFS=' ' read -r recorded_revision recorded_sha extra <"$provenance_path" ||
    fail "staged Sand provenance is unreadable"
  [[ -z "${extra:-}" && "$recorded_revision" == "$expected_revision" ]] ||
    fail "staged Sand provenance revision mismatch"
  [[ "$recorded_sha" =~ ^[0-9a-f]{64}$ ]] ||
    fail "staged Sand provenance contains an invalid SHA-256 digest"
  actual_sha="$(shasum -a 256 "$binary")"
  actual_sha="${actual_sha%% *}"
  [[ "$actual_sha" == "$recorded_sha" ]] ||
    fail "staged Sand binary differs from its provenance"
}

make_backup() {
  local install_dir="$1"
  backup_dir="$(mktemp -d "$install_dir/.sand-upgrade-backup.XXXXXX")" ||
    fail "could not create durable rollback backup"
  cp -p "$target" "$backup_dir/sand" || fail "could not back up the Sand binary"
  cp -p "$provenance" "$backup_dir/sand.provenance" ||
    fail "could not back up Sand provenance"
  local target_sha
  local backup_sha
  target_sha="$(shasum -a 256 "$target")"
  backup_sha="$(shasum -a 256 "$backup_dir/sand")"
  target_sha="${target_sha%% *}"
  backup_sha="${backup_sha%% *}"
  [[ "$target_sha" == "$backup_sha" ]] || fail "rollback backup checksum mismatch"
  backup_ready=true
}

restore_backup() {
  [[ -n "$backup_dir" && -d "$backup_dir" ]] || return 1
  local install_dir
  local restore_dir
  install_dir="$(dirname "$target")"
  restore_dir="$(mktemp -d "$install_dir/.sand-upgrade-rollback.XXXXXX")" || return 1
  cp -p "$backup_dir/sand" "$restore_dir/sand" || {
    rm -rf "$restore_dir"
    return 1
  }
  cp -p "$backup_dir/sand.provenance" "$restore_dir/sand.provenance" || {
    rm -rf "$restore_dir"
    return 1
  }
  mv "$restore_dir/sand" "$target" || {
    rm -rf "$restore_dir"
    return 1
  }
  mv "$restore_dir/sand.provenance" "$provenance" || {
    rm -rf "$restore_dir"
    return 1
  }
  rmdir "$restore_dir" 2>/dev/null || true
}

bootstrap_or_rollback() {
  if launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1; then
    launchctl print "$TARGET_SERVICE" >/dev/null 2>&1 || {
      launchctl bootout --wait "$TARGET_SERVICE" >/dev/null 2>&1 || true
      restore_backup || fail "service did not load and binary rollback failed"
      launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 ||
        fail "service did not load; binary restored but service remains stopped"
      fail "service did not load; binary restored"
    }
    return 0
  fi

  launchctl bootout --wait "$TARGET_SERVICE" >/dev/null 2>&1 || true
  restore_backup || fail "service bootstrap failed and binary rollback failed"
  launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 ||
    fail "service bootstrap failed; binary restored but service remains stopped"
  launchctl print "$TARGET_SERVICE" >/dev/null 2>&1 ||
    fail "service bootstrap failed after binary rollback"
  fail "service bootstrap failed; binary restored"
}

require_command gh
require_command git
require_command tart
require_command python3
require_command launchctl
require_command shasum
require_command mktemp
require_command cp
require_command mv
require_directory "$sand_repo" "Sand source repository"
[[ -x "$setup_script" ]] || fail "Sand setup helper is missing or not executable: $setup_script"
require_regular_file "$target" "installed Sand binary"
require_regular_file "$provenance" "installed Sand provenance"
require_regular_file "$config_path" "active Sand config"
require_regular_file "$plist_path" "active Sand LaunchAgent"
check_plist_contract || fail "active Sand LaunchAgent contract validation failed"

install_dir="$(dirname "$target")"
require_directory "$install_dir" "Sand install directory"
[[ "$github_organization" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "SAND_GITHUB_ORGANIZATION contains unsupported characters"
[[ "$runner_name" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "SAND_RUNNER_NAME contains unsupported characters"

config_sha="$(shasum -a 256 "$config_path")"
plist_sha="$(shasum -a 256 "$plist_path")"
config_sha="${config_sha%% *}"
plist_sha="${plist_sha%% *}"

check_idle || fail "initial idle guard failed"
if launchctl print "$TARGET_SERVICE" >/dev/null 2>&1; then
  service_was_loaded=true
fi

stage_dir="$(mktemp -d "$install_dir/.stacked-runner-upgrade.XXXXXX")" ||
  fail "could not create same-filesystem staging directory"
revision="$(fetch_revision)"
stage_build "$revision"

# A build can take long enough for a job to arrive. Recheck immediately before
# stopping Sand so staging never turns into an unplanned service interruption.
check_idle || fail "pre-swap idle guard failed"
check_static_inputs_unchanged || fail "active Sand config or LaunchAgent changed during staging"
make_backup "$install_dir"

if [[ "$service_was_loaded" == true ]]; then
  launchctl bootout --wait "$TARGET_SERVICE" >/dev/null 2>&1 || {
    if launchctl print "$TARGET_SERVICE" >/dev/null 2>&1; then
      fail "could not gracefully stop the Sand LaunchAgent"
    fi
  }
  if ! check_idle; then
    launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 || true
    fail "idle guard failed after stopping Sand"
  fi
  if ! check_static_inputs_unchanged; then
    launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 || true
    fail "active Sand config or LaunchAgent changed while stopping Sand"
  fi
  if ! wait_github_offline; then
    launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 || true
    fail "old GitHub runner registration did not become offline"
  fi
fi

if ! check_static_inputs_unchanged; then
  if [[ "$service_was_loaded" == true ]]; then
    launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 || true
  fi
  fail "active Sand config or LaunchAgent changed before binary swap"
fi

mv "$stage_dir/sand" "$target" || {
  if [[ "$service_was_loaded" == true ]]; then
    launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 || true
  fi
  fail "could not atomically install staged Sand binary"
}
mv "$stage_dir/sand.provenance" "$provenance" || {
  restore_backup || true
  if [[ "$service_was_loaded" == true ]]; then
    launchctl bootstrap "$DOMAIN" "$plist_path" >/dev/null 2>&1 || true
  fi
  fail "could not install staged Sand provenance; rollback attempted"
}

if [[ "$service_was_loaded" == true ]]; then
  bootstrap_or_rollback
fi

printf 'Stacked runner upgraded Sand to %s.\n' "$revision"
printf 'Rollback backup retained at %s.\n' "$backup_dir"
printf 'Existing config, LaunchAgent, and logs were preserved.\n'
