#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || {
  printf 'usage: %s <extracted-root> <fixture-root>\n' "$0" >&2
  exit 64
}

EXTRACTED="$1"
FIXTURE_ROOT="$2/openvpn-scenario"
MAC_HELPER="$EXTRACTED/scripts/openvpn-setup.sh"
VM_HELPER="$EXTRACTED/vm-scripts/configure-codex-openvpn.sh"
REAL_PATH="$PATH"
FAKE_BIN="$FIXTURE_ROOT/bin"
FAKE_VM_ROOT="$FIXTURE_ROOT/vm"
LOCAL_VPN_ROOT="$FIXTURE_ROOT/mac/openvpn"
SSH_CONFIG="$FIXTURE_ROOT/mac/ssh/config"
KNOWN_HOSTS="$FIXTURE_ROOT/mac/ssh/known-hosts"
SYSTEMD_STATE="$FIXTURE_ROOT/vm-systemd-active"
SYSTEMD_ENABLED="$FIXTURE_ROOT/vm-systemd-enabled"
SYSTEMD_FAIL_ONCE="$FIXTURE_ROOT/vm-systemd-fail-once"
SSH_LOSE_RESULT_ONCE="$FIXTURE_ROOT/ssh-lose-result-once"
CALL_LOG="$FIXTURE_ROOT/calls.log"
OUTPUT_LOG="$FIXTURE_ROOT/output.log"
PERSISTENT_SERVER="$FAKE_VM_ROOT/home/azureadmin/projects/.codex-on-vm/openvpn/server"
RUNTIME_SERVER="$FAKE_VM_ROOT/etc/openvpn/server"

