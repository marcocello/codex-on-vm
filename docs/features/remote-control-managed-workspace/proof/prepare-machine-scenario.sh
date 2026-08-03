#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <repo-root> <temporary-root>\n' "$0" >&2
  exit 64
fi

ROOT="$1"
FIXTURE="$2/local-preparation"
TF_DIR="$ROOT/deployment/prod/tf"
LOCAL_BIN="$FIXTURE/local-bin"
REMOTE_BIN="$FIXTURE/remote-bin"
REMOTE_ROOT="$FIXTURE/vm-root"
CALL_LOG="$FIXTURE/calls.log"
REMOTE_CALL_LOG="$FIXTURE/remote-calls.log"
DATA_DISK="$FIXTURE/data-disk"
PARTITION="$FIXTURE/data-disk-part1"
PARTITION_STATE="$FIXTURE/partition-created"
FILESYSTEM_STATE="$FIXTURE/filesystem-created"
MOUNT_STATE="$FIXTURE/mounted"
FORMAT_COUNT="$FIXTURE/format-count"
HEALTH_START_COUNT="$FIXTURE/health-start-count"
SSH_SERVICE_STATE="$FIXTURE/ssh-service-active"
SSH_SOCKET_STATE="$FIXTURE/ssh-socket-active"
PACKAGE_ROOT="$FIXTURE/package"
PACKAGE_ARCHIVE="$FIXTURE/codex-package.tgz"
LOCAL_SSH_CONFIG="$FIXTURE/mac/.ssh/config.d/codex-on-vm.conf"
LOCAL_KNOWN_HOSTS="$FIXTURE/mac/.ssh/codex-on-vm-known_hosts"
LOCAL_PRIVATE_KEY="$FIXTURE/mac/.ssh/codex-on-vm-mac"
REAL_PATH="$PATH"

