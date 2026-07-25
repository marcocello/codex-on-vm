#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
REAL_PATH="$PATH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OPERATOR_ROOT="$TMP/operator-root"
CODEX_VM_TEST_MODE=1 "$ROOT/scripts/codex-vm.sh" __extract-helpers "$OPERATOR_ROOT"
OPERATOR_SCRIPTS="$OPERATOR_ROOT/scripts"
VM_SCRIPTS="$OPERATOR_ROOT/vm-scripts"

fail() {
  printf 'Remote-control managed workspace proof failed: %s\n' "$1" >&2
  exit 1
}

printf 'Terraform runtime: %s\n' "$(terraform version | sed -n '1p')"
printf 'Shell runtime: bash %s\n' "$BASH_VERSION"
printf 'Proof mode: mocked Azure providers with production Terraform and operator scripts\n'

"$ROOT/docs/features/pinned-root-provisioning/proof/run.sh"
"$ROOT/docs/features/dot-codex-vm-bootstrap/proof/run.sh"
terraform -chdir="$TF_DIR" test -filter=tests/remote_control_managed_workspace.tftest.hcl

if rg -n '^[[:space:]]*custom_data[[:space:]]*=' "$TF_DIR" --glob '*.tf' >/dev/null; then
  fail "Terraform must not launch guest preparation through custom data"
fi
if rg -n 'resource[[:space:]]+"azurerm_virtual_machine_run_command"|provisioner[[:space:]]+"remote-exec"|resource[[:space:]]+"local_file"' \
  "$TF_DIR" --glob '*.tf' >/dev/null; then
  fail "Terraform must not own guest preparation or post-provision local SSH files"
fi
[[ ! -e "$TF_DIR/templates/cloud-init.yaml" ]] ||
  fail "the rejected cloud-init preparation template is still present"

if rg -n '^[[:space:]]*security_rule[[:space:]]*[{=]' "$TF_DIR/networking.tf" >/dev/null; then
  printf 'production NSG must not contain an inline security rule\n' >&2
  exit 1
fi
if rg -n 'resource[[:space:]]+"azurerm_network_security_rule"' "$TF_DIR" --glob '*.tf' >/dev/null; then
  printf 'production Terraform must not contain a standalone NSG rule\n' >&2
  exit 1
fi
if ! rg -n '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TF_DIR/storage.tf" >/dev/null; then
  printf 'workspace managed disk must enable the Terraform destruction guard\n' >&2
  exit 1
fi

for script in prepare-machine.sh codex-pair.sh remote-control-recover.sh ssh-open.sh ssh-close.sh workspace-open.sh workspace-close.sh; do
  [[ -x "$OPERATOR_SCRIPTS/$script" ]]
done
[[ -x "$VM_SCRIPTS/ensure-codex-remote-control.sh" ]]
[[ -x "$VM_SCRIPTS/prepare-codex-vm.sh" ]]
CODEX_HOME_HELPER="$VM_SCRIPTS/prepare-persistent-codex-home.sh"
[[ -x "$CODEX_HOME_HELPER" ]] || fail "persistent Codex home helper is unavailable"

"$ROOT/docs/features/remote-control-managed-workspace/proof/prepare-machine-scenario.sh" "$OPERATOR_ROOT" "$TMP"

ADMIN_USER="$(id -un)"

FRESH_FIXTURE="$TMP/codex-home-fresh"
mkdir -p "$FRESH_FIXTURE/home" "$FRESH_FIXTURE/projects"
FRESH_SELECTED="$("$CODEX_HOME_HELPER" "$ADMIN_USER" "$FRESH_FIXTURE/home" "$FRESH_FIXTURE/projects")" ||
  fail "fresh persistent Codex home preparation failed"
[[ "$FRESH_SELECTED" == "$FRESH_FIXTURE/projects/.codex" ]] ||
  fail "fresh state selected $FRESH_SELECTED"
[[ -d "$FRESH_SELECTED" && -L "$FRESH_FIXTURE/home/.codex" ]] ||
  fail "fresh state did not create the persistent home and compatibility link"
[[ "$(readlink -f "$FRESH_FIXTURE/home/.codex")" == "$(readlink -f "$FRESH_SELECTED")" ]] ||
  fail "fresh compatibility link resolves to the wrong home"

EXISTING_FIXTURE="$TMP/codex-home-existing"
mkdir -p "$EXISTING_FIXTURE/home" "$EXISTING_FIXTURE/projects/.codex"
printf 'preserved auth\n' >"$EXISTING_FIXTURE/projects/.codex/auth.json"
EXISTING_SELECTED="$("$CODEX_HOME_HELPER" "$ADMIN_USER" "$EXISTING_FIXTURE/home" "$EXISTING_FIXTURE/projects")" ||
  fail "existing persistent Codex home preparation failed"