fail() {
  printf 'OpenVPN scenario failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p \
  "$FAKE_BIN" \
  "$FAKE_VM_ROOT/home/azureadmin/projects" \
  "$(dirname "$SSH_CONFIG")"
printf 'codex-on-vm.example.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureHostKey\n' >"$KNOWN_HOSTS"
chmod 0600 "$KNOWN_HOSTS"
printf 'fixture SSH key placeholder\n' >"$FIXTURE_ROOT/mac/ssh/id_ed25519"
chmod 0600 "$FIXTURE_ROOT/mac/ssh/id_ed25519"
: >"$CALL_LOG"

cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF

cat >"$FAKE_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform' >>"$FAKE_CALL_LOG"
printf '\t%q' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
cat <<JSON
{"subscription_id":"00000000-0000-0000-0000-000000000000","resource_group_name":"prod-codex-on-vm-rg","network_security_group_name":"prod-codex-on-vm-nsg","vm_name":"prod-codex-on-vm-vm","ssh_fqdn":"codex-on-vm.example.invalid","ssh_username":"azureadmin","workspace_mount_path":"/home/azureadmin/projects","mac_private_key_path":"$FAKE_MAC_PRIVATE_KEY","ssh_host_config_path":"$FAKE_SSH_CONFIG","ssh_known_hosts_path":"$FAKE_KNOWN_HOSTS","openvpn_rule_name":"AllowOpenVpn","openvpn_port":1194,"openvpn_network":"10.250.0.0","openvpn_netmask":"255.255.255.0","openvpn_server_address":"10.250.0.1","openvpn_ssh_alias":"codex-on-vm-vpn","openvpn_local_root_path":"$FAKE_LOCAL_VPN_ROOT","openvpn_client_profile_path":"$FAKE_LOCAL_VPN_ROOT/codex-on-vm.ovpn"}
JSON
EOF

cat >"$FAKE_BIN/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'az' >>"$FAKE_CALL_LOG"
printf '\t%q' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
printf 'Azure must not be called by VPN-only trust maintenance: %s\n' "$*" >&2
exit 91
EOF

cat >"$FAKE_BIN/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp' >>"$FAKE_CALL_LOG"
printf '\t%q' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
target="${!#}"
[[ "$target" == codex-on-vm-vpn:* ]] || exit 92
remote_path="${target#*:}"
[[ "$remote_path" != "$target" && "$remote_path" == /* ]] || exit 2
mkdir -p "$remote_path"
index=1
while ((index < $#)); do
  source_path="${!index}"
  cp "$source_path" "$remote_path/"
  index=$((index + 1))
done
EOF

cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF

cat >"$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl' >>"$FAKE_CALL_LOG"
printf '\t%q' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
case "${1:-}" in
  daemon-reload)
    ;;
  enable)
    touch "$FAKE_SYSTEMD_ENABLED"
    if [[ " $* " == *" --now "* ]]; then
      touch "$FAKE_SYSTEMD_STATE"
    fi
    ;;
  restart | start)
    if [[ -f "$FAKE_SYSTEMD_FAIL_ONCE" ]]; then
      rm -f "$FAKE_SYSTEMD_FAIL_ONCE"
      exit 31
    fi
    touch "$FAKE_SYSTEMD_STATE"
    ;;
  disable)
    rm -f "$FAKE_SYSTEMD_ENABLED"
    if [[ " $* " == *" --now "* ]]; then
      rm -f "$FAKE_SYSTEMD_STATE"
    fi
    ;;
  is-active)
    [[ -f "$FAKE_SYSTEMD_STATE" ]]
    ;;
  *)
    printf 'unexpected fake systemctl invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

cat >"$FAKE_BIN/openvpn" <<'EOF'
#!/usr/bin/env bash
printf 'OpenVPN 2.6.19 fixture\n'
EOF

cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh' >>"$FAKE_CALL_LOG"
printf '\t%q' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"
if [[ " $* " == *" BatchMode=yes "* ]]; then
  [[ "${FAKE_VPN_REACHABLE:-0}" == "1" ]]
  exit
fi
[[ $# -ge 1 ]]
[[ "$1" == "codex-on-vm-vpn" ]] || exit 93
shift
if [[ $# -eq 0 ]]; then
  exit 0
fi
remote_command="$1"
set +e
CODEX_VM_ROOT="$FAKE_VM_ROOT" \
CODEX_VM_TEST_MODE=1 \
PATH="$FAKE_BIN:$REAL_PATH" \
/bin/bash -c "$remote_command"
status=$?
set -e
if [[ "$status" == "0" && "$remote_command" == *"configure-codex-openvpn.sh"* && -f "$FAKE_SSH_LOSE_RESULT_ONCE" ]]; then
  rm -f "$FAKE_SSH_LOSE_RESULT_ONCE"
  exit 88
fi
exit "$status"
EOF

chmod +x "$FAKE_BIN"/*

export PATH="$FAKE_BIN:$REAL_PATH"
export FAKE_BIN REAL_PATH FAKE_VM_ROOT
export FAKE_LOCAL_VPN_ROOT="$LOCAL_VPN_ROOT"
export FAKE_MAC_PRIVATE_KEY="$FIXTURE_ROOT/mac/ssh/id_ed25519"
export FAKE_SSH_CONFIG="$SSH_CONFIG"
export FAKE_KNOWN_HOSTS="$KNOWN_HOSTS"
export FAKE_CALL_LOG="$CALL_LOG"
export FAKE_SYSTEMD_STATE="$SYSTEMD_STATE"
export FAKE_SYSTEMD_ENABLED="$SYSTEMD_ENABLED"
export FAKE_SYSTEMD_FAIL_ONCE="$SYSTEMD_FAIL_ONCE"
export FAKE_SSH_LOSE_RESULT_ONCE="$SSH_LOSE_RESULT_ONCE"
export CODEX_VM_TEST_MODE=1
export FAKE_VPN_REACHABLE=1

run_setup() {
  if ! TMPDIR="$FIXTURE_ROOT/tmp" "$MAC_HELPER" "$@" >>"$OUTPUT_LOG" 2>&1; then
    printf 'OpenVPN setup output (bounded tail):\n' >&2
    tail -n 80 "$OUTPUT_LOG" >&2 || true
    return 1
  fi
}

mkdir -p "$FIXTURE_ROOT/tmp"
if TMPDIR="$FIXTURE_ROOT/tmp" "$MAC_HELPER" >>"$OUTPUT_LOG" 2>&1; then
  fail "ordinary repair generated replacement trust when local trust was missing"
fi
rg -F 'existing OpenVPN trust is missing' "$OUTPUT_LOG" >/dev/null ||
  fail "missing-trust repair did not explain how to restore or rotate trust"
[[ ! -e "$LOCAL_VPN_ROOT" ]] ||
  fail "missing-trust repair changed the local OpenVPN root"
if rg -F $'scp\t' "$CALL_LOG" >/dev/null ||
  rg -F $'systemctl\t' "$CALL_LOG" >/dev/null ||
  rg -F $'az\t' "$CALL_LOG" >/dev/null; then
  fail "missing-trust repair crossed a remote mutation edge"
fi

: >"$CALL_LOG"
run_setup --rotate

for required in \
  ca.crt ca.key server.crt server.key client.crt client.key tls-crypt.key \
  server.conf codex-on-vm.ovpn; do
  [[ -f "$LOCAL_VPN_ROOT/$required" ]] || fail "local credential is missing: $required"
done
[[ -d "$PERSISTENT_SERVER" && -d "$RUNTIME_SERVER" ]] ||
  fail "server material was not installed to persistent and runtime locations"
for required in ca.crt server.crt server.key tls-crypt.key codex-vm.conf; do
  [[ -f "$PERSISTENT_SERVER/$required" ]] || fail "persistent server file is missing: $required"
  [[ -f "$RUNTIME_SERVER/$required" ]] || fail "runtime server file is missing: $required"
done
[[ ! -e "$PERSISTENT_SERVER/ca.key" && ! -e "$RUNTIME_SERVER/ca.key" ]] ||
  fail "the CA private key was copied to the VM"
[[ -f "$SYSTEMD_STATE" && -f "$SYSTEMD_ENABLED" ]] ||
  fail "OpenVPN was not enabled and started"
if rg -F $'az\t' "$CALL_LOG" >/dev/null; then
  fail "VPN setup called Azure"
fi

openssl verify -CAfile "$LOCAL_VPN_ROOT/ca.crt" \
  "$LOCAL_VPN_ROOT/server.crt" "$LOCAL_VPN_ROOT/client.crt" >/dev/null
python3 - "$LOCAL_VPN_ROOT" "$PERSISTENT_SERVER" <<'PY'
import pathlib
import stat
import sys

local = pathlib.Path(sys.argv[1])
persistent = pathlib.Path(sys.argv[2])
if stat.S_IMODE(local.stat().st_mode) != 0o700:
    raise SystemExit("local OpenVPN root is not mode 0700")
for path in local.iterdir():
    if path.is_file() and stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise SystemExit(f"local OpenVPN file is not mode 0600: {path.name}")
if stat.S_IMODE(persistent.stat().st_mode) != 0o700:
    raise SystemExit("persistent server root is not mode 0700")
for name in ("server.key", "tls-crypt.key"):
    if stat.S_IMODE((persistent / name).stat().st_mode) != 0o600:
        raise SystemExit(f"persistent private file is not mode 0600: {name}")
PY

PROFILE="$LOCAL_VPN_ROOT/codex-on-vm.ovpn"
SERVER_CONFIG="$PERSISTENT_SERVER/codex-vm.conf"
for expected in \
  'client' \
  'proto udp' \
  'remote codex-on-vm.example.invalid 1194' \
  'remote-cert-tls server' \
  'tls-version-min 1.2' \
  '<ca>' '<cert>' '<key>' '<tls-crypt>'; do
  rg -F "$expected" "$PROFILE" >/dev/null || fail "client profile is missing: $expected"
done
for rejected in redirect-gateway dhcp-option comp-lzo compress; do
  if rg -i "^[[:space:]]*(push[[:space:]]+\")?$rejected" "$PROFILE" "$SERVER_CONFIG" >/dev/null; then
    fail "split-tunnel configuration contains rejected directive: $rejected"
  fi
done
for expected in \
  'port 1194' \
  'proto udp' \
  'server 10.250.0.0 255.255.255.0' \
  'verify-client-cert require' \
  'remote-cert-tls client' \
  'tls-version-min 1.2' \
  'tls-crypt /etc/openvpn/server/tls-crypt.key'; do
  rg -F "$expected" "$SERVER_CONFIG" >/dev/null || fail "server config is missing: $expected"
done
rg -F 'Host codex-on-vm-vpn' "$SSH_CONFIG" >/dev/null || fail "VPN SSH alias is missing"
rg -F 'HostName 10.250.0.1' "$SSH_CONFIG" >/dev/null || fail "VPN SSH alias has the wrong address"
rg -F 'HostKeyAlias codex-on-vm.example.invalid' "$SSH_CONFIG" >/dev/null ||
  fail "VPN SSH alias does not reuse pinned host identity"
if rg -Fx 'Host codex-on-vm' "$SSH_CONFIG" >/dev/null; then
  fail "public SSH alias remains in the generated config"
fi

if rg -n 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|OpenVPN Static key' "$CALL_LOG" "$OUTPUT_LOG" >/dev/null; then
  fail "setup leaked private material to calls or output"
fi

initial_fingerprint="$(openssl x509 -in "$LOCAL_VPN_ROOT/client.crt" -noout -fingerprint -sha256)"
run_setup
repeat_fingerprint="$(openssl x509 -in "$LOCAL_VPN_ROOT/client.crt" -noout -fingerprint -sha256)"
[[ "$repeat_fingerprint" == "$initial_fingerprint" ]] || fail "ordinary setup rotated credentials"

run_setup --rotate
rotated_fingerprint="$(openssl x509 -in "$LOCAL_VPN_ROOT/client.crt" -noout -fingerprint -sha256)"
[[ "$rotated_fingerprint" != "$initial_fingerprint" ]] || fail "explicit rotation preserved the old client certificate"
backup_dir="$(find "$(dirname "$LOCAL_VPN_ROOT")" -maxdepth 1 -type d -name 'openvpn.backup-*' -print -quit)"
[[ -n "$backup_dir" ]] || fail "rotation did not retain a private local recovery backup"

pre_ambiguous_fingerprint="$rotated_fingerprint"
touch "$SSH_LOSE_RESULT_ONCE"
if run_setup --rotate; then
  fail "injected lost SSH result unexpectedly reported success"
fi
post_ambiguous_fingerprint="$(openssl x509 -in "$LOCAL_VPN_ROOT/client.crt" -noout -fingerprint -sha256)"
[[ "$post_ambiguous_fingerprint" != "$pre_ambiguous_fingerprint" ]] ||
  fail "lost SSH result did not retain the remotely committed replacement"
[[ "$(openssl x509 -in "$LOCAL_VPN_ROOT/ca.crt" -noout -fingerprint -sha256)" == \
  "$(openssl x509 -in "$PERSISTENT_SERVER/ca.crt" -noout -fingerprint -sha256)" ]] ||
  fail "lost SSH result split local and remote trust"

stable_local_fingerprint="$post_ambiguous_fingerprint"
stable_remote_fingerprint="$(openssl x509 -in "$PERSISTENT_SERVER/ca.crt" -noout -fingerprint -sha256)"
touch "$SYSTEMD_FAIL_ONCE"
if run_setup --rotate; then
  fail "injected OpenVPN service failure unexpectedly succeeded"
fi
[[ "$(openssl x509 -in "$LOCAL_VPN_ROOT/client.crt" -noout -fingerprint -sha256)" == "$stable_local_fingerprint" ]] ||
  fail "failed rotation changed the authoritative local client"
[[ "$(openssl x509 -in "$PERSISTENT_SERVER/ca.crt" -noout -fingerprint -sha256)" == "$stable_remote_fingerprint" ]] ||
  fail "failed rotation changed the authoritative remote CA"
rm -rf "$RUNTIME_SERVER"
CODEX_VM_ROOT="$FAKE_VM_ROOT" CODEX_VM_TEST_MODE=1 \
  "$VM_HELPER" azureadmin /home/azureadmin/projects 1194 \
  10.250.0.0 255.255.255.0 10.250.0.1
cmp -s "$PERSISTENT_SERVER/server.crt" "$RUNTIME_SERVER/server.crt" ||
  fail "VM replacement recovery did not restore runtime server material"

: >"$CALL_LOG"
disconnected_fingerprint="$(openssl x509 -in "$LOCAL_VPN_ROOT/client.crt" -noout -fingerprint -sha256)"
if FAKE_VPN_REACHABLE=0 run_setup --rotate; then
  fail "VPN-disconnected rotation unexpectedly succeeded"
fi
[[ "$(openssl x509 -in "$LOCAL_VPN_ROOT/client.crt" -noout -fingerprint -sha256)" == "$disconnected_fingerprint" ]] ||
  fail "VPN-disconnected rotation changed local trust"
if rg -F $'scp\t' "$CALL_LOG" >/dev/null || rg -F $'systemctl\t' "$CALL_LOG" >/dev/null || rg -F $'az\t' "$CALL_LOG" >/dev/null; then
  fail "VPN-disconnected rotation crossed a remote mutation edge"
fi

if rg -n 'codex-on-vm:' "$CALL_LOG" >/dev/null; then
  fail "a public SSH alias entered VPN-only calls"
fi
printf 'OpenVPN fixture: VPN-only transport, real certificates, persistence, idempotency, rotation, rollback, and disconnected fail-closed behavior\n'
