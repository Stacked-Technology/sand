#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/release-smoke.sh"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/sand-release-smoke-case.XXXXXX")
trap 'rm -rf "$workdir"' EXIT

bin="$workdir/bin"
state="$workdir/state"
tmp="$workdir/tmp"
mkdir -p "$bin" "$state" "$tmp"

config="$workdir/config.json"
cat >"$config" <<'JSON'
{
  "runners": [
    {
      "name": "sand-release-smoke-test",
      "stopAfter": 1,
      "vm": {
        "source": {
          "type": "oci",
          "image": "ghcr.io/example/sand@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        }
      },
      "provisioner": {
        "type": "github",
        "config": {
          "appId": 1,
          "organization": "example",
          "privateKeyPath": "/private/tmp/sand-smoke-test-key",
          "runnerName": "sand-release-smoke-test",
          "ephemeral": true,
          "extraLabels": ["sand-release-smoke", "sand-release-smoke-test"]
        }
      }
    }
  ]
}
JSON

cat >"$bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
state="${SMOKE_FAKE_STATE:?}"
if [[ "${1:-}" == api ]]; then
  if [[ -f "$state/collision" ]]; then
    printf '%s\n' 'foreign-runner'
  elif [[ -f "$state/registered" ]]; then
    printf '%s\n' 'sand-release-smoke-test'
  fi
elif [[ "${1:-}" == workflow && "${2:-}" == run ]]; then
  if [[ ! -f "$state/no-url" ]]; then
    printf '%s\n' 'https://github.com/example/sand/actions/runs/123'
  fi
elif [[ "${1:-}" == run && "${2:-}" == list ]]; then
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ -f "$state/ambiguous" ]]; then
    printf '[{"databaseId":123,"createdAt":"%s","event":"workflow_dispatch","headBranch":"main","displayTitle":"Sand runner smoke sand-smoke-test"},{"databaseId":124,"createdAt":"%s","event":"workflow_dispatch","headBranch":"main","displayTitle":"Sand runner smoke sand-smoke-test"}]\n' "$now" "$now"
  elif [[ -f "$state/near-match" ]]; then
    printf '[{"databaseId":123,"createdAt":"%s","event":"workflow_dispatch","headBranch":"main","displayTitle":"Sand runner smoke sand-smoke-test2"}]\n' "$now"
  else
    printf '[{"databaseId":123,"createdAt":"%s","event":"workflow_dispatch","headBranch":"main","displayTitle":"Sand runner smoke sand-smoke-test"}]\n' "$now"
  fi
elif [[ "${1:-}" == run && "${2:-}" == cancel ]]; then
  exit 0
elif [[ "${1:-}" == run && "${2:-}" == view ]]; then
  if [[ "$*" == *"--log"* ]]; then
    if [[ -f "$state/success" ]]; then
      printf 'sand_smoke_success id=sand-smoke-test runner=sand-release-smoke-test\n'
    else
      printf 'sand_smoke_success id=sand-smoke-test runner=foreign-runner\n'
    fi
  elif [[ "$*" == *"--jq"* ]]; then
    printf 'completed\n'
  else
    printf '%s\n' '{"status":"completed","conclusion":"success"}'
  fi
else
  exit 2
fi
SH

cat >"$bin/tart" <<'SH'
#!/bin/bash
set -euo pipefail
state="${SMOKE_FAKE_STATE:?}"
if [[ -f "$state/tart-fail-after" && -f "$state/after-destroy" ]]; then
  exit 1
fi
printf '[]\n'
SH

cat >"$bin/sleep" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "$#" -eq 1 && "${1:-}" =~ ^[0-9]+$ ]]; then
  exit 0
fi
exec /bin/sleep "$@"
SH

cat >"$bin/sand" <<'SH'
#!/bin/bash
set -euo pipefail
state="${SMOKE_FAKE_STATE:?}"
if [[ "${1:-}" == validate ]]; then
  exit 0