fail() {
  printf 'Local preparation scenario failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p \
  "$LOCAL_BIN" \
  "$REMOTE_BIN" \
  "$REMOTE_ROOT/etc/ssh" \
  "$REMOTE_ROOT/usr/share/apparmor/extra-profiles" \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/codex-path" \
  "$PACKAGE_ROOT/codex-resources" \
  "$(dirname "$LOCAL_PRIVATE_KEY")"
touch "$DATA_DISK" "$LOCAL_PRIVATE_KEY" "$SSH_SOCKET_STATE"
printf 'profile bwrap-userns-restrict {}\n' >"$REMOTE_ROOT/usr/share/apparmor/extra-profiles/bwrap-userns-restrict"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPrepareMachineFixtureKey proof-vm\n' \
  >"$REMOTE_ROOT/etc/ssh/ssh_host_ed25519_key.pub"

cat >"$PACKAGE_ROOT/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "--version" ]]; then
  printf 'codex-cli 0.144.3\n'
  exit 0
fi
if [[ "$*" == "app-server daemon bootstrap --remote-control" ]]; then
  exit 1
fi
if [[ "$*" == "app-server daemon bootstrap" ]]; then
  exit 0
fi
if [[ "$*" == "login status" ]]; then
  [[ -f "$CODEX_HOME/auth.json" ]]
  exit
fi
exit 2
EOF
cat >"$PACKAGE_ROOT/bin/codex-code-mode-host" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$PACKAGE_ROOT/codex-path/rg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$PACKAGE_ROOT/codex-resources/bwrap" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
printf '{"version":"0.144.3"}\n' >"$PACKAGE_ROOT/codex-package.json"
chmod +x \
  "$PACKAGE_ROOT/bin/codex" \
  "$PACKAGE_ROOT/bin/codex-code-mode-host" \
  "$PACKAGE_ROOT/codex-path/rg" \
  "$PACKAGE_ROOT/codex-resources/bwrap"
tar -czf "$PACKAGE_ARCHIVE" -C "$PACKAGE_ROOT" .
PACKAGE_SHA="$(shasum -a 256 "$PACKAGE_ARCHIVE" | awk '{print $1}')"

cat >"$LOCAL_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
python3 - <<'PY'
import json
import os

print(json.dumps({
    "subscription_id": "00000000-0000-0000-0000-000000000000",
    "resource_group_name": "prod-codex-on-vm-rg",
    "network_security_group_name": "prod-codex-on-vm-nsg",
    "ssh_fqdn": "codex-on-vm.example.invalid",
    "ssh_username": "azureadmin",
    "vm_name": "prod-codex-on-vm-vm",
    "workspace_disk_name": "prod-codex-on-vm-workspace-disk",
    "workspace_disk_lun": 0,
    "workspace_mount_path": "/home/azureadmin/projects",
    "mac_private_key_path": os.environ["FAKE_MAC_PRIVATE_KEY"],
    "ssh_host_config_path": os.environ["FAKE_LOCAL_SSH_CONFIG"],
    "ssh_known_hosts_path": os.environ["FAKE_LOCAL_KNOWN_HOSTS"],
    "openvpn_rule_name": "AllowOpenVpn",
    "openvpn_port": 1194,
    "openvpn_network": "10.250.0.0",
    "openvpn_netmask": "255.255.255.0",
    "openvpn_server_address": "10.250.0.1",
    "openvpn_ssh_alias": "codex-on-vm-vpn",
    "openvpn_local_root_path": "/tmp/openvpn-unused",
    "openvpn_client_profile_path": "/tmp/openvpn-unused/codex-on-vm.ovpn",
    "codex_version": "0.144.3",
    "codex_package_url": "https://example.invalid/codex-package.tgz",
    "codex_package_sha256": os.environ["FAKE_PACKAGE_SHA"],
}, sort_keys=True))
PY
EOF

cat >"$LOCAL_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF

cat >"$LOCAL_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$LOCAL_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '8.8.8.8\n'
EOF

cat >"$LOCAL_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >>"$FAKE_PREPARE_CALL_LOG"
if [[ "${FAKE_LOGIN_MISSING:-0}" == "1" &&
  "$*" == *"login status"* &&
  "$*" != *"login --device-auth"* ]]; then
  exit 12
fi
if [[ "${FAKE_PAIR_FAIL:-0}" == "1" && "$*" == *"remote-control pair"* ]]; then
  exit 9
fi
if [[ "$*" == *"BatchMode=yes"* && "${FAKE_VPN_UNREACHABLE:-0}" == "1" ]]; then
  exit 255
fi
[[ "$*" == *"codex-on-vm-vpn"* ]] || {
  printf 'non-VPN SSH target: %s\n' "$*" >&2
  exit 93
}
exit 0
EOF

cat >"$LOCAL_BIN/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'az %s\n' "$*" >>"$FAKE_PREPARE_CALL_LOG"
if [[ "$*" == "account show --query id --output tsv" ]]; then
  printf '00000000-0000-0000-0000-000000000000\n'
  exit 0
fi
if [[ "$1 $2" == "vm get-instance-view" ]]; then
  expected="vm get-instance-view --subscription 00000000-0000-0000-0000-000000000000 --resource-group prod-codex-on-vm-rg --name prod-codex-on-vm-vm --query instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].code | [0] --output tsv --only-show-errors"
  [[ "$*" == "$expected" ]] || {
    printf 'unexpected VM-agent target or query: %s\n' "$*" >&2
    exit 2
  }
  printf 'ProvisioningState/succeeded\n'
  exit 0
fi
if [[ "$1 $2 $3" == "vm run-command invoke" ]]; then
  shift 3
  script_argument=""
  subscription=""
  resource_group=""
  vm_name=""
  command_id=""
  output_format=""
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
      --output)
        output_format="$2"
        shift 2
        ;;
      --scripts)
        script_argument="$2"
        shift 2
        ;;
      --only-show-errors)
        shift
        ;;
      *)
        printf 'unexpected preparation Run Command argument: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  [[ "$subscription" == "00000000-0000-0000-0000-000000000000" ]] || {
    printf 'unexpected preparation subscription: %s\n' "$subscription" >&2
    exit 2
  }
  [[ "$resource_group" == "prod-codex-on-vm-rg" ]] || {
    printf 'unexpected preparation resource group: %s\n' "$resource_group" >&2
    exit 2
  }
  [[ "$vm_name" == "prod-codex-on-vm-vm" ]] || {
    printf 'unexpected preparation VM: %s\n' "$vm_name" >&2
    exit 2
  }
  [[ "$command_id" == "RunShellScript" ]] || {
    printf 'unexpected preparation command ID: %s\n' "$command_id" >&2
    exit 2
  }
  [[ "$output_format" == "json" ]] || {
    printf 'unexpected preparation output format: %s\n' "$output_format" >&2
    exit 2
  }
  [[ "$script_argument" == @* ]]
  payload="${script_argument#@}"
  set +e
  remote_output="$(
    PATH="$FAKE_REMOTE_BIN:$FAKE_REAL_PATH" \
      CODEX_VM_TEST_MODE=1 \
      CODEX_VM_ROOT="$FAKE_REMOTE_ROOT" \
      CODEX_VM_DATA_DISK="$FAKE_DATA_DISK" \
      FAKE_REMOTE_CALL_LOG="$FAKE_REMOTE_CALL_LOG" \
      FAKE_PARTITION="$FAKE_PARTITION" \
      FAKE_PARTITION_STATE="$FAKE_PARTITION_STATE" \
      FAKE_FILESYSTEM_STATE="$FAKE_FILESYSTEM_STATE" \
      FAKE_MOUNT_STATE="$FAKE_PREPARE_MOUNT_STATE" \
      FAKE_FORMAT_COUNT="$FAKE_FORMAT_COUNT" \
      FAKE_CORRUPT_PREPARE_PAYLOAD="${FAKE_CORRUPT_PREPARE_PAYLOAD:-0}" \
      FAKE_CORRUPTION_STATE="$FAKE_CORRUPTION_STATE" \
      TEST_ARTIFACT="$FAKE_PACKAGE_ARCHIVE" \
      /bin/bash "$payload" 2>&1
  )"
  remote_status=$?
  set -e
  if [[ "$remote_status" != "0" ]]; then
    printf '%s\n' "$remote_output" >&2
    exit "$remote_status"
  fi
  if [[ "${FAKE_DROP_PREPARE_MARKER:-0}" == "1" ]]; then
    diagnostic_padding="$(head -c 8192 /dev/zero | tr '\0' x)"
    remote_output="${remote_output}
