#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CONSOLE="$ROOT/scripts/codex-vm.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'Codex VM operator console proof failed: %s\n' "$1" >&2
  exit 1
}

printf 'Bash: %s | %s\n' "$(command -v bash)" "$(bash --version | head -n 1)"
printf 'Python: %s | %s\n' "$(command -v python3)" "$(python3 --version 2>&1)"
printf 'Proof mode: production console with fake helper/provider executable edges\n'

[[ -x "$CONSOLE" ]] || fail "production operator console is missing or not executable"
bash -n "$CONSOLE"

FIXTURE="$TMP/operator-console"
FAKE_ROOT="$FIXTURE/repo"
FAKE_BIN="$FIXTURE/bin"
CALL_LOG="$FIXTURE/calls.log"
SSH_STATE="$FIXTURE/ssh-open"
MOUNT_STATE="$FIXTURE/workspace-mounted"
PREPARED_STATE="$FIXTURE/vm-prepared"
mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/deployment/prod/tf" "$FAKE_BIN"
cp "$CONSOLE" "$FAKE_ROOT/scripts/codex-vm.sh"
chmod +x "$FAKE_ROOT/scripts/codex-vm.sh"
touch "$FAKE_ROOT/deployment/prod/tf/backend.hcl"

MAC_SCRIPTS="$(find "$ROOT/scripts" -maxdepth 1 -type f -name '*.sh' -print | sort)"
[[ "$MAC_SCRIPTS" == "$ROOT/scripts/codex-vm.sh" ]] ||
  fail "codex-vm.sh is not the only checked-in Mac production script: $MAC_SCRIPTS"
