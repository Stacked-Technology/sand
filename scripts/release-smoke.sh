#!/usr/bin/env bash
set -euo pipefail

# Run one manually dispatched, uniquely labelled Sand lifecycle smoke. The
# caller supplies a restricted JSON disposable GitHub-provisioner config and a
# candidate Sand binary; this script never falls back to the production config.

fail() {
  printf 'release-smoke: %s\n' "$*" >&2
  exit 1
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a regular file: $path"
}

require_env SAND_SMOKE_BIN
require_env SAND_SMOKE_CONFIG
require_env SAND_SMOKE_RUNNER_NAME
require_env SAND_SMOKE_RUNNER_LABEL
require_env SAND_SMOKE_SOURCE_REVISION
require_env SAND_SMOKE_OUTPUT

require_file "$SAND_SMOKE_BIN" "Sand binary"
[[ -x "$SAND_SMOKE_BIN" ]] || fail "Sand binary is not executable: $SAND_SMOKE_BIN"
require_file "$SAND_SMOKE_CONFIG" "smoke config"
grep -Fq "stacked-macos" "$SAND_SMOKE_CONFIG" &&
  fail "production runner identifier is forbidden in the smoke config"
grep -Fq "sand-production" "$SAND_SMOKE_CONFIG" &&
  fail "production runner label is forbidden in the smoke config"

[[ "$SAND_SMOKE_RUNNER_NAME" != "stacked-macos" ]] || fail "production runner name is forbidden"
[[ "$SAND_SMOKE_RUNNER_NAME" != stacked-macos-* ]] || fail "production runner name prefix is forbidden"
[[ "$SAND_SMOKE_RUNNER_NAME" =~ ^sand-release-smoke-[A-Za-z0-9-]+$ ]] ||
  fail "runner name must use sand-release-smoke- prefix"
[[ "$SAND_SMOKE_RUNNER_LABEL" =~ ^sand-release-smoke-[a-z0-9-]+$ ]] ||
  fail "runner label must use sand-release-smoke- prefix"
[[ "$SAND_SMOKE_SOURCE_REVISION" =~ ^[0-9a-f]{7,64}$ ]] ||
  fail "source revision must be a hexadecimal commit id"

readonly smoke_repo="${SAND_SMOKE_REPO:-Stacked-Technology/sand}"
readonly smoke_ref="${SAND_SMOKE_REF:-main}"
readonly smoke_workflow="${SAND_SMOKE_WORKFLOW:-sand-runner-smoke.yml}"
readonly smoke_org="${SAND_SMOKE_ORG:-Stacked-Technology}"
readonly smoke_timeout="${SAND_SMOKE_TIMEOUT_SEC:-1200}"
[[ "$smoke_org" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,37}$ ]] ||
  fail "invalid smoke organization"