REMOTE_PREPARATION_OMITTED=unbounded-output-must-not-surface
${diagnostic_padding}
REMOTE_PREPARATION_DIAGNOSTIC=fixture-readiness-failure"
    remote_output="$(printf '%s\n' "$remote_output" | sed '/^CODEX_ON_VM_PREPARED=1$/d')"
  fi
  REMOTE_OUTPUT="$remote_output" python3 - <<'PY'
import json
import os

print(json.dumps({
    "value": [{
        "code": "ComponentStatus/StdOut/succeeded",
        "message": os.environ["REMOTE_OUTPUT"],
    }]
}))
PY
  exit 0
fi
if [[ "$1 $2 $3" == "network nsg rule" ]]; then
  printf 'public ingress mutation is forbidden: %s\n' "$*" >&2
  exit 91
fi
exit 2
EOF

cat >"$REMOTE_BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$FAKE_REMOTE_CALL_LOG"
exit 0
EOF

for command in bwrap apparmor_parser partprobe udevadm sshd ssh-keygen; do
  cat >"$REMOTE_BIN/$command" <<EOF
#!/usr/bin/env bash
printf '$command %s\\n' "\$*" >>"\$FAKE_REMOTE_CALL_LOG"
exit 0
EOF
done

cat >"$REMOTE_BIN/sshd" <<'EOF'
#!/usr/bin/env bash
printf 'sshd %s\n' "$*" >>"$FAKE_REMOTE_CALL_LOG"
[[ -d "$FAKE_REMOTE_ROOT/run/sshd" ]] || {
  printf 'Missing privilege separation directory: /run/sshd\n' >&2
  exit 255
}
EOF