DEPLOYMENT_SCRIPTS="$(find "$ROOT/deployment/prod/tf" \
  -path "$ROOT/deployment/prod/tf/scripts/*.sh" -type f -print | sort)"
[[ -z "$DEPLOYMENT_SCRIPTS" ]] ||
  fail "deployment shell payloads still exist outside codex-vm.sh: $DEPLOYMENT_SCRIPTS"
rg -F 'scripts/codex-vm.sh' "$ROOT/deployment/prod/tf/main.tf" >/dev/null ||
  fail "Terraform does not invoke the unified console for SSH-key preparation"
rg -F '__terraform-ensure-ssh-keys' "$ROOT/deployment/prod/tf/main.tf" >/dev/null ||
  fail "Terraform does not invoke the private SSH-key preparation entrypoint"

EXTRACTED_ROOT="$FIXTURE/extracted"
CODEX_VM_TEST_MODE=1 "$CONSOLE" __extract-helpers "$EXTRACTED_ROOT"
for helper in \
  prepare-machine.sh \
  codex-pair.sh \
  dot-codex-bootstrap.sh \
  remote-control-recover.sh \
  ssh-open.sh \
  ssh-close.sh \
  workspace-open.sh \
  workspace-close.sh; do
  [[ -x "$EXTRACTED_ROOT/scripts/$helper" ]] ||
    fail "embedded helper did not materialize: $helper"
  bash -n "$EXTRACTED_ROOT/scripts/$helper"
done
for payload in \
  ensure-codex-remote-control.sh \
  ensure-ssh-keys.sh \
  fetch-verified-artifact.sh \
  install-verified-codex.sh \
  prepare-codex-vm.sh \
  prepare-persistent-codex-home.sh; do
  [[ -x "$EXTRACTED_ROOT/vm-scripts/$payload" ]] ||
    fail "embedded VM payload did not materialize: $payload"
  bash -n "$EXTRACTED_ROOT/vm-scripts/$payload"
done
[[ -L "$EXTRACTED_ROOT/deployment" ]] ||
  fail "embedded helper root does not link the production deployment tree"
if "$CONSOLE" __extract-helpers "$FIXTURE/unguarded-extraction" \
  >"$FIXTURE/unguarded-extraction.txt" 2>&1; then
  fail "internal helper extraction unexpectedly succeeded outside test mode"
fi

KEY_RUNTIME_PARENT="$FIXTURE/key-runtime"
KEY_PRIVATE="$FIXTURE/keys/codex-on-vm"
KEY_RESULT="$FIXTURE/key-result.json"
mkdir -m 0700 "$KEY_RUNTIME_PARENT"
printf '{"mac_private_key_path":"%s"}\n' "$KEY_PRIVATE" |
  TMPDIR="$KEY_RUNTIME_PARENT" "$CONSOLE" __terraform-ensure-ssh-keys >"$KEY_RESULT"
python3 - "$KEY_RESULT" "$KEY_PRIVATE" <<'PY'
import json
import pathlib
import stat
import subprocess
import sys

result = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if set(result) != {"mac_public_key"}:
    raise SystemExit(f"private Terraform entrypoint returned unexpected fields: {result!r}")
private = pathlib.Path(sys.argv[2])
public = pathlib.Path(f"{private}.pub")
if not private.is_file() or not public.is_file():
    raise SystemExit("private Terraform entrypoint did not create the key pair")
if stat.S_IMODE(private.stat().st_mode) != 0o600:
    raise SystemExit("private Terraform entrypoint used the wrong private-key mode")
if stat.S_IMODE(public.stat().st_mode) != 0o644:
    raise SystemExit("private Terraform entrypoint used the wrong public-key mode")
derived = subprocess.check_output(
    ["ssh-keygen", "-y", "-f", str(private)],
    text=True,
).strip().split()[:2]
returned = result["mac_public_key"].strip().split()[:2]
if derived != returned:
    raise SystemExit("private Terraform entrypoint returned the wrong public key")
if str(private) in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"):
    raise SystemExit("private Terraform entrypoint leaked the private-key path")
PY
if [[ -n "$(find "$KEY_RUNTIME_PARENT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  fail "private Terraform entrypoint left its extracted runtime behind"
fi

for helper in \
  prepare-machine.sh \
  codex-pair.sh \
  dot-codex-bootstrap.sh \
  remote-control-recover.sh \
  workspace-open.sh \
  workspace-close.sh; do
  cat >"$FAKE_ROOT/scripts/$helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helper:%s' "$(basename "$0")" >>"$CODEX_VM_TEST_CALL_LOG"
if [[ $# -gt 0 ]]; then
  printf '\t%q' "$@" >>"$CODEX_VM_TEST_CALL_LOG"
fi
printf '\n' >>"$CODEX_VM_TEST_CALL_LOG"
case "$(basename "$0")" in
  prepare-machine.sh)
    rm -f "$CODEX_VM_TEST_PREPARED_STATE"
    printf 'codex_version=0.144.3\nworkspace_mount=/home/azureadmin/projects\n' \
      >"$CODEX_VM_TEST_PREPARED_STATE"
    ;;
  workspace-open.sh) touch "$CODEX_VM_TEST_MOUNT_STATE" ;;
  workspace-close.sh) rm -f "$CODEX_VM_TEST_MOUNT_STATE" "$CODEX_VM_TEST_SSH_STATE" ;;
esac
if [[ "$(basename "$0")" == "prepare-machine.sh" && "${CODEX_VM_TEST_PREPARE_FAIL:-0}" == "1" ]]; then
  rm -f "$CODEX_VM_TEST_PREPARED_STATE"
  exit 17
fi
EOF
  chmod +x "$FAKE_ROOT/scripts/$helper"
done

cat >"$FAKE_ROOT/scripts/ssh-open.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helper:ssh-open.sh\n' >>"$CODEX_VM_TEST_CALL_LOG"
touch "$CODEX_VM_TEST_SSH_STATE"
EOF
cat >"$FAKE_ROOT/scripts/ssh-close.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helper:ssh-close.sh\n' >>"$CODEX_VM_TEST_CALL_LOG"
rm -f "$CODEX_VM_TEST_SSH_STATE"
EOF
chmod +x "$FAKE_ROOT/scripts/ssh-open.sh" "$FAKE_ROOT/scripts/ssh-close.sh"

cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
cat >"$FAKE_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${CODEX_VM_TEST_RUNTIME_PARENT:-}" ]]; then
  runtime_root="$(find "$CODEX_VM_TEST_RUNTIME_PARENT" \
    -mindepth 1 -maxdepth 1 -type d -name 'codex-vm.*' -print -quit)"
  [[ -n "$runtime_root" ]] || exit 95
  {
    printf 'runtime_path\t%s\n' "$runtime_root"
    printf 'runtime_mode\t%s\n' "$(stat -f '%Lp' "$runtime_root")"
    printf 'scripts_mode\t%s\n' "$(stat -f '%Lp' "$runtime_root/scripts")"
    printf 'vm_scripts_mode\t%s\n' "$(stat -f '%Lp' "$runtime_root/vm-scripts")"
    printf 'deployment_target\t%s\n' "$(readlink "$runtime_root/deployment")"
    for helper in \
      prepare-machine.sh \
      codex-pair.sh \
      dot-codex-bootstrap.sh \
      remote-control-recover.sh \
      ssh-open.sh \
      ssh-close.sh \
      workspace-open.sh \
      workspace-close.sh; do
      printf 'helper_mode:%s\t%s\n' \
        "$helper" "$(stat -f '%Lp' "$runtime_root/scripts/$helper")"
    done
    for payload in \
      ensure-codex-remote-control.sh \
      ensure-ssh-keys.sh \
      fetch-verified-artifact.sh \
      install-verified-codex.sh \
      prepare-codex-vm.sh \
      prepare-persistent-codex-home.sh; do
      printf 'payload_mode:%s\t%s\n' \
        "$payload" "$(stat -f '%Lp' "$runtime_root/vm-scripts/$payload")"
    done
  } >"$CODEX_VM_TEST_RUNTIME_REPORT"
fi
printf 'terraform' >>"$CODEX_VM_TEST_CALL_LOG"
printf '\t%q' "$@" >>"$CODEX_VM_TEST_CALL_LOG"
printf '\n' >>"$CODEX_VM_TEST_CALL_LOG"
if [[ "$*" == *"output -json connection"* ]]; then
  cat <<JSON
{"subscription_id":"00000000-0000-0000-0000-000000000000","resource_group_name":"prod-codex-on-vm-rg","network_security_group_name":"prod-codex-on-vm-nsg","temporary_ssh_rule_name":"AllowTemporarySsh","vm_name":"prod-codex-on-vm-vm","ssh_alias":"codex-on-vm","ssh_host_config_path":"$CODEX_VM_TEST_SSH_CONFIG","ssh_known_hosts_path":"$CODEX_VM_TEST_KNOWN_HOSTS","workspace_mount_path":"/home/azureadmin/projects","local_mount_path":"$CODEX_VM_TEST_LOCAL_MOUNT","codex_version":"0.144.3"}
JSON
fi
EOF
cat >"$FAKE_BIN/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'az' >>"$CODEX_VM_TEST_CALL_LOG"
printf '\t%q' "$@" >>"$CODEX_VM_TEST_CALL_LOG"
printf '\n' >>"$CODEX_VM_TEST_CALL_LOG"
if [[ "$*" == "account show --query id --output tsv" ]]; then
  printf '%s\n' "${CODEX_VM_TEST_ACTIVE_SUBSCRIPTION:-00000000-0000-0000-0000-000000000000}"
elif [[ "$1 $2" == "vm get-instance-view" ]]; then
  printf 'running\tProvisioningState/succeeded\n'
elif [[ "$1 $2 $3" == "vm run-command invoke" ]]; then
  [[ "${CODEX_VM_TEST_MARKER_CHECK_UNREACHABLE:-0}" != "1" ]] || exit 23
  check_script=
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--scripts" && $# -ge 2 ]]; then
      check_script="$2"
      break
    fi
    shift
  done
  [[ -n "$check_script" ]] || exit 24
  check_script="${check_script//\/var\/lib\/codex-on-vm\/prepared/$CODEX_VM_TEST_PREPARED_STATE}"
  marker_result="$(/bin/bash -c "$check_script")"
  if [[ "$marker_result" == "CODEX_ON_VM_PREPARED=1" ]]; then
    printf '{"value":[{"message":"CODEX_ON_VM_PREPARED=1\\n"}]}\n'
  else
    printf '{"value":[{"message":"preparation marker missing\\n"}]}\n'
  fi
elif [[ "$1 $2 $3 $4" == "network nsg rule show" ]]; then
  [[ -f "$CODEX_VM_TEST_SSH_STATE" ]] || exit 3
  printf '{}\n'
fi
EOF
cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh' >>"$CODEX_VM_TEST_CALL_LOG"
printf '\t%q' "$@" >>"$CODEX_VM_TEST_CALL_LOG"
printf '\n' >>"$CODEX_VM_TEST_CALL_LOG"
[[ "${CODEX_VM_TEST_SSH_FAIL:-0}" != "1" ]] || exit 9
EOF
cat >"$FAKE_BIN/mount" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$CODEX_VM_TEST_MOUNT_STATE" ]]; then
  printf 'fixture on %s (macfuse)\n' "$CODEX_VM_TEST_LOCAL_MOUNT"
fi
EOF
chmod +x "$FAKE_BIN"/*

export PATH="$FAKE_BIN:$PATH"
export CODEX_VM_TEST_CALL_LOG="$CALL_LOG"
export CODEX_VM_TEST_SSH_STATE="$SSH_STATE"
export CODEX_VM_TEST_MOUNT_STATE="$MOUNT_STATE"
export CODEX_VM_TEST_PREPARED_STATE="$PREPARED_STATE"
export CODEX_VM_TEST_SSH_CONFIG="$FIXTURE/mac/.ssh/config.d/codex-on-vm.conf"
export CODEX_VM_TEST_KNOWN_HOSTS="$FIXTURE/mac/.ssh/codex-on-vm-known-hosts"
export CODEX_VM_TEST_LOCAL_MOUNT="$FIXTURE/mac/Volumes/codex-on-vm"
export CODEX_VM_TEST_MODE=1
export CODEX_VM_TEST_HELPER_DIR="$FAKE_ROOT/scripts"
mkdir -p "$(dirname "$CODEX_VM_TEST_SSH_CONFIG")" "$CODEX_VM_TEST_LOCAL_MOUNT"
touch "$CODEX_VM_TEST_SSH_CONFIG" "$CODEX_VM_TEST_KNOWN_HOSTS"

CONSOLE_COPY="$FAKE_ROOT/scripts/codex-vm.sh"
HELP_OUTPUT="$FIXTURE/help.txt"
"$CONSOLE_COPY" help >"$HELP_OUTPUT"
for command in setup pair dot-codex shell ssh-close workspace-open workspace-close status; do
  rg -F "$command" "$HELP_OUTPUT" >/dev/null || fail "help omits $command"
done
for removed_command in deploy prepare sync-config repair recover ssh-open; do
  if rg "^  ${removed_command}[[:space:]]" "$HELP_OUTPUT" >/dev/null; then
    fail "help still exposes removed command: $removed_command"
  fi
done
if rg '^  --yes[[:space:]]' "$HELP_OUTPUT" >/dev/null; then
  fail "help still exposes removed option: --yes"
fi
REJECTED_FIRST_STEP_WARNING='Required first step after terraform apply: Set up or repair Codex on the VM.'
if rg -F "$REJECTED_FIRST_STEP_WARNING" "$HELP_OUTPUT" >/dev/null; then
  fail "help still uses warning-only preparation ordering"
fi

: >"$CALL_LOG"
RUNTIME_PARENT="$FIXTURE/runtime-parent"
RUNTIME_REPORT="$FIXTURE/runtime-report.tsv"
mkdir -m 0700 "$RUNTIME_PARENT"
CODEX_VM_TEST_MODE=0 \
  CODEX_VM_TEST_HELPER_DIR= \
  CODEX_VM_TEST_RUNTIME_PARENT="$RUNTIME_PARENT" \
  CODEX_VM_TEST_RUNTIME_REPORT="$RUNTIME_REPORT" \
  CODEX_SSH_STATE_FILE="$FIXTURE/runtime-ssh-state.json" \
  TMPDIR="$RUNTIME_PARENT" \
  "$CONSOLE_COPY" ssh-close >"$FIXTURE/production-runtime.txt"
python3 - "$RUNTIME_REPORT" "$FAKE_ROOT/deployment" <<'PY'
import pathlib
import sys

report = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    key, value = line.split("\t", 1)
    report[key] = value

expected_helpers = {
    "prepare-machine.sh",
    "codex-pair.sh",
    "dot-codex-bootstrap.sh",
    "remote-control-recover.sh",
    "ssh-open.sh",
    "ssh-close.sh",
    "workspace-open.sh",
    "workspace-close.sh",
}
expected_payloads = {
    "ensure-codex-remote-control.sh",
    "ensure-ssh-keys.sh",
    "fetch-verified-artifact.sh",
    "install-verified-codex.sh",
    "prepare-codex-vm.sh",
    "prepare-persistent-codex-home.sh",
}
if report.get("runtime_mode") != "700":
    raise SystemExit(f"runtime root is not private: {report!r}")
if report.get("scripts_mode") != "700":
    raise SystemExit(f"runtime scripts directory is not private: {report!r}")
if report.get("vm_scripts_mode") != "700":
    raise SystemExit(f"runtime VM scripts directory is not private: {report!r}")
if report.get("deployment_target") != sys.argv[2]:
    raise SystemExit(f"runtime deployment link is incorrect: {report!r}")
for helper in expected_helpers:
    if report.get(f"helper_mode:{helper}") != "700":
        raise SystemExit(f"embedded helper is not private and executable: {helper}: {report!r}")
for payload in expected_payloads:
    if report.get(f"payload_mode:{payload}") != "700":
        raise SystemExit(f"embedded payload is not private and executable: {payload}: {report!r}")
runtime_path = pathlib.Path(report["runtime_path"])
if runtime_path.exists() or runtime_path.is_symlink():
    raise SystemExit(f"runtime root was not removed after the public command: {runtime_path}")
PY
rg -F 'terraform' "$CALL_LOG" >/dev/null ||
  fail "production runtime command did not execute its embedded helper"
if rg -F 'helper:' "$CALL_LOG" >/dev/null; then
  fail "production runtime command used a test helper override"
fi

: >"$CALL_LOG"
DRY_OUTPUT="$FIXTURE/dry-run.txt"
"$CONSOLE_COPY" --dry-run setup >"$DRY_OUTPUT"
[[ ! -s "$CALL_LOG" ]] || fail "setup dry-run executed an external command"
rg -F 'prepare-machine.sh' "$DRY_OUTPUT" >/dev/null

: >"$CALL_LOG"
rm -f "$PREPARED_STATE"
DRY_PAIR_OUTPUT="$FIXTURE/dry-run-pair.txt"
"$CONSOLE_COPY" --dry-run pair >"$DRY_PAIR_OUTPUT"
[[ ! -s "$CALL_LOG" ]] || fail "pair dry-run checked or changed external state"
rg -F 'setup requires confirmation' "$DRY_PAIR_OUTPUT" >/dev/null ||
  fail "pair dry-run did not describe its consent-based preparation gate"

for removed_command in deploy prepare sync-config repair recover ssh-open; do
  : >"$CALL_LOG"
  if "$CONSOLE_COPY" "$removed_command" >"$FIXTURE/removed-$removed_command.txt" 2>&1; then
    fail "removed command unexpectedly succeeded: $removed_command"
  fi
  [[ ! -s "$CALL_LOG" ]] || fail "removed command made an external call: $removed_command"
done

: >"$CALL_LOG"
if "$CONSOLE_COPY" --yes setup >"$FIXTURE/removed-yes.txt" 2>&1; then
  fail "removed --yes option unexpectedly succeeded"
fi
[[ ! -s "$CALL_LOG" ]] || fail "removed --yes option made an external call"

assert_helper() {
  local command="$1"
  local helper="$2"
  shift 2
  : >"$CALL_LOG"
  "$CONSOLE_COPY" "$command" "$@" >"$FIXTURE/$command.txt"
  [[ "$(rg -c '^helper:' "$CALL_LOG")" == "1" ]] ||
    fail "$command made an unexpected number of helper calls"
  rg -Fx "helper:$helper" "$CALL_LOG" >/dev/null ||
    rg -F "helper:$helper"$'\t' "$CALL_LOG" >/dev/null ||
    fail "$command did not call $helper"
}

assert_helper_sequence() {
  local label="$1"
  local expected="$2"
  python3 - "$CALL_LOG" "$label" "$expected" <<'PY'
import pathlib
import sys

helpers = [
    line
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.startswith("helper:")
]
expected = sys.argv[3].split(",")
if helpers != expected:
    raise SystemExit(f"{sys.argv[2]} helper order is incorrect: {helpers!r}")
PY
}

assert_unprepared_noninteractive() {
  local command="$1"
  shift
  rm -f "$PREPARED_STATE"
  : >"$CALL_LOG"
  if "$CONSOLE_COPY" "$command" "$@" \
    >"$FIXTURE/unprepared-$command.txt" 2>&1; then
    fail "unprepared non-interactive $command unexpectedly succeeded"
  fi
  if rg '^helper:' "$CALL_LOG" >/dev/null; then
    fail "unprepared non-interactive $command ran setup or the requested action"
  fi
  rg -F 'scripts/codex-vm.sh setup' "$FIXTURE/unprepared-$command.txt" >/dev/null ||
    fail "unprepared non-interactive $command omitted the setup instruction"
}

assert_unprepared_noninteractive pair
assert_unprepared_noninteractive dot-codex
assert_unprepared_noninteractive workspace-open
assert_unprepared_noninteractive shell

assert_marker_requires_consent() {
  local scenario="$1"
  rm -f "$PREPARED_STATE"
  case "$scenario" in
    stale)
      printf 'codex_version=0.143.0\nworkspace_mount=/home/azureadmin/projects\n' \
        >"$PREPARED_STATE"
      ;;
    malformed)
      printf 'ready=yes\n' >"$PREPARED_STATE"
      ;;
    unreadable)
      printf 'codex_version=0.144.3\nworkspace_mount=/home/azureadmin/projects\n' \
        >"$PREPARED_STATE"
      chmod 000 "$PREPARED_STATE"
      ;;
    unreachable)
      printf 'codex_version=0.144.3\nworkspace_mount=/home/azureadmin/projects\n' \
        >"$PREPARED_STATE"
      ;;
    *) fail "unknown marker recovery scenario: $scenario" ;;
  esac

  : >"$CALL_LOG"
  if [[ "$scenario" == "unreachable" ]]; then
    if CODEX_VM_TEST_MARKER_CHECK_UNREACHABLE=1 \
      "$CONSOLE_COPY" pair >"$FIXTURE/marker-$scenario.txt" 2>&1; then
      fail "$scenario marker unexpectedly allowed non-interactive pairing"
    fi
  else
    if "$CONSOLE_COPY" pair >"$FIXTURE/marker-$scenario.txt" 2>&1; then
      fail "$scenario marker unexpectedly allowed non-interactive pairing"
    fi
  fi
  if rg '^helper:' "$CALL_LOG" >/dev/null; then
    fail "$scenario marker ran setup or pairing without consent"
  fi
  rg -F 'scripts/codex-vm.sh setup' "$FIXTURE/marker-$scenario.txt" >/dev/null ||
    fail "$scenario marker omitted the non-interactive setup instruction"
}

for marker_scenario in stale malformed unreadable unreachable; do
  assert_marker_requires_consent "$marker_scenario"
done

rm -f "$PREPARED_STATE"
: >"$CALL_LOG"
if CODEX_VM_TEST_ACTIVE_SUBSCRIPTION=11111111-1111-1111-1111-111111111111 \
  "$CONSOLE_COPY" pair >"$FIXTURE/subscription-mismatch.txt" 2>&1; then
  fail "subscription mismatch unexpectedly continued"
fi
if rg '^helper:' "$CALL_LOG" >/dev/null; then
  fail "subscription mismatch ran setup or pairing"
fi
if rg -F $'az\tvm\trun-command\tinvoke' "$CALL_LOG" >/dev/null; then
  fail "subscription mismatch reached the VM preparation check"
fi

assert_helper setup prepare-machine.sh
if rg -F "$REJECTED_FIRST_STEP_WARNING" "$FIXTURE/setup.txt" >/dev/null; then
  fail "setup output still uses the rejected warning"
fi
assert_helper pair codex-pair.sh
rg -F 'codex_version=0.144.3' "$CALL_LOG" >/dev/null ||
  fail "preparation check omitted the current Terraform Codex version"
rg -F 'workspace_mount=/home/azureadmin/projects' "$CALL_LOG" >/dev/null ||
  fail "preparation check omitted the current Terraform projects mount"
assert_helper dot-codex dot-codex-bootstrap.sh
assert_helper ssh-close ssh-close.sh
if rg -F $'az\tvm\trun-command\tinvoke' "$CALL_LOG" >/dev/null; then
  fail "ssh-close unexpectedly enforced preparation"
fi
assert_helper workspace-open workspace-open.sh /home/azureadmin
rg -F $'helper:workspace-open.sh\t/home/azureadmin' "$CALL_LOG" >/dev/null ||
  fail "workspace-open did not preserve the absolute remote path"
assert_helper workspace-close workspace-close.sh
if rg -F $'az\tvm\trun-command\tinvoke' "$CALL_LOG" >/dev/null; then
  fail "workspace-close unexpectedly enforced preparation"
fi

: >"$CALL_LOG"
if "$CONSOLE_COPY" workspace-open relative/path >"$FIXTURE/relative.txt" 2>&1; then
  fail "relative workspace path unexpectedly succeeded"
fi
[[ ! -s "$CALL_LOG" ]] || fail "relative workspace path reached the helper"

: >"$CALL_LOG"
if CODEX_VM_TEST_SSH_FAIL=1 "$CONSOLE_COPY" shell >"$FIXTURE/shell-failure.txt" 2>&1; then
  fail "injected SSH client failure unexpectedly succeeded"
fi
[[ ! -e "$SSH_STATE" ]] || fail "failed shell left temporary SSH open"
python3 - "$CALL_LOG" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
lines = [
    line
    for line in lines
    if line.startswith("helper:") or line.startswith("ssh\t")
]
expected = ["helper:ssh-close.sh", "helper:ssh-open.sh", "ssh\tcodex-on-vm", "helper:ssh-close.sh"]
if lines != expected:
    raise SystemExit(f"shell cleanup order is incorrect: {lines!r}")
PY

: >"$CALL_LOG"
STATUS_OUTPUT="$FIXTURE/status.txt"
"$CONSOLE_COPY" status >"$STATUS_OUTPUT"
rg -F 'prod-codex-on-vm-vm' "$STATUS_OUTPUT" >/dev/null
rg -F 'running' "$STATUS_OUTPUT" >/dev/null
rg -F 'VM agent' "$STATUS_OUTPUT" >/dev/null
if rg -F 'helper:' "$CALL_LOG" >/dev/null; then
  fail "status invoked a mutating helper"
fi
if rg -F $'az\tvm\trun-command\tinvoke' "$CALL_LOG" >/dev/null; then
  fail "status unexpectedly enforced preparation"
fi

: >"$CALL_LOG"
if "$CONSOLE_COPY" unknown >"$FIXTURE/unknown.txt" 2>&1; then
  fail "unknown command unexpectedly succeeded"
fi
[[ ! -s "$CALL_LOG" ]] || fail "unknown command made an external call"

run_menu_session() {
  local output_path="$1"
  local prepare_fail="$2"
  local menu_input="$3"
  local expected_exit="${4:-0}"
  local tty_command="${5:-}"
  CONSOLE_COPY="$CONSOLE_COPY" \
    MENU_OUTPUT="$output_path" \
    MENU_INPUT="$menu_input" \
    EXPECTED_EXIT="$expected_exit" \
    TTY_COMMAND="$tty_command" \
    CODEX_VM_TEST_PREPARE_FAIL="$prepare_fail" \
    python3 <<'PY'
import os
import pty
import select
import time

pid, fd = pty.fork()
if pid == 0:
    argv = [os.environ["CONSOLE_COPY"]]
    if os.environ["TTY_COMMAND"]:
        argv.append(os.environ["TTY_COMMAND"])
    os.execve(os.environ["CONSOLE_COPY"], argv, os.environ.copy())

os.write(fd, os.environ["MENU_INPUT"].encode())
chunks = []
deadline = time.monotonic() + 10
done = 0
status = 0
while time.monotonic() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.2)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        break
else:
    os.kill(pid, 9)
    raise SystemExit("interactive menu timed out")

_, status = os.waitpid(pid, 0) if done == 0 else (done, status)
path = os.environ["MENU_OUTPUT"]
with open(path, "wb") as handle:
    handle.write(b"".join(chunks))
actual_exit = os.waitstatus_to_exitcode(status)
expected_exit = int(os.environ["EXPECTED_EXIT"])
if actual_exit != expected_exit:
    raise SystemExit(
        f"interactive menu exited with {actual_exit}, expected {expected_exit}"
    )
PY
}

: >"$CALL_LOG"
rm -f "$PREPARED_STATE"
MENU_OUTPUT="$FIXTURE/menu.txt"
run_menu_session "$MENU_OUTPUT" 0 $'0\n'
rg -F 'Codex VM operator console' "$MENU_OUTPUT" >/dev/null ||
  fail "interactive menu did not render"
[[ ! -s "$CALL_LOG" ]] ||
  fail "interactive menu checked preparation or ran setup before showing options"
if rg -F "$REJECTED_FIRST_STEP_WARNING" "$MENU_OUTPUT" >/dev/null; then
  fail "interactive menu still uses the rejected warning"
fi
for label in \
  'Set up or repair Codex on the VM' \
  'Sign in and pair a device' \
  'Clone or update dot-codex from GitHub'; do
  rg -F "$label" "$MENU_OUTPUT" >/dev/null || fail "interactive menu omits: $label"
done
for removed_label in \
  'Deploy infrastructure and prepare machine' \
  'Prepare or reconcile machine' \
  'Authenticate and pair Remote Control' \
  'Bootstrap or refresh dot-codex' \
  'Recover Remote Control' \
  'Set up Codex on the VM' \
  'Sync your Codex configuration' \
  'Repair Remote Control' \
  'Open restricted SSH and leave it open'; do
  if rg -F "$removed_label" "$MENU_OUTPUT" >/dev/null; then
    fail "interactive menu still exposes: $removed_label"
  fi
done

rm -f "$PREPARED_STATE"
: >"$CALL_LOG"
TTY_DECLINE_OUTPUT="$FIXTURE/tty-decline.txt"
run_menu_session "$TTY_DECLINE_OUTPUT" 0 $'n\n' 0 pair
rg -F 'Run setup now?' "$TTY_DECLINE_OUTPUT" >/dev/null ||
  fail "interactive pair did not ask before setup"
rg -F 'Action cancelled.' "$TTY_DECLINE_OUTPUT" >/dev/null ||
  fail "interactive pair did not confirm cancellation"
if rg '^helper:' "$CALL_LOG" >/dev/null; then
  fail "interactive negative answer ran setup or pairing"
fi

rm -f "$PREPARED_STATE"
: >"$CALL_LOG"
TTY_ACCEPT_OUTPUT="$FIXTURE/tty-accept.txt"
run_menu_session "$TTY_ACCEPT_OUTPUT" 0 $'y\n' 0 pair
rg -F 'Run setup now?' "$TTY_ACCEPT_OUTPUT" >/dev/null ||
  fail "interactive pair did not ask before setup"
assert_helper_sequence \
  "interactive pair after accepted setup" \
  "helper:prepare-machine.sh,helper:codex-pair.sh"

rm -f "$PREPARED_STATE"
: >"$CALL_LOG"
TTY_FAILED_SETUP_OUTPUT="$FIXTURE/tty-failed-setup.txt"
run_menu_session "$TTY_FAILED_SETUP_OUTPUT" 1 $'y\n' 17 pair
assert_helper_sequence \
  "interactive pair after failed accepted setup" \
  "helper:prepare-machine.sh"

rm -f "$PREPARED_STATE"
: >"$CALL_LOG"
MENU_DECLINE_OUTPUT="$FIXTURE/menu-decline.txt"
run_menu_session "$MENU_DECLINE_OUTPUT" 0 $'2\nn\n\n0\n'
[[ "$(rg -c -F 'Codex VM operator console' "$MENU_DECLINE_OUTPUT")" == "2" ]] ||
  fail "menu did not return after setup was declined"
rg -F 'Run setup now?' "$MENU_DECLINE_OUTPUT" >/dev/null ||
  fail "menu action did not ask before setup"
rg -F 'Action cancelled.' "$MENU_DECLINE_OUTPUT" >/dev/null ||
  fail "menu action did not confirm cancellation"
if rg '^helper:' "$CALL_LOG" >/dev/null; then
  fail "declined menu action ran setup or pairing"
fi

rm -f "$PREPARED_STATE"
: >"$CALL_LOG"
MENU_ACCEPT_OUTPUT="$FIXTURE/menu-accept.txt"
run_menu_session "$MENU_ACCEPT_OUTPUT" 0 $'2\ny\n\n0\n'
[[ "$(rg -c -F 'Codex VM operator console' "$MENU_ACCEPT_OUTPUT")" == "2" ]] ||
  fail "menu did not return after accepted setup and pairing"
assert_helper_sequence \
  "menu pair after accepted setup" \
  "helper:prepare-machine.sh,helper:codex-pair.sh"

rm -f "$PREPARED_STATE"
: >"$CALL_LOG"
MENU_FAILED_SETUP_OUTPUT="$FIXTURE/menu-failed-setup.txt"
run_menu_session "$MENU_FAILED_SETUP_OUTPUT" 1 $'2\ny\n\n0\n'
[[ "$(rg -c -F 'Codex VM operator console' "$MENU_FAILED_SETUP_OUTPUT")" == "2" ]] ||
  fail "menu did not return after accepted setup failed"
rg -F 'Action failed.' "$MENU_FAILED_SETUP_OUTPUT" >/dev/null ||
  fail "menu did not report accepted setup failure"
assert_helper_sequence \
  "menu pair after failed accepted setup" \
  "helper:prepare-machine.sh"

printf 'Codex VM operator console proof passed.\n'