[[ "$EXISTING_SELECTED" == "$EXISTING_FIXTURE/projects/.codex" ]] ||
  fail "existing state selected $EXISTING_SELECTED"
[[ "$(cat "$EXISTING_SELECTED/auth.json")" == "preserved auth" ]] ||
  fail "existing persistent authentication state changed"
[[ "$(readlink -f "$EXISTING_FIXTURE/home/.codex")" == "$(readlink -f "$EXISTING_SELECTED")" ]] ||
  fail "existing-state compatibility link resolves to the wrong home"

DOT_FIXTURE="$TMP/codex-home-dot-codex"
mkdir -p "$DOT_FIXTURE/home" "$DOT_FIXTURE/projects/.codex" "$DOT_FIXTURE/projects/dot-codex/.git"
printf 'older persistent state\n' >"$DOT_FIXTURE/projects/.codex/state.txt"
printf 'active dot-codex auth\n' >"$DOT_FIXTURE/projects/dot-codex/auth.json"
DOT_SELECTED="$("$CODEX_HOME_HELPER" "$ADMIN_USER" "$DOT_FIXTURE/home" "$DOT_FIXTURE/projects")" ||
  fail "existing dot-codex home preparation failed"
[[ "$DOT_SELECTED" == "$DOT_FIXTURE/projects/dot-codex" ]] ||
  fail "dot-codex state selected $DOT_SELECTED"
[[ "$(cat "$DOT_SELECTED/auth.json")" == "active dot-codex auth" ]] ||
  fail "active dot-codex authentication state changed"
[[ "$(cat "$DOT_FIXTURE/projects/.codex/state.txt")" == "older persistent state" ]] ||
  fail "inactive persistent state was deleted or changed"
[[ "$(readlink -f "$DOT_FIXTURE/home/.codex")" == "$(readlink -f "$DOT_SELECTED")" ]] ||
  fail "dot-codex compatibility link resolves to the wrong home"

REAL_HOME_FIXTURE="$TMP/codex-home-real"
mkdir -p "$REAL_HOME_FIXTURE/home/.codex" "$REAL_HOME_FIXTURE/projects"
printf 'do not overwrite\n' >"$REAL_HOME_FIXTURE/home/.codex/auth.json"
if "$CODEX_HOME_HELPER" "$ADMIN_USER" "$REAL_HOME_FIXTURE/home" "$REAL_HOME_FIXTURE/projects"; then
  printf 'persistent Codex home helper must reject a real ~/.codex directory\n' >&2
  exit 1
fi
[[ "$(cat "$REAL_HOME_FIXTURE/home/.codex/auth.json")" == "do not overwrite" ]] ||
  fail "real ~/.codex state changed after refusal"
[[ ! -e "$REAL_HOME_FIXTURE/projects/.codex" ]] ||
  fail "real ~/.codex refusal created persistent state"

MISMATCH_FIXTURE="$TMP/codex-home-mismatch"
mkdir -p "$MISMATCH_FIXTURE/home" "$MISMATCH_FIXTURE/projects/.codex" "$MISMATCH_FIXTURE/unrelated"
ln -s "$MISMATCH_FIXTURE/unrelated" "$MISMATCH_FIXTURE/home/.codex"
if "$CODEX_HOME_HELPER" "$ADMIN_USER" "$MISMATCH_FIXTURE/home" "$MISMATCH_FIXTURE/projects"; then
  printf 'persistent Codex home helper must reject a mismatched ~/.codex symlink\n' >&2
  exit 1
fi
[[ "$(readlink "$MISMATCH_FIXTURE/home/.codex")" == "$MISMATCH_FIXTURE/unrelated" ]] ||
  fail "mismatched ~/.codex symlink changed after refusal"

printf 'Persistent Codex home fixtures: fresh, existing, dot-codex, real-home refusal, mismatched-link refusal\n'

FAKE_BIN="$TMP/bin"
CALL_LOG="$TMP/calls.log"
RULE_STATE="$TMP/rule"
MOUNT_STATE="$TMP/mount-state"
ACCESS_STATE="$TMP/access.json"
MOUNT_PATH="$TMP/workspace"
REMOTE_HELPER_TARGET="$TMP/remote/usr/local/sbin/ensure-codex-remote-control"
REMOTE_HELPER_OUTDATED="$TMP/outdated-ensure-codex-remote-control"
REMOTE_INSTALL_COUNT="$TMP/remote-install-count"
REMOTE_RECOVERY_COUNT="$TMP/remote-recovery-count"
mkdir -p "$FAKE_BIN" "$MOUNT_PATH" "$(dirname "$REMOTE_HELPER_TARGET")"