[[ "$smoke_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "invalid smoke repository"
[[ "${smoke_repo%%/*}" == "$smoke_org" ]] ||
  fail "smoke repository owner must match smoke organization"
[[ "$smoke_timeout" =~ ^[0-9]+$ && "$smoke_timeout" -gt 0 ]] || fail "invalid timeout"

command -v gh >/dev/null 2>&1 || fail "missing required command: gh"
command -v tart >/dev/null 2>&1 || fail "missing required command: tart"
command -v python3 >/dev/null 2>&1 || fail "missing required command: python3"
command -v shasum >/dev/null 2>&1 || fail "missing required command: shasum"

image_sha256="$(python3 - "$SAND_SMOKE_CONFIG" "$SAND_SMOKE_RUNNER_NAME" "$SAND_SMOKE_RUNNER_LABEL" "$smoke_org" <<'PY'
import hashlib
import json
import re
import sys

config_path, requested_name, requested_label, expected_org = sys.argv[1:]
try:
    with open(config_path, encoding="utf-8") as handle:
        config = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"smoke config must be strict JSON: {error}")

if not isinstance(config, dict):
    raise SystemExit("smoke config must be a JSON object")
runners = config.get("runners")
if not isinstance(runners, list) or len(runners) != 1:
    raise SystemExit("smoke config must define exactly one runner")
runner = runners[0]
if not isinstance(runner, dict):
    raise SystemExit("smoke config runner must be a JSON object")
if runner.get("name") != requested_name:
    raise SystemExit("smoke config VM name must exactly match the requested runner")
if type(runner.get("stopAfter")) is not int or runner["stopAfter"] != 1:
    raise SystemExit("smoke config must set stopAfter to 1")
if "pool" in runner:
    raise SystemExit("smoke config must not define a runner pool")

vm = runner.get("vm")
if not isinstance(vm, dict) or any(key in vm for key in ("mounts", "cache")):
    raise SystemExit("smoke config must omit VM mounts and shared cache")
source = vm.get("source")
if not isinstance(source, dict) or source.get("type") != "oci":
    raise SystemExit("smoke config must use one pinned OCI image")
image = source.get("image")
if not isinstance(image, str) or not re.fullmatch(r".+@sha256:[0-9a-f]{64}", image):
    raise SystemExit("smoke config image must be pinned by a sha256 digest")

provisioner = runner.get("provisioner")
if not isinstance(provisioner, dict) or provisioner.get("type") != "github":
    raise SystemExit("smoke config must use a GitHub provisioner")
github = provisioner.get("config")
if not isinstance(github, dict):
    raise SystemExit("smoke config must include GitHub provisioner config")
if "repository" in github:
    raise SystemExit("smoke config must use organization-level GitHub registration")
if github.get("runnerName") != requested_name:
    raise SystemExit("smoke config provisioner runnerName must exactly match the requested runner")
if github.get("ephemeral") is not True:
    raise SystemExit("smoke config must explicitly enable an ephemeral GitHub runner")
if github.get("extraLabels") != ["sand-release-smoke", requested_label]:
    raise SystemExit("smoke config extraLabels must exactly match the static and unique smoke labels")
if type(github.get("appId")) is not int or github["appId"] <= 0:
    raise SystemExit("smoke config GitHub appId must be positive")
if github.get("organization") != expected_org:
    raise SystemExit("smoke config GitHub organization must exactly match smoke organization")
if not isinstance(github.get("privateKeyPath"), str) or not github["privateKeyPath"]:
    raise SystemExit("smoke config GitHub privateKeyPath must be non-empty")

print(hashlib.sha256(image.encode("utf-8")).hexdigest())
PY
)" || fail "invalid structured smoke config"

readonly smoke_id="${SAND_SMOKE_ID:-sand-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ "$smoke_id" =~ ^sand-smoke-[A-Za-z0-9._-]+$ ]] || fail "invalid smoke id"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/sand-release-smoke.XXXXXX")"
sand_pid=""
log_path="$workdir/sand.log"
run_id=""
dispatch_epoch=""
preserve_resources=false
sand_started=false
binary_sha256="$(shasum -a 256 "$SAND_SMOKE_BIN" | awk '{print $1}')"
config_sha256="$(shasum -a 256 "$SAND_SMOKE_CONFIG" | awk '{print $1}')"

