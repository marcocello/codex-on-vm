#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
REAL_PATH="$PATH"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf 'Terraform runtime: %s\n' "$(terraform version | sed -n '1p')"
printf 'Shell runtime: bash %s\n' "$BASH_VERSION"
printf 'Proof mode: mocked Azure providers with production Terraform and operator scripts\n'

"$ROOT/docs/features/pinned-root-provisioning/proof/run.sh"
terraform -chdir="$TF_DIR" test -filter=tests/remote_control_managed_workspace.tftest.hcl

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

for script in remote-control-recover.sh ssh-open.sh ssh-close.sh workspace-open.sh workspace-close.sh; do
  [[ -x "$ROOT/scripts/$script" ]]
done
[[ -x "$TF_DIR/scripts/ensure-codex-remote-control.sh" ]]

FAKE_BIN="$TMP/bin"
CALL_LOG="$TMP/calls.log"
RULE_STATE="$TMP/rule"
MOUNT_STATE="$TMP/mount-state"
ACCESS_STATE="$TMP/access.json"
MOUNT_PATH="$TMP/workspace"
mkdir -p "$FAKE_BIN" "$MOUNT_PATH"

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
if [[ "$*" == "vm run-command invoke "* ]]; then
  printf '{"value":[{"code":"ProvisioningState/succeeded","message":"Remote Control recovery completed."}]}\n'
  exit 0
fi
exit 2
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
        printf '%s app-server daemon pid-update-loop\n' "$FAKE_MANAGED_CODEX"
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
export CODEX_SSH_STATE_FILE="$ACCESS_STATE"
export CODEX_WORKSPACE_LOCAL_MOUNT_PATH="$MOUNT_PATH"

DAEMON_HOME="$TMP/codex-home"
MANAGED_CODEX="$DAEMON_HOME/packages/standalone/current/codex"
DAEMON_STATE="$DAEMON_HOME/app-server-daemon"
PARENT_TERMINATED="$TMP/parent-terminated"
PAIRING_STATE="$DAEMON_HOME/remote-control/pairing-proof"
mkdir -p "$(dirname "$MANAGED_CODEX")" "$DAEMON_STATE" "$(dirname "$PAIRING_STATE")"
cat >"$MANAGED_CODEX" <<'EOF'
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
  printf '{"status":"running","managedCodexPath":"%s","appServerVersion":"0.144.6"}\n' "$0"
  exit 0
fi
exit 2
EOF
chmod +x "$MANAGED_CODEX"
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
export FAKE_PARENT_TERMINATED="$PARENT_TERMINATED"
export FAKE_PROCESS_USER="$(id -un)"
export CODEX_HOME="$DAEMON_HOME"
export CODEX_RECOVERY_PS="$FAKE_BIN/ps"
export CODEX_RECOVERY_KILL="$FAKE_BIN/kill"
export CODEX_RECOVERY_SLEEP="$FAKE_BIN/sleep"

: >"$CALL_LOG"
FAKE_CODEX_MODE=healthy "$TF_DIR/scripts/ensure-codex-remote-control.sh"
rg -F 'codex remote-control start --json' "$CALL_LOG" >/dev/null
if rg -F 'codex app-server daemon restart' "$CALL_LOG" >/dev/null || rg -F 'kill ' "$CALL_LOG" >/dev/null; then
  printf 'healthy daemon recovery must not restart or signal a process\n' >&2
  exit 1
fi

: >"$CALL_LOG"
FAKE_CODEX_MODE=stopped "$TF_DIR/scripts/ensure-codex-remote-control.sh"
rg -F 'codex remote-control start --json' "$CALL_LOG" >/dev/null
rg -F 'codex app-server daemon version' "$CALL_LOG" >/dev/null

: >"$CALL_LOG"
rm -f "$PARENT_TERMINATED"
FAKE_CODEX_MODE=stale "$TF_DIR/scripts/ensure-codex-remote-control.sh"
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
  mismatch_app_user \
  mismatch_app_start \
  mismatch_app_stat \
  mismatch_app_parent; do
  : >"$CALL_LOG"
  rm -f "$PARENT_TERMINATED"
  if FAKE_CODEX_MODE="$mismatch" "$TF_DIR/scripts/ensure-codex-remote-control.sh"; then
    printf '%s must not be recovered automatically\n' "$mismatch" >&2
    exit 1
  fi
  if rg -F 'kill ' "$CALL_LOG" >/dev/null || [[ -f "$PARENT_TERMINATED" ]]; then
    printf '%s must not signal a process\n' "$mismatch" >&2
    exit 1
  fi