cat >"$FAKE_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"subscription_id":"00000000-0000-0000-0000-000000000000","resource_group_name":"prod-codex-on-vm-rg","network_security_group_name":"prod-codex-on-vm-nsg","temporary_ssh_rule_name":"AllowTemporarySsh","ssh_alias":"codex-on-vm","ssh_fqdn":"codex-on-vm.example.invalid","ssh_username":"azureadmin","vm_name":"prod-codex-on-vm-vm","workspace_mount_path":"/home/azureadmin/projects","local_mount_path":"/tmp/unused"}
JSON
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '8.8.8.8\n'
EOF

cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF

cat >"$FAKE_BIN/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "vm" && "$2" == "run-command" && "$3" == "invoke" ]]; then
  shift 3
  subscription=""
  resource_group=""
  vm_name=""
  command_id=""
  remote_script=""
  only_show_errors=false
  while (($#)); do
    case "$1" in
      --subscription)
        subscription="$2"
        shift 2
        ;;
      --resource-group)
        resource_group="$2"
        shift 2
        ;;
      --name)
        vm_name="$2"
        shift 2
        ;;
      --command-id)
        command_id="$2"
        shift 2
        ;;
      --scripts)
        remote_script="$2"
        shift 2
        ;;
      --only-show-errors)
        only_show_errors=true
        shift
        ;;
      *)
        printf 'unexpected Run Command argument: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  [[ "$subscription" == "00000000-0000-0000-0000-000000000000" ]]
  [[ "$resource_group" == "prod-codex-on-vm-rg" ]]
  [[ "$vm_name" == "prod-codex-on-vm-vm" ]]
  [[ "$command_id" == "RunShellScript" ]]
  [[ -n "$remote_script" && "$only_show_errors" == true ]]
  printf 'az vm run-command invoke --subscription %s --resource-group %s --name %s --command-id %s --scripts <reconcile-payload> --only-show-errors\n' \
    "$subscription" "$resource_group" "$vm_name" "$command_id" >>"$FAKE_CALL_LOG"
  FAKE_REMOTE_CONTEXT=1 PATH="$FAKE_BIN:$PATH" /bin/sh -c "$remote_script"
  printf '{"value":[{"code":"ProvisioningState/succeeded","message":"Remote Control recovery completed."}]}\n'
  exit 0
fi
printf 'az %s\n' "$*" >>"$FAKE_CALL_LOG"
if [[ "$*" == "account show --query id --output tsv" ]]; then
  printf '%s\n' "00000000-0000-0000-0000-000000000000"
  exit 0
fi
if [[ "$*" == "network nsg rule create "* ]]; then
  python3 - "$FAKE_RULE_STATE" "${@:5}" <<'PY'
import json
import pathlib
import sys

arguments = sys.argv[2:]
values = {}
index = 0
while index < len(arguments):
    option = arguments[index]
    if not option.startswith("--"):
        raise SystemExit(f"unexpected NSG create argument: {option}")
    if option == "--only-show-errors":
        values[option[2:]] = True
        index += 1
        continue
    if index + 1 >= len(arguments):
        raise SystemExit(f"missing value for NSG create argument: {option}")
    if option[2:] in values:
        raise SystemExit(f"duplicate NSG create argument: {option}")
    values[option[2:]] = arguments[index + 1]
    index += 2
pathlib.Path(sys.argv[1]).write_text(json.dumps(values, sort_keys=True) + "\n", encoding="utf-8")
PY
  exit 0
fi
if [[ "$*" == "network nsg rule delete "* ]]; then
  [[ -f "$FAKE_RULE_STATE" ]] || exit 3
  python3 - "$FAKE_RULE_STATE" "${@:5}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open(encoding="utf-8") as handle:
    rule = json.load(handle)
arguments = sys.argv[2:]
values = {}
index = 0
while index < len(arguments):
    option = arguments[index]
    if option == "--only-show-errors":
        index += 1
        continue
    if not option.startswith("--") or index + 1 >= len(arguments):
        raise SystemExit(f"invalid NSG delete argument: {option}")
    values[option[2:]] = arguments[index + 1]
    index += 2
for key in ("resource-group", "nsg-name", "name"):
    if values.get(key) != rule.get(key):
        raise SystemExit(3)
path.unlink()
PY
  exit 0
fi
if [[ "$*" == "network nsg rule show "* ]]; then
  [[ -f "$FAKE_RULE_STATE" ]] || exit 3
  python3 - "$FAKE_RULE_STATE" "${@:5}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    rule = json.load(handle)
arguments = sys.argv[2:]
values = {}
index = 0
while index < len(arguments):
    option = arguments[index]
    if option == "--only-show-errors":
        index += 1
        continue
    if not option.startswith("--") or index + 1 >= len(arguments):
        raise SystemExit(f"invalid NSG show argument: {option}")
    values[option[2:]] = arguments[index + 1]
    index += 2