cancel_workflow_run() {
  local candidate="$1"
  local deadline run_status
  [[ -n "$candidate" ]] || return 1
  gh run cancel "$candidate" --repo "$smoke_repo" >/dev/null 2>&1 || true
  deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    run_status="$(gh run view "$candidate" --repo "$smoke_repo" --json status --jq '.status' 2>/dev/null || true)"
    if [[ "$run_status" == completed ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT INT TERM
  if [[ "$status" -ne 0 ]]; then
    if [[ -z "$run_id" && -n "$dispatch_epoch" ]]; then
      run_id="$(find_run_id "$dispatch_epoch" || true)"
    fi
    if [[ -z "$run_id" ]]; then
      preserve_resources=true
      printf 'release-smoke: could not identify the dispatched workflow run; preserving the isolated runner for manual cancellation\n' >&2
    elif ! cancel_workflow_run "$run_id"; then
      preserve_resources=true
      printf 'release-smoke: could not confirm cancellation for workflow run %s; preserving the isolated runner\n' "$run_id" >&2
    fi
  fi
  if [[ "$preserve_resources" == false && "$sand_started" == true ]]; then
    if [[ -n "$sand_pid" ]] && kill -0 "$sand_pid" >/dev/null 2>&1; then
      kill -TERM "$sand_pid" >/dev/null 2>&1 || true
      local reap_deadline=$((SECONDS + 10))
      while kill -0 "$sand_pid" >/dev/null 2>&1 && (( SECONDS < reap_deadline )); do
        sleep 1
      done
      if kill -0 "$sand_pid" >/dev/null 2>&1; then
        preserve_resources=true
        cleanup_status=1
        printf 'release-smoke: Sand did not exit after TERM; preserving the isolated runner and diagnostics at %s\n' "$workdir" >&2
      else
        wait "$sand_pid" >/dev/null 2>&1 || true
      fi
    fi
    if [[ "$preserve_resources" == true ]]; then
      :
    elif ! "$SAND_SMOKE_BIN" destroy --config "$SAND_SMOKE_CONFIG" >"$workdir/destroy.stdout" 2>"$workdir/destroy.stderr"; then
      preserve_resources=true
      cleanup_status=1
      printf 'release-smoke: destroy failed; preserving the isolated runner and diagnostics at %s\n' "$workdir" >&2
    elif ! confirm_vm_absent; then
      preserve_resources=true
      cleanup_status=1
      printf 'release-smoke: could not confirm isolated runner teardown; preserving resources and diagnostics at %s\n' "$workdir" >&2
    fi
  fi
  if [[ "$cleanup_status" -ne 0 ]]; then
    status=1
  fi
  if [[ "$status" -ne 0 ]]; then
    if [[ "$preserve_resources" == true ]]; then
      printf 'release-smoke: failed; cancel the unique run and destroy %s before retrying\n' "$SAND_SMOKE_RUNNER_NAME" >&2
      printf 'release-smoke: diagnostics remain at %s\n' "$workdir" >&2
    else
      printf 'release-smoke: failed; sanitized artifacts are at %s\n' "$SAND_SMOKE_OUTPUT" >&2
    fi
  fi
  if [[ "$preserve_resources" == false ]]; then
    rm -rf "$workdir"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

verify_runner_absent() {
  local registered
  registered="$(gh api \
    "/orgs/$smoke_org/actions/runners" \
    --paginate \
    --jq '.runners[] | select(.name == "'"$SAND_SMOKE_RUNNER_NAME"'" or any(.labels[]?; .name == "'"$SAND_SMOKE_RUNNER_LABEL"'")) | .name' \
    2>"$workdir/runner-preflight.err")" ||
    fail "could not verify that the isolated GitHub runner name and label are unused"
  [[ -z "$registered" ]] || fail "isolated GitHub runner name or label is already registered"
  tart list --format json >"$workdir/tart-preflight.json" ||
    fail "could not verify that the isolated Tart VM name is unused"
  if ! python3 - "$SAND_SMOKE_RUNNER_NAME" "$workdir/tart-preflight.json" <<'PY'
import json
import sys

runner_name = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    entries = json.load(handle)
if any(entry.get("Name") == runner_name for entry in entries):
    raise SystemExit(1)
PY
  then
    fail "isolated Tart VM name is already present"
  fi
}

wait_for_runner() {
  local deadline=$((SECONDS + 300))
  local online
  while (( SECONDS < deadline )); do
    if ! grep -Fq "lifecycle event=runner_lifecycle_start" "$log_path" ||
       ! grep -Fq "runner=$SAND_SMOKE_RUNNER_NAME" "$log_path"; then
      if ! kill -0 "$sand_pid" >/dev/null 2>&1; then
        wait "$sand_pid" >/dev/null 2>&1 || true
        fail "Sand exited before starting the isolated lifecycle"
      fi
      sleep 2
      continue
    fi
    online="$(gh api \
      "/orgs/$smoke_org/actions/runners" \
      --paginate \
      --jq '.runners[] | select(.name == "'"$SAND_SMOKE_RUNNER_NAME"'") | select(.status == "online") | select(any(.labels[]?; .name == "'"$SAND_SMOKE_RUNNER_LABEL"'")) | .name' \
      2>"$workdir/runner-api.err" || true)"
    if [[ -n "$online" ]]; then
      return 0
    fi
    if ! kill -0 "$sand_pid" >/dev/null 2>&1; then
      wait "$sand_pid" >/dev/null 2>&1 || true
      fail "Sand exited before the smoke runner registered"
    fi
    sleep 5
  done
  fail "timed out waiting for the isolated GitHub runner to register"
}

find_run_id() {
  local cutoff="$1"
  gh run list \
    --repo "$smoke_repo" \
    --workflow "$smoke_workflow" \
    --limit 20 \
    --json databaseId,createdAt,event,headBranch,displayTitle \
    >"$workdir/runs.json" || return 1
  python3 - "$cutoff" "$smoke_ref" "$smoke_id" "$workdir/runs.json" <<'PY'
import json
import sys
from datetime import datetime

cutoff = int(sys.argv[1])
ref = sys.argv[2]
smoke_id = sys.argv[3]
expected_title = f"Sand runner smoke {smoke_id}"
with open(sys.argv[4], encoding="utf-8") as handle:
    runs = json.load(handle)
candidates = []
for run in runs:
    if run.get("event") != "workflow_dispatch":
        continue
    if run.get("headBranch") != ref:
        continue
    if run.get("displayTitle") != expected_title:
        continue
    created = run.get("createdAt", "")
    try:
        created_epoch = int(datetime.fromisoformat(created.replace("Z", "+00:00")).timestamp())
    except (TypeError, ValueError):
        continue
    if created_epoch >= cutoff - 5:
        candidates.append((created_epoch, int(run["databaseId"])))
if candidates:
    if len(candidates) == 1:
        print(candidates[0][1])
    else:
        raise SystemExit("ambiguous smoke workflow run correlation")
PY
}

wait_for_run() {
  local deadline=$((SECONDS + smoke_timeout))
  local payload status conclusion
  while (( SECONDS < deadline )); do
    payload="$(gh run view "$run_id" --repo "$smoke_repo" --json status,conclusion)" ||
      fail "could not read smoke workflow status"
    status="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$payload")"
    conclusion="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("conclusion") or "")' <<<"$payload")"
    if [[ "$status" == completed ]]; then
      [[ "$conclusion" == success ]] || fail "smoke workflow concluded $conclusion"
      return 0
    fi
    sleep 5
  done
  fail "smoke workflow exceeded ${smoke_timeout}s timeout"
}

wait_for_sand() {
  local deadline=$((SECONDS + smoke_timeout))
  local status=0
  while (( SECONDS < deadline )); do
    if ! kill -0 "$sand_pid" >/dev/null 2>&1; then
      wait "$sand_pid" || status=$?
      [[ "$status" -eq 0 ]] || fail "Sand lifecycle exited with status $status"
      return 0
    fi
    sleep 2
  done
  fail "Sand lifecycle exceeded ${smoke_timeout}s timeout"
}

wait_for_vm_absent() {
  if ! confirm_vm_absent; then
    fail "timed out waiting for the isolated smoke VM to disappear"
  fi
}

confirm_vm_absent() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    tart list --format json >"$workdir/tart-list.json" || return 1
    if python3 - "$SAND_SMOKE_RUNNER_NAME" "$workdir/tart-list.json" <<'PY'
import json
import sys

runner_name = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    entries = json.load(handle)
if not any(entry.get("Name") == runner_name for entry in entries):
    raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 5
  done
  return 1
}

write_metrics() {
  python3 - "$log_path" "$SAND_SMOKE_OUTPUT" "$smoke_id" "$run_id" \
    "$SAND_SMOKE_RUNNER_NAME" "$SAND_SMOKE_RUNNER_LABEL" "$SAND_SMOKE_SOURCE_REVISION" \
    "$binary_sha256" "$config_sha256" "$image_sha256" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path, output_path, smoke_id, run_id, runner_name, runner_label, source_revision, binary_sha256, config_sha256, image_sha256 = sys.argv[1:]
event_pattern = re.compile(r"lifecycle event=(?P<event>[A-Za-z_]+).*?lifecycle=(?P<lifecycle>[A-Za-z0-9._:/-]+)")
elapsed_pattern = re.compile(r"elapsed_ms=(?P<elapsed>[0-9]+)")
phase_pattern = re.compile(r"lifecycle phase=(?P<phase>[A-Za-z0-9_]+) outcome=complete.*?lifecycle=(?P<lifecycle>[A-Za-z0-9._:/-]+).*?elapsed_ms=(?P<elapsed>[0-9]+)")
selected_phases = {
    "vm_ready",
    "vm_ip",
    "ssh_ready",
    "guest_agent_preflight",
    "guest_dns",
    "github_setup_before_runner",
    "runner_process",
    "github_provisioner",
    "teardown",
}
events = {}
seen_events = set()
phases = {}
lifecycle_ids = set()
for line in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines():
    event = event_pattern.search(line)
    if event:
        lifecycle_ids.add(event.group("lifecycle"))
        event_name = event.group("event")
        seen_events.add(event_name)
        elapsed = elapsed_pattern.search(line)
        if elapsed:
            events.setdefault(event_name, int(elapsed.group("elapsed")))
    phase = phase_pattern.search(line)
    if phase:
        lifecycle_ids.add(phase.group("lifecycle"))
        if phase.group("phase") in selected_phases:
            phases.setdefault(phase.group("phase"), int(phase.group("elapsed")))
if len(lifecycle_ids) != 1:
    raise SystemExit(f"expected one lifecycle, found {len(lifecycle_ids)}")
required_events = {"runner_lifecycle_start", "runner_lifecycle_end", "runner_listener_ready", "runner_job_accepted"}
missing = sorted(required_events - seen_events)
if missing:
    raise SystemExit(f"missing lifecycle events: {', '.join(missing)}")
payload = {
    "schema_version": 1,
    "smoke_id": smoke_id,
    "workflow_run_id": int(run_id),
    "source_revision": source_revision,
    "binary_sha256": binary_sha256,
    "config_sha256": config_sha256,
    "image_sha256": image_sha256,
    "runner_name": runner_name,
    "runner_label": runner_label,
    "lifecycle_id": next(iter(lifecycle_ids)),
    "events_elapsed_ms": {key: events[key] for key in sorted(events)},
    "phases_elapsed_ms": {key: phases[key] for key in sorted(phases)},
}
Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

"$SAND_SMOKE_BIN" validate --config "$SAND_SMOKE_CONFIG" \
  >"$workdir/config-validation.out" 2>"$workdir/config-validation.err" ||
  fail "sand validate rejected the isolated smoke config"
verify_runner_absent
: >"$log_path"
SAND_LOG_FILE="$log_path" "$SAND_SMOKE_BIN" run \
  --config "$SAND_SMOKE_CONFIG" \
  --log-file "$log_path" \
  >"$workdir/sand.stdout" 2>"$workdir/sand.stderr" &
sand_pid=$!
sand_started=true

wait_for_runner
dispatch_epoch="$(date -u +%s)"
if ! gh workflow run "$smoke_workflow" \
  --repo "$smoke_repo" \
  --ref "$smoke_ref" \
  --field runner_label="$SAND_SMOKE_RUNNER_LABEL" \
  --field runner_name="$SAND_SMOKE_RUNNER_NAME" \
  --field smoke_id="$smoke_id" \
  >"$workdir/dispatch.out"; then
  fail "could not dispatch smoke workflow"
fi
run_id="$(sed -nE 's#.*/runs/([0-9]+).*#\1#p' "$workdir/dispatch.out" | tail -n 1)"
[[ "$run_id" =~ ^[0-9]+$ ]] || run_id=""

if [[ -z "$run_id" ]]; then
  for _ in 1 2 3 4 5 6; do
    run_id="$(find_run_id "$dispatch_epoch" || true)"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
fi
[[ -n "$run_id" ]] || fail "could not identify dispatched smoke workflow"

wait_for_run
gh run view "$run_id" --repo "$smoke_repo" --log >"$workdir/workflow.log" ||
  fail "could not fetch completed smoke workflow log"
grep -Fq "sand_smoke_success id=$smoke_id runner=$SAND_SMOKE_RUNNER_NAME" "$workdir/workflow.log" ||
  fail "smoke workflow did not emit the unique success marker"

wait_for_sand
grep -Fq "event=runner_listener_ready" "$log_path" || fail "listener readiness marker missing"
grep -Fq "event=runner_job_accepted" "$log_path" || fail "job acceptance marker missing"
grep -Fq "lifecycle event=runner_lifecycle_end" "$log_path" || fail "lifecycle completion marker missing"
wait_for_vm_absent
write_metrics
printf '%s\n' "$SAND_SMOKE_OUTPUT"