fi
if [[ "${1:-}" == destroy ]]; then
  touch "$state/destroy-attempted"
  if [[ -f "$state/destroy-fail" ]]; then
    printf 'destroy failed\n' >&2
    exit 1
  fi
  if [[ -f "$state/tart-fail-after" ]]; then
    touch "$state/after-destroy"
  fi
  touch "$state/stop"
  rm -f "$state/registered"
  exit 0
fi
if [[ "${1:-}" != run ]]; then
  exit 2
fi
log=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --log-file ]]; then
    log="$2"
    shift 2
  else
    shift
  fi
done
printf 'lifecycle event=runner_lifecycle_start lifecycle=smoke runner=sand-release-smoke-test elapsed_ms=0\n' >>"$log"
printf 'lifecycle event=runner_listener_ready lifecycle=smoke runner=sand-release-smoke-test elapsed_ms=100\n' >>"$log"
printf 'lifecycle event=runner_job_accepted lifecycle=smoke runner=sand-release-smoke-test elapsed_ms=200\n' >>"$log"
printf 'lifecycle event=runner_lifecycle_end lifecycle=smoke runner=sand-release-smoke-test elapsed_ms=300\n' >>"$log"
touch "$state/registered"
printf '%s\n' "$$" >"$state/sand.pid"
if [[ -f "$state/success" ]]; then
  exit 0
fi
while [[ ! -f "$state/stop" ]]; do
  /bin/sleep 1