cat >"$REMOTE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAKE_REMOTE_CALL_LOG"
case "$*" in
  "start codex-remote-control-health.service")
    count=0
    if [[ -f "$FAKE_HEALTH_START_COUNT" ]]; then
      read -r count <"$FAKE_HEALTH_START_COUNT"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_HEALTH_START_COUNT"
    if [[ "${FAKE_HEALTH_TRANSIENT_ONCE:-0}" == "1" && "$count" == "1" ]]; then
      exit 1
    fi
    ;;
  "is-active --quiet ssh")
    [[ -f "$FAKE_SSH_SERVICE_STATE" ]] && exit 0
    exit 3
    ;;
  "is-active --quiet ssh.socket")
    [[ -f "$FAKE_SSH_SOCKET_STATE" ]] && exit 0
    exit 3
    ;;
  "enable --now ssh")
    touch "$FAKE_SSH_SERVICE_STATE"
    ;;
  "start ssh")
    touch "$FAKE_SSH_SERVICE_STATE"
    ;;
  "reload ssh")
    [[ -f "$FAKE_SSH_SERVICE_STATE" ]] || {
      printf 'ssh.service is not active, cannot reload.\n' >&2
      exit 1
    }
    ;;
esac
exit 0
EOF

cat >"$REMOTE_BIN/lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$FAKE_PARTITION_STATE" ]]; then
  printf '%s part\n' "$FAKE_PARTITION"
fi
EOF

cat >"$REMOTE_BIN/blkid" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-s TYPE"* && "$*" == *"$FAKE_PARTITION"* && -f "$FAKE_FILESYSTEM_STATE" ]]; then
  printf 'ext4\n'
elif [[ "$*" == *"-s UUID"* && "$*" == *"$FAKE_PARTITION"* && -f "$FAKE_FILESYSTEM_STATE" ]]; then
  printf '11111111-2222-3333-4444-555555555555\n'
fi
EOF

cat >"$REMOTE_BIN/wipefs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$REMOTE_BIN/parted" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_PARTITION" "$FAKE_PARTITION_STATE"
printf 'parted %s\n' "$*" >>"$FAKE_REMOTE_CALL_LOG"
EOF

cat >"$REMOTE_BIN/mkfs.ext4" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_FILESYSTEM_STATE"
count=0
if [[ -f "$FAKE_FORMAT_COUNT" ]]; then
  read -r count <"$FAKE_FORMAT_COUNT"
fi
printf '%s\n' "$((count + 1))" >"$FAKE_FORMAT_COUNT"
printf 'mkfs.ext4 %s\n' "$*" >>"$FAKE_REMOTE_CALL_LOG"
EOF

cat >"$REMOTE_BIN/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ -f "$FAKE_MOUNT_STATE" ]]
EOF

cat >"$REMOTE_BIN/mount" <<'EOF'
#!/usr/bin/env bash
touch "$FAKE_MOUNT_STATE"
printf 'mount %s\n' "$*" >>"$FAKE_REMOTE_CALL_LOG"
EOF

cat >"$REMOTE_BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
[[ -f "$FAKE_MOUNT_STATE" ]]
printf 'ext4\n'
EOF

cat >"$REMOTE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$REMOTE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (($#)); do
  case "$1" in
    -o|--output)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$output" ]]
cp "$TEST_ARTIFACT" "$output"
EOF

cat >"$REMOTE_BIN/base64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/base64 "$@"
if [[ "${FAKE_CORRUPT_PREPARE_PAYLOAD:-0}" == "1" && ! -e "$FAKE_CORRUPTION_STATE" ]]; then
  printf 'corrupted'
  touch "$FAKE_CORRUPTION_STATE"
fi
EOF