for key in ("resource-group", "nsg-name", "name"):
    if values.get(key) != rule.get(key):
        raise SystemExit(3)
query = values.get("query", "")
mapping = {
    "sourceAddressPrefix": "source-address-prefixes",
    "destinationPortRange": "destination-port-ranges",
    "access": "access",
}
if not query:
    print(json.dumps(rule, sort_keys=True))
elif query in mapping:
    print(rule.get(mapping[query], ""))
else:
    raise SystemExit(f"unsupported NSG show query: {query}")
PY
  exit 0
fi
exit 2
EOF

cat >"$FAKE_BIN/base64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_REMOTE_CONTEXT:-0}" == "1" ]]
[[ "$#" == 1 && "$1" == "--decode" ]]
python3 -c 'import base64, sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read(), validate=True))'
if [[ "${FAKE_REMOTE_CORRUPT_PAYLOAD:-0}" == "1" ]]; then
  printf 'corrupted'
fi
printf 'remote base64 --decode\n' >>"$FAKE_CALL_LOG"
EOF

cat >"$FAKE_BIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_REMOTE_CONTEXT:-0}" == "1" ]]
[[ "$#" == 1 ]]
python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path}")
PY
printf 'remote sha256sum\n' >>"$FAKE_CALL_LOG"
EOF

cat >"$FAKE_BIN/cmp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_REMOTE_CONTEXT:-0}" == "1" ]]
[[ "$#" == 3 && "$1" == "-s" ]]
source_path="$2"
target_path="$3"
[[ "$target_path" == "/usr/local/sbin/ensure-codex-remote-control" ]]
/usr/bin/cmp -s "$source_path" "$FAKE_REMOTE_HELPER_TARGET"
EOF

cat >"$FAKE_BIN/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_REMOTE_CONTEXT:-0}" == "1" && "$#" == 8 && "$1" == "-o" && "$2" == "root" && "$3" == "-g" && "$4" == "root" && "$5" == "-m" && "$6" == "0755" && "$8" == "/usr/local/sbin/ensure-codex-remote-control" ]]; then
  /bin/cp "$7" "$FAKE_REMOTE_HELPER_TARGET"
  /bin/chmod 0755 "$FAKE_REMOTE_HELPER_TARGET"
  count=0
  if [[ -f "$FAKE_REMOTE_INSTALL_COUNT" ]]; then
    read -r count <"$FAKE_REMOTE_INSTALL_COUNT"
  fi
  printf '%s\n' "$((count + 1))" >"$FAKE_REMOTE_INSTALL_COUNT"
  printf 'remote install %s\n' "$8" >>"$FAKE_CALL_LOG"
  exit 0
fi
if [[ "${FAKE_REMOTE_CONTEXT:-0}" == "1" || "$*" == *"/usr/local/sbin/ensure-codex-remote-control"* ]]; then
  printf 'recovery install escaped or mismatched the Run Command boundary\n' >&2
  exit 2
fi
exec /usr/bin/install "$@"
EOF

cat >"$FAKE_BIN/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_REMOTE_CONTEXT:-0}" == "1" ]]
[[ "$*" == "-u azureadmin -- env HOME=/home/azureadmin CODEX_HOME=/home/azureadmin/.codex /usr/local/sbin/ensure-codex-remote-control" ]]
/usr/bin/cmp -s "$FAKE_EXPECTED_REMOTE_HELPER" "$FAKE_REMOTE_HELPER_TARGET"
count=0
if [[ -f "$FAKE_REMOTE_RECOVERY_COUNT" ]]; then
  read -r count <"$FAKE_REMOTE_RECOVERY_COUNT"
fi
printf '%s\n' "$((count + 1))" >"$FAKE_REMOTE_RECOVERY_COUNT"
printf 'remote runuser %s\n' "$*" >>"$FAKE_CALL_LOG"
EOF

cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "-p" && "$3" == "-o" ]]
pid="$2"
field="$4"
if [[ -f "$FAKE_PARENT_TERMINATED" ]]; then
  exit 1