done
SH
chmod +x "$bin"/*

sand_validator="${SAND_BIN:-$ROOT/.build/debug/sand}"
[[ -x "$sand_validator" ]] || { printf 'missing Sand validator binary: %s\n' "$sand_validator" >&2; exit 1; }
"$sand_validator" validate --config "$ROOT/fixtures/release_smoke_config.json" \
  >"$workdir/fixture-validation.out" 2>"$workdir/fixture-validation.err"

run_smoke() {
  local name="$1"
  local config_path="${2:-$config}"
  local output="$workdir/$name.out"
  local status
  if env \
    PATH="$bin:$PATH" \
    SMOKE_FAKE_STATE="$state" \
    TMPDIR="$tmp" \
    SAND_SMOKE_BIN="$bin/sand" \
    SAND_SMOKE_CONFIG="$config_path" \
    SAND_SMOKE_RUNNER_NAME="sand-release-smoke-test" \
    SAND_SMOKE_RUNNER_LABEL="sand-release-smoke-test" \
    SAND_SMOKE_SOURCE_REVISION="abcdef1" \
    SAND_SMOKE_OUTPUT="$workdir/$name.json" \
    SAND_SMOKE_LOG="${SAND_SMOKE_LOG_OVERRIDE:-}" \
    SAND_SMOKE_ORG="example" \
    SAND_SMOKE_REPO="${SMOKE_FAKE_REPO:-example/sand}" \
    SAND_SMOKE_ID="sand-smoke-test" \
    SAND_SMOKE_TIMEOUT_SEC=1 \
    "$SCRIPT" >"$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  return "$status"
}

assert_failure() {
  local name="$1"
  local config_path="${2:-$config}"
  set +e
  run_smoke "$name" "$config_path"
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || { printf 'expected %s to fail\n' "$name" >&2; exit 1; }
}

printf '{' >"$workdir/malformed.json"
assert_failure malformed_config "$workdir/malformed.json"
grep -Fq 'strict JSON' "$workdir/malformed_config.out"

python3 - "$config" "$workdir/script-config.json" "$workdir/label-config.json" \
  "$workdir/name-config.json" "$workdir/repository-config.json" "$workdir/org-config.json" <<'PY'
import copy
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
script_config = copy.deepcopy(config)
script_config["runners"][0]["provisioner"]["type"] = "script"
label_config = copy.deepcopy(config)
label_config["runners"][0]["provisioner"]["config"]["extraLabels"] = ["sand-release-smoke", "foreign-label"]
name_config = copy.deepcopy(config)
name_config["runners"][0]["provisioner"]["config"]["runnerName"] = "other-runner"
repository_config = copy.deepcopy(config)
repository_config["runners"][0]["provisioner"]["config"]["repository"] = "example/repo"
org_config = copy.deepcopy(config)
org_config["runners"][0]["provisioner"]["config"]["organization"] = "other-org"
for path, value in (
    (sys.argv[2], script_config),
    (sys.argv[3], label_config),
    (sys.argv[4], name_config),
    (sys.argv[5], repository_config),
    (sys.argv[6], org_config),
):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(value, handle)
PY
assert_failure script_config "$workdir/script-config.json"
grep -Fq 'GitHub provisioner' "$workdir/script_config.out"
assert_failure label_config "$workdir/label-config.json"
grep -Fq 'extraLabels must exactly match' "$workdir/label_config.out"
assert_failure name_config "$workdir/name-config.json"
grep -Fq 'runnerName must exactly match' "$workdir/name_config.out"
assert_failure repository_config "$workdir/repository-config.json"
grep -Fq 'organization-level GitHub registration' "$workdir/repository_config.out"
assert_failure org_config "$workdir/org-config.json"
grep -Fq 'exactly match smoke organization' "$workdir/org_config.out"
set +e
SMOKE_FAKE_REPO="other/sand" run_smoke repo_scope
repo_scope_status=$?
set -e
[[ "$repo_scope_status" -ne 0 ]]
grep -Fq 'repository owner must match smoke organization' "$workdir/repo_scope.out"

rm -f "$state"/*
touch "$state/collision"
assert_failure collision
grep -Fq 'name or label is already registered' "$workdir/collision.out"
[[ ! -e "$state/destroy-attempted" ]]

rm -f "$state"/*
touch "$state/success" "$state/no-url"
printf '%s\n' 'keep this sentinel' >"$workdir/external.log"
SAND_SMOKE_LOG_OVERRIDE="$workdir/external.log" run_smoke fallback_success
grep -Fxq 'keep this sentinel' "$workdir/external.log"
python3 - "$workdir/fallback_success.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metrics = json.load(handle)
assert metrics["workflow_run_id"] == 123
assert len(metrics["binary_sha256"]) == 64
assert len(metrics["config_sha256"]) == 64
assert len(metrics["image_sha256"]) == 64
assert metrics["runner_name"] == "sand-release-smoke-test"
PY

rm -f "$state"/*
assert_failure wrong_runner
grep -Fq 'unique success marker' "$workdir/wrong_runner.out"
[[ -e "$state/destroy-attempted" ]]

rm -f "$state"/*
touch "$state/no-url" "$state/ambiguous"
assert_failure ambiguous_fallback
grep -Fq 'ambiguous smoke workflow run correlation' "$workdir/ambiguous_fallback.out"
if [[ -f "$state/sand.pid" ]]; then
  touch "$state/stop"
  kill "$(<"$state/sand.pid")" 2>/dev/null || true
fi
rm -rf "$tmp"/*

rm -f "$state"/*
touch "$state/no-url" "$state/near-match"
assert_failure near_match
grep -Fq 'could not identify dispatched smoke workflow' "$workdir/near_match.out"
if [[ -f "$state/sand.pid" ]]; then
  touch "$state/stop"
  kill "$(<"$state/sand.pid")" 2>/dev/null || true
fi
rm -rf "$tmp"/*

rm -f "$state"/*
touch "$state/destroy-fail"
assert_failure destroy_failure
grep -Fq 'destroy failed' "$workdir/destroy_failure.out"
[[ -e "$state/destroy-attempted" ]]
[[ -n "$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'sand-release-smoke.*' -print -quit)" ]]
rm -rf "$tmp"/*

rm -f "$state"/*
touch "$state/tart-fail-after"
assert_failure tart_inspection_failure
grep -Fq 'could not confirm isolated runner teardown' "$workdir/tart_inspection_failure.out"
rm -rf "$tmp"/*

printf '%s\n' 'release smoke identity, fallback, metrics, and cleanup checks passed'