done
[[ "$(cat "$DAEMON_STATE/settings.json")" == '{"remoteControlEnabled":true}' ]]
[[ "$(cat "$DAEMON_HOME/auth.json")" == 'proof-auth-state' ]]
[[ "$(cat "$PAIRING_STATE")" == 'proof-pairing-state' ]]

: >"$CALL_LOG"
"$ROOT/scripts/remote-control-recover.sh"
rg -F 'az vm run-command invoke --subscription 00000000-0000-0000-0000-000000000000 --resource-group prod-codex-on-vm-rg --name prod-codex-on-vm-vm --command-id RunShellScript' "$CALL_LOG" >/dev/null
rg -F 'runuser -u azureadmin -- env HOME=/home/azureadmin CODEX_HOME=/home/azureadmin/.codex /usr/local/sbin/ensure-codex-remote-control' "$CALL_LOG" >/dev/null
if rg -F 'network nsg rule create' "$CALL_LOG" >/dev/null; then
  printf 'Azure Run Command recovery must not open SSH\n' >&2
  exit 1
fi

"$ROOT/scripts/ssh-open.sh"
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
if "$ROOT/scripts/workspace-open.sh"; then
  printf 'expected workspace-open to reject a pre-existing SSH session\n' >&2
  exit 1
fi
[[ -f "$RULE_STATE" && -f "$ACCESS_STATE" ]]
"$ROOT/scripts/ssh-close.sh"
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" ]]

"$ROOT/scripts/workspace-open.sh"
[[ -f "$RULE_STATE" && -f "$ACCESS_STATE" && -f "$MOUNT_STATE" ]]
rg -F "sshfs codex-on-vm:/home/azureadmin/projects $MOUNT_PATH" "$CALL_LOG" >/dev/null
"$ROOT/scripts/workspace-close.sh"
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
if "$ROOT/scripts/workspace-open.sh" relative/path; then
  printf 'expected workspace-open to reject a relative remote path\n' >&2
  exit 1
fi
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]
if rg -F 'network nsg rule create' "$CALL_LOG" >/dev/null || rg -F 'sshfs ' "$CALL_LOG" >/dev/null; then
  printf 'invalid remote path must fail before external access or mount calls\n' >&2
  exit 1
fi

: >"$CALL_LOG"
if "$ROOT/scripts/workspace-open.sh" /home/azureadmin /home/azureadmin/projects; then
  printf 'expected workspace-open to reject multiple remote paths\n' >&2
  exit 1
fi
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]
if rg -F 'network nsg rule create' "$CALL_LOG" >/dev/null || rg -F 'sshfs ' "$CALL_LOG" >/dev/null; then
  printf 'extra remote paths must fail before external access or mount calls\n' >&2
  exit 1
fi

: >"$CALL_LOG"
"$ROOT/scripts/workspace-open.sh" /home/azureadmin
[[ -f "$RULE_STATE" && -f "$ACCESS_STATE" && -f "$MOUNT_STATE" ]]
rg -F "sshfs codex-on-vm:/home/azureadmin $MOUNT_PATH" "$CALL_LOG" >/dev/null
"$ROOT/scripts/workspace-close.sh"
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]

if FAKE_SSHFS_FAIL=1 "$ROOT/scripts/workspace-open.sh"; then
  printf 'expected injected SSHFS failure\n' >&2
  exit 1
fi
[[ ! -e "$RULE_STATE" && ! -e "$ACCESS_STATE" && ! -e "$MOUNT_STATE" ]]

export PATH="$REAL_PATH"
bash -n \
  "$ROOT/scripts/ssh-open.sh" \
  "$ROOT/scripts/ssh-close.sh" \
  "$ROOT/scripts/remote-control-recover.sh" \
  "$ROOT/scripts/workspace-open.sh" \
  "$ROOT/scripts/workspace-close.sh" \
  "$ROOT/deployment/prod/tf/scripts/ensure-ssh-keys.sh" \
  "$ROOT/deployment/prod/tf/scripts/ensure-codex-remote-control.sh"
terraform -chdir="$TF_DIR" fmt -check -recursive
terraform -chdir="$TF_DIR" validate
git -C "$ROOT" diff --check
printf 'Remote-control managed workspace proof passed.\n'