fi
if [[ "$pid" == "22420" ]]; then
  case "$field" in
    user=)
      if [[ "$FAKE_CODEX_MODE" == "mismatch_updater_user" ]]; then
        printf 'unrelated-user\n'
      else
        printf '%s\n' "$FAKE_PROCESS_USER"
      fi
      ;;
    lstart=)
      if [[ "$FAKE_CODEX_MODE" == "mismatch_updater_start" ]]; then
        printf 'Fri Jul 17 07:49:18 2026\n'
      else
        printf 'Fri Jul 17 07:49:19 2026\n'
      fi
      ;;
    args=)
      if [[ "$FAKE_CODEX_MODE" == "mismatch_updater_args" ]]; then
        printf 'unrelated updater\n'
      else
        printf '%s app-server daemon pid-update-loop\n' "$FAKE_RELEASE_CODEX"
      fi
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi
if [[ "$pid" == "23288" ]]; then
  case "$field" in
    user=)
      if [[ "$FAKE_CODEX_MODE" == "mismatch_app_user" ]]; then
        printf 'unrelated-user\n'
      else
        printf '%s\n' "$FAKE_PROCESS_USER"
      fi
      ;;
    lstart=)
      if [[ "$FAKE_CODEX_MODE" == "mismatch_app_start" ]]; then
        printf 'Fri Jul 17 07:49:18 2026\n'
      else
        printf 'Fri Jul 17 07:49:20 2026\n'
      fi
      ;;
    stat=)
      if [[ "$FAKE_CODEX_MODE" == "mismatch_app_stat" ]]; then
        printf 'S\n'
      else
        printf 'Z\n'
      fi
      ;;
    ppid=)
      if [[ "$FAKE_CODEX_MODE" == "mismatch_app_parent" ]]; then
        printf '1\n'
      else
        printf '22420\n'
      fi
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi
exit 1
EOF

cat >"$FAKE_BIN/kill" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kill %s\n' "$*" >>"$FAKE_CALL_LOG"
[[ "$1" == "-TERM" && "$2" == "22420" ]]
touch "$FAKE_PARENT_TERMINATED"
EOF

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN/sshfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sshfs %s\n' "$*" >>"$FAKE_CALL_LOG"
[[ "${FAKE_SSHFS_FAIL:-0}" != "1" ]] || exit 9
touch "$FAKE_MOUNT_STATE"
EOF

cat >"$FAKE_BIN/mount" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$FAKE_MOUNT_STATE" ]]; then
  printf 'codex-on-vm:/home/azureadmin/projects on %s (macfuse)\n' "$FAKE_MOUNT_PATH"
fi
EOF

cat >"$FAKE_BIN/diskutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'diskutil %s\n' "$*" >>"$FAKE_CALL_LOG"
[[ "$1" == "unmount" ]]
rm -f "$FAKE_MOUNT_STATE"
EOF