chmod +x "$LOCAL_BIN"/* "$REMOTE_BIN"/*
export PATH="$LOCAL_BIN:$REAL_PATH"
export FAKE_PREPARE_CALL_LOG="$CALL_LOG"
export FAKE_REMOTE_CALL_LOG="$REMOTE_CALL_LOG"
export FAKE_PREPARE_MOUNT_STATE="$MOUNT_STATE"
export FAKE_DATA_DISK="$DATA_DISK"
export FAKE_PARTITION="$PARTITION"
export FAKE_PARTITION_STATE="$PARTITION_STATE"
export FAKE_FILESYSTEM_STATE="$FILESYSTEM_STATE"
export FAKE_FORMAT_COUNT="$FORMAT_COUNT"
export FAKE_HEALTH_START_COUNT="$HEALTH_START_COUNT"
export FAKE_SSH_SERVICE_STATE="$SSH_SERVICE_STATE"
export FAKE_SSH_SOCKET_STATE="$SSH_SOCKET_STATE"
export FAKE_CORRUPTION_STATE="$FIXTURE/corruption-used"
export FAKE_REMOTE_BIN="$REMOTE_BIN"
export FAKE_REAL_PATH="$REAL_PATH"
export FAKE_REMOTE_ROOT="$REMOTE_ROOT"
export FAKE_PACKAGE_ARCHIVE="$PACKAGE_ARCHIVE"
export FAKE_PACKAGE_SHA="$PACKAGE_SHA"
export FAKE_MAC_PRIVATE_KEY="$LOCAL_PRIVATE_KEY"
export FAKE_LOCAL_SSH_CONFIG="$LOCAL_SSH_CONFIG"
export FAKE_LOCAL_KNOWN_HOSTS="$LOCAL_KNOWN_HOSTS"

: >"$CALL_LOG"
: >"$REMOTE_CALL_LOG"
if FAKE_CORRUPT_PREPARE_PAYLOAD=1 "$ROOT/scripts/prepare-machine.sh"; then
  fail "corrupted preparation payload unexpectedly succeeded"
fi
[[ ! -e "$LOCAL_SSH_CONFIG" && ! -e "$LOCAL_KNOWN_HOSTS" ]] ||
  fail "checksum failure wrote local SSH trust files"
[[ ! -e "$REMOTE_ROOT/var/lib/codex-on-vm/prepared" ]] ||
  fail "checksum failure reached VM preparation"

"$ROOT/scripts/prepare-machine.sh"

for script in \
  fetch-verified-artifact \
  install-verified-codex \
  configure-codex-openvpn \
  prepare-persistent-codex-home \
  ensure-codex-remote-control \
  prepare-codex-vm; do
  cmp -s "$ROOT/vm-scripts/$script.sh" "$REMOTE_ROOT/usr/local/sbin/$script" ||
    fail "transmitted $script does not match the checked-in source"
done

FSTAB="$REMOTE_ROOT/etc/fstab"
CODEX_LINK="$REMOTE_ROOT/home/azureadmin/.codex"
PERSISTENT_HOME="$REMOTE_ROOT/home/azureadmin/projects/.codex"
[[ "$(cat "$FSTAB")" == "UUID=11111111-2222-3333-4444-555555555555 /home/azureadmin/projects ext4 defaults,nofail,x-systemd.device-timeout=2min 0 2" ]] ||
  fail "persistent fstab read-back is incorrect"
[[ -L "$CODEX_LINK" && "$(readlink "$CODEX_LINK")" == "$PERSISTENT_HOME" ]] ||
  fail "Codex compatibility link is not on the projects disk"
[[ -x "$PERSISTENT_HOME/packages/standalone/current/codex" ]] ||
  fail "persistent Codex package was not installed"
[[ -L "$REMOTE_ROOT/usr/local/bin/codex" ]] ||
  fail "Codex CLI publication is missing"
[[ "$(cat "$FORMAT_COUNT")" == "1" ]] || fail "fresh disk was not formatted exactly once"
rg -F 'RequiresMountsFor=/home/azureadmin/projects' \
  "$REMOTE_ROOT/etc/systemd/system/codex-remote-control-bootstrap.service" \
  "$REMOTE_ROOT/etc/systemd/system/codex-remote-control-health.service" >/dev/null
for service in \
  "$REMOTE_ROOT/etc/systemd/system/codex-remote-control-bootstrap.service" \
  "$REMOTE_ROOT/etc/systemd/system/codex-remote-control-health.service"; do
  [[ "$(rg -c '^KillMode=process$' "$service")" == "1" ]] ||
    fail "$(basename "$service") does not preserve the detached managed daemon"
  [[ "$(rg -c '^ConditionFileIsExecutable=/home/azureadmin/.codex/packages/standalone/current/codex$' "$service")" == "1" ]] ||
    fail "$(basename "$service") does not use systemd's executable-file condition"
  if rg -F 'ConditionPathIsExecutable=' "$service" >/dev/null; then
    fail "$(basename "$service") uses an ignored systemd condition"
  fi
done
rg -F 'systemctl is-active --quiet ssh' "$REMOTE_CALL_LOG" >/dev/null
rg -F 'systemctl is-active --quiet ssh.socket' "$REMOTE_CALL_LOG" >/dev/null
if rg -F 'systemctl reload ssh' "$REMOTE_CALL_LOG" >/dev/null; then
  fail "socket-activated fresh host attempted to reload an inactive SSH service"
fi
rg -F 'AllowTcpForwarding local' "$REMOTE_ROOT/etc/ssh/sshd_config.d/60-codex-hardening.conf" >/dev/null
rg -F 'GatewayPorts no' "$REMOTE_ROOT/etc/ssh/sshd_config.d/60-codex-hardening.conf" >/dev/null
rg -F 'codex_version=0.144.3' "$REMOTE_ROOT/var/lib/codex-on-vm/prepared" >/dev/null
[[ "$(cat "$LOCAL_KNOWN_HOSTS")" == "codex-on-vm.example.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPrepareMachineFixtureKey" ]] ||
  fail "local known-hosts file does not use VM read-back"
rg -F 'StrictHostKeyChecking yes' "$LOCAL_SSH_CONFIG" >/dev/null
rg -F "IdentityFile $LOCAL_PRIVATE_KEY" "$LOCAL_SSH_CONFIG" >/dev/null
rg -F 'Host codex-on-vm-vpn' "$LOCAL_SSH_CONFIG" >/dev/null
rg -F 'HostName 10.250.0.1' "$LOCAL_SSH_CONFIG" >/dev/null
rg -F 'HostKeyAlias codex-on-vm.example.invalid' "$LOCAL_SSH_CONFIG" >/dev/null
[[ "$(rg -c '^Host ' "$LOCAL_SSH_CONFIG")" == "1" ]] ||
  fail "local SSH config contains more than the VPN alias"
if rg -Fx 'Host codex-on-vm' "$LOCAL_SSH_CONFIG" >/dev/null; then
  fail "local SSH config contains the public alias"
fi
rg -F "az vm get-instance-view --subscription 00000000-0000-0000-0000-000000000000 --resource-group prod-codex-on-vm-rg --name prod-codex-on-vm-vm " "$CALL_LOG" >/dev/null
rg -F "az vm run-command invoke --subscription 00000000-0000-0000-0000-000000000000 --resource-group prod-codex-on-vm-rg --name prod-codex-on-vm-vm --command-id RunShellScript " "$CALL_LOG" >/dev/null
if rg -F 'network nsg rule create' "$CALL_LOG" >/dev/null || rg -F 'ssh ' "$CALL_LOG" >/dev/null; then
  fail "machine preparation opened SSH instead of using the VM agent"
fi

printf 'persistent-auth\n' >"$PERSISTENT_HOME/auth.json"
FAKE_HEALTH_TRANSIENT_ONCE=1 "$ROOT/scripts/prepare-machine.sh"
[[ "$(cat "$PERSISTENT_HOME/auth.json")" == "persistent-auth" ]] ||
  fail "repeated preparation changed persistent authentication"
[[ "$(cat "$FORMAT_COUNT")" == "1" ]] || fail "repeated preparation reformatted the managed disk"
[[ "$(rg -c '/home/azureadmin/projects ext4' "$FSTAB")" == "1" ]] ||
  fail "repeated preparation duplicated the fstab entry"
rg -F 'systemctl start codex-remote-control-health.service' "$REMOTE_CALL_LOG" >/dev/null ||
  fail "authenticated repeated preparation did not activate the checked-in health service"
rg -F 'systemctl start codex-remote-control-bootstrap.service' "$REMOTE_CALL_LOG" >/dev/null ||
  fail "authenticated repeated preparation did not activate the checked-in bootstrap service"
[[ "$(cat "$HEALTH_START_COUNT")" == "2" ]] ||
  fail "authenticated preparation did not retry one transient post-bootstrap health failure"

: >"$REMOTE_CALL_LOG"
rm -f "$SSH_SOCKET_STATE" "$SSH_SERVICE_STATE"
"$ROOT/scripts/prepare-machine.sh"
[[ -f "$SSH_SERVICE_STATE" ]] ||
  fail "preparation did not start SSH when neither service nor socket was active"
rg -F 'systemctl enable --now ssh' "$REMOTE_CALL_LOG" >/dev/null

rm -f "$LOCAL_SSH_CONFIG" "$LOCAL_KNOWN_HOSTS"
READBACK_FAILURE_LOG="$FIXTURE/readback-failure.log"
if FAKE_DROP_PREPARE_MARKER=1 "$ROOT/scripts/prepare-machine.sh" >"$READBACK_FAILURE_LOG" 2>&1; then
  fail "missing preparation marker unexpectedly succeeded"
fi
rg -F 'REMOTE_PREPARATION_DIAGNOSTIC=fixture-readiness-failure' "$READBACK_FAILURE_LOG" >/dev/null ||
  fail "missing-readiness failure hid the Azure Run Command diagnostic"
if rg -F 'REMOTE_PREPARATION_OMITTED=unbounded-output-must-not-surface' "$READBACK_FAILURE_LOG" >/dev/null; then
  fail "missing-readiness failure printed the unbounded Azure Run Command response"
fi
python3 - "$READBACK_FAILURE_LOG" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
header = "Azure Run Command output (bounded tail):\n"
footer = "\nMachine preparation failed:"
start = text.index(header) + len(header)
end = text.index(footer, start)
diagnostic = text[start:end]
if len(diagnostic) > 4097:
    raise SystemExit(f"bounded diagnostic contains {len(diagnostic)} characters")
PY
rg -F 'systemctl reload ssh' "$REMOTE_CALL_LOG" >/dev/null ||
  fail "active SSH service was not reloaded during repeated preparation"
[[ ! -e "$LOCAL_SSH_CONFIG" && ! -e "$LOCAL_KNOWN_HOSTS" ]] ||
  fail "missing readiness marker wrote local SSH trust files"
"$ROOT/scripts/prepare-machine.sh"

: >"$CALL_LOG"
"$ROOT/scripts/codex-pair.sh" sign-in
rg -F 'ssh -t codex-on-vm-vpn ' "$CALL_LOG" >/dev/null
rg -F 'login --device-auth' "$CALL_LOG" >/dev/null
if rg -F 'network nsg rule' "$CALL_LOG" >/dev/null; then
  fail "sign-in mutated public ingress"
fi
if rg -F 'remote-control start' "$CALL_LOG" >/dev/null ||
  rg -F 'remote-control pair' "$CALL_LOG" >/dev/null; then
  fail "sign-in also started or paired Remote Control"
fi

: >"$CALL_LOG"
"$ROOT/scripts/codex-pair.sh" pair
rg -F 'codex-on-vm-vpn' "$CALL_LOG" >/dev/null
rg -F 'login status' "$CALL_LOG" >/dev/null
rg -F 'remote-control start' "$CALL_LOG" >/dev/null
rg -F 'remote-control pair' "$CALL_LOG" >/dev/null
if rg -F 'login --device-auth' "$CALL_LOG" >/dev/null; then
  fail "pairing attempted device authentication"
fi

: >"$CALL_LOG"
if FAKE_LOGIN_MISSING=1 "$ROOT/scripts/codex-pair.sh" pair; then
  fail "pairing without a login unexpectedly succeeded"
fi
rg -F 'scripts/codex-vm.sh sign-in' "$CALL_LOG" >/dev/null ||
  fail "missing-login pairing omitted the local sign-in instruction"
if rg -F 'remote-control start' "$CALL_LOG" >/dev/null ||
  rg -F 'remote-control pair' "$CALL_LOG" >/dev/null; then
  fail "missing-login pairing reached Remote Control"
fi

: >"$CALL_LOG"
if FAKE_PAIR_FAIL=1 "$ROOT/scripts/codex-pair.sh" pair; then
  fail "injected pairing failure unexpectedly succeeded"
fi

: >"$CALL_LOG"
if FAKE_VPN_UNREACHABLE=1 "$ROOT/scripts/codex-pair.sh" pair; then
  fail "pairing with a disconnected VPN unexpectedly succeeded"
fi
if rg -F 'network nsg rule' "$CALL_LOG" >/dev/null || rg -F 'remote-control start' "$CALL_LOG" >/dev/null; then
  fail "disconnected pairing crossed a mutation edge"
fi

printf 'Local preparation, sign-in, and pairing scenario passed.\n'