chmod +x "$FAKE_BIN"/*
export PATH="$FAKE_BIN:$PATH"
export FAKE_CALL_LOG="$CALL_LOG"
export FAKE_RULE_STATE="$RULE_STATE"
export FAKE_MOUNT_STATE="$MOUNT_STATE"
export FAKE_MOUNT_PATH="$MOUNT_PATH"
export FAKE_BIN
export FAKE_REMOTE_HELPER_TARGET="$REMOTE_HELPER_TARGET"
export FAKE_REMOTE_INSTALL_COUNT="$REMOTE_INSTALL_COUNT"
export FAKE_REMOTE_RECOVERY_COUNT="$REMOTE_RECOVERY_COUNT"
export FAKE_EXPECTED_REMOTE_HELPER="$VM_SCRIPTS/ensure-codex-remote-control.sh"
export CODEX_SSH_STATE_FILE="$ACCESS_STATE"
export CODEX_WORKSPACE_LOCAL_MOUNT_PATH="$MOUNT_PATH"

DAEMON_HOME="$TMP/codex-home"
MANAGED_CODEX="$DAEMON_HOME/packages/standalone/current/codex"
RELEASE_CODEX="$DAEMON_HOME/packages/standalone/releases/0.145.0-x86_64-unknown-linux-musl/bin/codex"
BACKUP_RELEASE_CODEX="$TMP/codex-home-backup/releases/0.145.0-x86_64-unknown-linux-musl/bin/codex"
UNRELATED_CODEX="$TMP/unrelated-codex"
FAKE_PROC_ROOT="$TMP/proc"
DAEMON_STATE="$DAEMON_HOME/app-server-daemon"
PARENT_TERMINATED="$TMP/parent-terminated"
PAIRING_STATE="$DAEMON_HOME/remote-control/pairing-proof"
mkdir -p \
  "$(dirname "$RELEASE_CODEX")" \
  "$(dirname "$BACKUP_RELEASE_CODEX")" \
  "$FAKE_PROC_ROOT/22420" \
  "$DAEMON_STATE" \
  "$(dirname "$PAIRING_STATE")"
ln -s "releases/0.145.0-x86_64-unknown-linux-musl/bin" \
  "$DAEMON_HOME/packages/standalone/current"
cat >"$RELEASE_CODEX" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex %s\n' "$*" >>"$FAKE_CALL_LOG"
if [[ "$*" == "remote-control start --json" ]]; then
  if [[ "$FAKE_CODEX_MODE" == "stale" || "$FAKE_CODEX_MODE" == mismatch_* ]]; then
    [[ -f "$FAKE_PARENT_TERMINATED" ]] || exit 1
  fi
  printf '{"status":"started","remoteControlEnabled":true}\n'
  exit 0
fi
if [[ "$*" == "app-server daemon restart" ]]; then
  exit 1
fi
if [[ "$*" == "app-server daemon version" ]]; then
  printf '{"status":"running","managedCodexPath":"%s","appServerVersion":"0.145.0"}\n' "$FAKE_RELEASE_CODEX"
  exit 0
fi
exit 2
EOF
chmod +x "$RELEASE_CODEX"
cp "$RELEASE_CODEX" "$BACKUP_RELEASE_CODEX"
cat >"$UNRELATED_CODEX" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BACKUP_RELEASE_CODEX" "$UNRELATED_CODEX"
ln -s "$BACKUP_RELEASE_CODEX" "$FAKE_PROC_ROOT/22420/exe"
cat >"$DAEMON_STATE/app-server-updater.pid" <<'EOF'
{"pid":22420,"processStartTime":"Fri Jul 17 07:49:19 2026"}
EOF
cat >"$DAEMON_STATE/app-server.pid" <<'EOF'
{"pid":23288,"processStartTime":"Fri Jul 17 07:49:20 2026"}
EOF
printf '{"remoteControlEnabled":true}\n' >"$DAEMON_STATE/settings.json"
printf 'proof-auth-state\n' >"$DAEMON_HOME/auth.json"
printf 'proof-pairing-state\n' >"$PAIRING_STATE"

export FAKE_MANAGED_CODEX="$MANAGED_CODEX"
export FAKE_RELEASE_CODEX="$RELEASE_CODEX"
export FAKE_PARENT_TERMINATED="$PARENT_TERMINATED"
export FAKE_PROCESS_USER="$(id -un)"
export CODEX_HOME="$DAEMON_HOME"
export CODEX_RECOVERY_PROC_ROOT="$FAKE_PROC_ROOT"
export CODEX_RECOVERY_PS="$FAKE_BIN/ps"
export CODEX_RECOVERY_KILL="$FAKE_BIN/kill"
export CODEX_RECOVERY_SLEEP="$FAKE_BIN/sleep"

: >"$CALL_LOG"
FAKE_CODEX_MODE=healthy "$VM_SCRIPTS/ensure-codex-remote-control.sh"
rg -F 'codex remote-control start --json' "$CALL_LOG" >/dev/null
if rg -F 'codex app-server daemon restart' "$CALL_LOG" >/dev/null || rg -F 'kill ' "$CALL_LOG" >/dev/null; then
  printf 'healthy daemon recovery must not restart or signal a process\n' >&2
  exit 1
fi

: >"$CALL_LOG"
FAKE_CODEX_MODE=stopped "$VM_SCRIPTS/ensure-codex-remote-control.sh"
rg -F 'codex remote-control start --json' "$CALL_LOG" >/dev/null
rg -F 'codex app-server daemon version' "$CALL_LOG" >/dev/null

: >"$CALL_LOG"
rm -f "$PARENT_TERMINATED"
FAKE_CODEX_MODE=stale "$VM_SCRIPTS/ensure-codex-remote-control.sh"
rg -F 'codex app-server daemon restart' "$CALL_LOG" >/dev/null
rg -F 'kill -TERM 22420' "$CALL_LOG" >/dev/null
[[ -f "$PARENT_TERMINATED" ]]
python3 - "$CALL_LOG" <<'PY'
import sys

calls = open(sys.argv[1], encoding="utf-8").read().splitlines()
starts = [index for index, call in enumerate(calls) if call == "codex remote-control start --json"]
restart = calls.index("codex app-server daemon restart")
signal = calls.index("kill -TERM 22420")
ready = calls.index("codex app-server daemon version")
assert len(starts) == 2, calls
assert starts[0] < restart < signal < starts[1] < ready, calls
PY

for mismatch in \
  mismatch_updater_user \
  mismatch_updater_start \
  mismatch_updater_args \
  mismatch_updater_executable \
  mismatch_app_user \
  mismatch_app_start \
  mismatch_app_stat \
  mismatch_app_parent; do
  : >"$CALL_LOG"
  rm -f "$PARENT_TERMINATED"
  ln -sfn "$BACKUP_RELEASE_CODEX" "$FAKE_PROC_ROOT/22420/exe"
  if [[ "$mismatch" == "mismatch_updater_executable" ]]; then
    ln -sfn "$UNRELATED_CODEX" "$FAKE_PROC_ROOT/22420/exe"
  fi
  if FAKE_CODEX_MODE="$mismatch" "$VM_SCRIPTS/ensure-codex-remote-control.sh"; then
    printf '%s must not be recovered automatically\n' "$mismatch" >&2
    exit 1
  fi
  if rg -F 'kill ' "$CALL_LOG" >/dev/null || [[ -f "$PARENT_TERMINATED" ]]; then
    printf '%s must not signal a process\n' "$mismatch" >&2
    exit 1
  fi
done
ln -sfn "$BACKUP_RELEASE_CODEX" "$FAKE_PROC_ROOT/22420/exe"
[[ "$(cat "$DAEMON_STATE/settings.json")" == '{"remoteControlEnabled":true}' ]]
[[ "$(cat "$DAEMON_HOME/auth.json")" == 'proof-auth-state' ]]
[[ "$(cat "$PAIRING_STATE")" == 'proof-pairing-state' ]]

: >"$CALL_LOG"
printf '#!/usr/bin/env bash\nexit 99\n' >"$REMOTE_HELPER_OUTDATED"
cp "$REMOTE_HELPER_OUTDATED" "$REMOTE_HELPER_TARGET"
chmod 0755 "$REMOTE_HELPER_TARGET"
rm -f "$REMOTE_INSTALL_COUNT" "$REMOTE_RECOVERY_COUNT"
if FAKE_REMOTE_CORRUPT_PAYLOAD=1 "$OPERATOR_SCRIPTS/remote-control-recover.sh"; then
  printf 'corrupted VM helper payload must fail before installation\n' >&2
  exit 1
fi
if ! /usr/bin/cmp -s "$REMOTE_HELPER_OUTDATED" "$REMOTE_HELPER_TARGET"; then
  printf 'checksum failure changed the outdated VM helper\n' >&2
  exit 1
fi
if [[ -e "$REMOTE_INSTALL_COUNT" || -e "$REMOTE_RECOVERY_COUNT" ]]; then
  printf 'checksum failure must not install or invoke the VM helper\n' >&2
  exit 1
fi
rg -F 'remote sha256sum' "$CALL_LOG" >/dev/null
if rg -F 'remote install ' "$CALL_LOG" >/dev/null || rg -F 'remote runuser ' "$CALL_LOG" >/dev/null; then
  printf 'checksum failure crossed the install or recovery boundary\n' >&2
  exit 1
fi

: >"$CALL_LOG"
"$OPERATOR_SCRIPTS/remote-control-recover.sh"
"$OPERATOR_SCRIPTS/remote-control-recover.sh"
rg -F 'az vm run-command invoke --subscription 00000000-0000-0000-0000-000000000000 --resource-group prod-codex-on-vm-rg --name prod-codex-on-vm-vm --command-id RunShellScript --scripts <reconcile-payload> --only-show-errors' "$CALL_LOG" >/dev/null
[[ "$(rg -c '^az vm run-command invoke ' "$CALL_LOG")" == "2" ]]
/usr/bin/cmp -s "$VM_SCRIPTS/ensure-codex-remote-control.sh" "$REMOTE_HELPER_TARGET"
[[ "$(cat "$REMOTE_INSTALL_COUNT")" == "1" ]]
[[ "$(cat "$REMOTE_RECOVERY_COUNT")" == "2" ]]
[[ "$(rg -c '^remote install ' "$CALL_LOG")" == "1" ]]
[[ "$(rg -c '^remote runuser ' "$CALL_LOG")" == "2" ]]
python3 - "$CALL_LOG" <<'PY'
import pathlib
import sys

events = []
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if line.startswith("remote sha256sum"):
        events.append("checksum")
    elif line.startswith("remote install "):
        events.append("install")
    elif line.startswith("remote runuser "):
        events.append("recovery")
assert events == ["checksum", "install", "recovery", "checksum", "recovery"], events
PY
if rg -F 'network nsg rule create' "$CALL_LOG" >/dev/null; then
  printf 'Azure Run Command recovery must not open SSH\n' >&2
  exit 1
fi

"$OPERATOR_SCRIPTS/ssh-open.sh"
[[ -f "$RULE_STATE" && -f "$ACCESS_STATE" ]]
python3 - "$ACCESS_STATE" "$RULE_STATE" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["public_ip_cidr"] == "8.8.8.8/32"
assert value["rule_name"] == "AllowTemporarySsh"
assert value["subscription_id"] == "00000000-0000-0000-0000-000000000000"
assert "key" not in value and "token" not in value

rule = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert rule == {
    "access": "Allow",
    "destination-address-prefixes": "*",
    "destination-port-ranges": "22",
    "direction": "Inbound",
    "name": "AllowTemporarySsh",
    "nsg-name": "prod-codex-on-vm-nsg",
    "only-show-errors": True,
    "priority": "100",
    "protocol": "Tcp",
    "resource-group": "prod-codex-on-vm-rg",
    "source-address-prefixes": "8.8.8.8/32",
    "source-port-ranges": "*",
}, rule
PY
if az network nsg rule show --resource-group prod-codex-on-vm-rg --nsg-name prod-codex-on-vm-nsg --name WrongRule --only-show-errors >/dev/null 2>&1; then
  printf 'Azure read-back fake must reject a mismatched rule identity\n' >&2
  exit 1
fi
if az network nsg rule delete --resource-group prod-codex-on-vm-rg --nsg-name prod-codex-on-vm-nsg --name WrongRule --only-show-errors >/dev/null 2>&1; then
  printf 'Azure delete fake must reject a mismatched rule identity\n' >&2
  exit 1
fi
[[ -f "$RULE_STATE" ]]
if "$OPERATOR_SCRIPTS/workspace-open.sh"; then
  printf 'expected workspace-open to reject a pre-existing SSH session\n' >&2
  exit 1
fi
[[ -f "$RULE_STATE" && -f "$ACCESS_STATE" ]]
"$OPERATOR_SCRIPTS/ssh-close.sh"
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" ]]

"$OPERATOR_SCRIPTS/workspace-open.sh"
[[ -f "$RULE_STATE" && -f "$ACCESS_STATE" && -f "$MOUNT_STATE" ]]
rg -F "sshfs codex-on-vm:/home/azureadmin/projects $MOUNT_PATH" "$CALL_LOG" >/dev/null
"$OPERATOR_SCRIPTS/workspace-close.sh"
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]
python3 - "$CALL_LOG" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
unmount = max(i for i, line in enumerate(lines) if line.startswith("diskutil unmount "))
delete = max(i for i, line in enumerate(lines) if line.startswith("az network nsg rule delete "))
assert unmount < delete
PY

: >"$CALL_LOG"
if "$OPERATOR_SCRIPTS/workspace-open.sh" relative/path; then
  printf 'expected workspace-open to reject a relative remote path\n' >&2
  exit 1
fi
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]
if rg -F 'network nsg rule create' "$CALL_LOG" >/dev/null || rg -F 'sshfs ' "$CALL_LOG" >/dev/null; then
  printf 'invalid remote path must fail before external access or mount calls\n' >&2
  exit 1
fi

: >"$CALL_LOG"
if "$OPERATOR_SCRIPTS/workspace-open.sh" /home/azureadmin /home/azureadmin/projects; then
  printf 'expected workspace-open to reject multiple remote paths\n' >&2
  exit 1
fi
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]
if rg -F 'network nsg rule create' "$CALL_LOG" >/dev/null || rg -F 'sshfs ' "$CALL_LOG" >/dev/null; then
  printf 'extra remote paths must fail before external access or mount calls\n' >&2
  exit 1
fi

: >"$CALL_LOG"
"$OPERATOR_SCRIPTS/workspace-open.sh" /home/azureadmin
[[ -f "$RULE_STATE" && -f "$ACCESS_STATE" && -f "$MOUNT_STATE" ]]
rg -F "sshfs codex-on-vm:/home/azureadmin $MOUNT_PATH" "$CALL_LOG" >/dev/null
"$OPERATOR_SCRIPTS/workspace-close.sh"
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]

if FAKE_SSHFS_FAIL=1 "$OPERATOR_SCRIPTS/workspace-open.sh"; then
  printf 'expected injected SSHFS failure\n' >&2
  exit 1
fi
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]

export PATH="$REAL_PATH"
bash -n \
  "$OPERATOR_SCRIPTS/prepare-machine.sh" \
  "$OPERATOR_SCRIPTS/codex-pair.sh" \
  "$OPERATOR_SCRIPTS/ssh-open.sh" \
  "$OPERATOR_SCRIPTS/ssh-close.sh" \
  "$OPERATOR_SCRIPTS/remote-control-recover.sh" \
  "$OPERATOR_SCRIPTS/workspace-open.sh" \
  "$OPERATOR_SCRIPTS/workspace-close.sh" \
  "$VM_SCRIPTS/ensure-ssh-keys.sh" \
  "$VM_SCRIPTS/ensure-codex-remote-control.sh" \
  "$VM_SCRIPTS/prepare-persistent-codex-home.sh" \
  "$VM_SCRIPTS/prepare-codex-vm.sh" \
  "$ROOT/docs/features/remote-control-managed-workspace/proof/prepare-machine-scenario.sh"
terraform -chdir="$TF_DIR" fmt -check -recursive
terraform -chdir="$TF_DIR" validate
git -C "$ROOT" diff --check
printf 'Remote-control managed workspace proof passed.\n'
