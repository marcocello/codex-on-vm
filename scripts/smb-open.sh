#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
STATE_FILE="${CODEX_SMB_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/smb-access.json}"
LOCK_DIR="${STATE_FILE}.lock"
CLIPBOARD_TTL_SECONDS="${CODEX_SMB_CLIPBOARD_TTL_SECONDS:-60}"
RULE_ADDED=0
KEY_EXPOSED=0
SESSION_STATE_OWNED=0
LOCK_HELD=0
SUCCESS=0
RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
PUBLIC_IP=""
KEY2_FINGERPRINT=""
CLIPBOARD_GUARD_PID=""

fail() {
  printf 'SMB open failed: %s\n' "$1" >&2
  return 1
}

fingerprint() {
  shasum -a 256 | awk '{print $1}'
}

clear_clipboard() {
  if [[ -n "$CLIPBOARD_GUARD_PID" ]]; then
    kill "$CLIPBOARD_GUARD_PID" >/dev/null 2>&1 || true
    wait "$CLIPBOARD_GUARD_PID" >/dev/null 2>&1 || true
    CLIPBOARD_GUARD_PID=""
  fi
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy </dev/null 2>/dev/null || true
  fi
}

renew_key2() {
  local old_fingerprint="$1"
  local new_key new_fingerprint
  new_key="$(az storage account keys renew \
    --resource-group "$RESOURCE_GROUP" \
    --account-name "$STORAGE_ACCOUNT" \
    --key key2 \
    --query "[?keyName=='key2'].value | [0]" \
    --output tsv \
    --only-show-errors)" || return 1
  [[ -n "$new_key" ]] || return 1
  new_fingerprint="$(printf '%s' "$new_key" | fingerprint)"
  unset new_key
  [[ -z "$old_fingerprint" || "$new_fingerprint" != "$old_fingerprint" ]]
}

cleanup_on_exit() {
  local status=$?
  local rule_cleanup_ok=1
  local rotation_ok=1
  set +e
  clear_clipboard

  if [[ "$SUCCESS" != "1" && "$RULE_ADDED" == "1" ]]; then
    if az storage account network-rule remove \
      --resource-group "$RESOURCE_GROUP" \
      --account-name "$STORAGE_ACCOUNT" \
      --ip-address "$PUBLIC_IP" \
      --only-show-errors >/dev/null 2>&1; then
      for _attempt in {1..30}; do
        RULE_COUNT="$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" --query "networkRuleSet.ipRules[?ipAddressOrRange=='$PUBLIC_IP'] | length(@)" --output tsv 2>/dev/null)"
        if [[ "$RULE_COUNT" == "0" ]]; then
          rule_cleanup_ok=0
          break
        fi
        sleep 2
      done
    fi
    if [[ "$rule_cleanup_ok" != "0" ]]; then
      printf 'SMB open cleanup warning: firewall-rule removal was not verified; recovery state was retained for scripts/smb-close.sh\n' >&2
    fi
  else
    rule_cleanup_ok=0
  fi

  if [[ "$SUCCESS" != "1" && "$KEY_EXPOSED" == "1" ]]; then
    if renew_key2 "$KEY2_FINGERPRINT" >/dev/null 2>&1; then
      rotation_ok=0
    else
      printf 'SMB open cleanup warning: key2 rotation failed; recovery state was retained for scripts/smb-close.sh\n' >&2
    fi
  else
    rotation_ok=0
  fi

  if [[ "$SUCCESS" != "1" && "$SESSION_STATE_OWNED" == "1" && "$rule_cleanup_ok" == "0" && "$rotation_ok" == "0" ]]; then
    rm -f "$STATE_FILE"
  fi

  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
for command in az terraform python3 curl nc mount_smbfs pbcopy shasum awk; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
[[ "$CLIPBOARD_TTL_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "CODEX_SMB_CLIPBOARD_TTL_SECONDS must be a positive integer"

install -d -m 0700 "$(dirname "$STATE_FILE")"
if ! mkdir "$LOCK_DIR"; then
  fail "another SMB lifecycle operation is already running"
fi
LOCK_HELD=1
[[ ! -e "$STATE_FILE" ]] || fail "an SMB access session is already recorded; run scripts/smb-close.sh"

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP STORAGE_ACCOUNT FILE_SHARE DEFAULT_MOUNT <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["CONNECTION"])
print("\t".join(value[key] for key in ("subscription_id", "resource_group_name", "storage_account_name", "file_share_name", "local_mount_path")))
PY
)"
MOUNT_PATH="${AZURE_FILES_LOCAL_MOUNT_PATH:-$DEFAULT_MOUNT}"
ACTIVE_SUBSCRIPTION="$(az account show --query id --output tsv)"
[[ "$ACTIVE_SUBSCRIPTION" == "$SUBSCRIPTION_ID" ]] || fail "Azure CLI is using a different subscription"

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org)"
PUBLIC_IP="$PUBLIC_IP" python3 - <<'PY'
import ipaddress
import os

address = ipaddress.IPv4Address(os.environ["PUBLIC_IP"])
if not address.is_global:
    raise SystemExit("current public IPv4 address is not globally routable")
PY

SMB_HOST="$STORAGE_ACCOUNT.file.core.windows.net"
nc -G 5 -z "$SMB_HOST" 445 || fail "outbound TCP 445 is blocked on this network"

az storage account network-rule add \
  --resource-group "$RESOURCE_GROUP" \
  --account-name "$STORAGE_ACCOUNT" \
  --ip-address "$PUBLIC_IP" \
  --only-show-errors >/dev/null
RULE_ADDED=1

for _attempt in {1..30}; do
  RULE_COUNT="$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" --query "networkRuleSet.ipRules[?ipAddressOrRange=='$PUBLIC_IP'] | length(@)" --output tsv)"
  [[ "$RULE_COUNT" == "1" ]] && break
  sleep 2
done
[[ "$RULE_COUNT" == "1" ]] || fail "temporary storage firewall rule was not visible"

STORAGE_KEY="$(az storage account keys list \
  --resource-group "$RESOURCE_GROUP" \
  --account-name "$STORAGE_ACCOUNT" \
  --query "[?keyName=='key2'].value | [0]" \
  --output tsv)"
[[ -n "$STORAGE_KEY" ]] || fail "Azure Storage key2 was not returned"
KEY2_FINGERPRINT="$(printf '%s' "$STORAGE_KEY" | fingerprint)"

STATE_FILE="$STATE_FILE" RESOURCE_GROUP="$RESOURCE_GROUP" STORAGE_ACCOUNT="$STORAGE_ACCOUNT" PUBLIC_IP="$PUBLIC_IP" MOUNT_PATH="$MOUNT_PATH" KEY2_FINGERPRINT="$KEY2_FINGERPRINT" python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["STATE_FILE"])
payload = {key.lower(): os.environ[key] for key in ("RESOURCE_GROUP", "STORAGE_ACCOUNT", "PUBLIC_IP", "MOUNT_PATH", "KEY2_FINGERPRINT")}
temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.chmod(0o600)
temporary.replace(path)
PY
SESSION_STATE_OWNED=1

printf '%s' "$STORAGE_KEY" | pbcopy
KEY_EXPOSED=1
unset STORAGE_KEY
python3 - "$CLIPBOARD_TTL_SECONDS" <<'PY' &
import subprocess
import sys
import time

time.sleep(int(sys.argv[1]))
subprocess.run(["pbcopy"], input=b"", check=False)
PY
CLIPBOARD_GUARD_PID=$!

mkdir -p "$MOUNT_PATH"
printf 'Storage key2 is on the clipboard for at most %s seconds. Paste it at the macOS password prompt.\n' "$CLIPBOARD_TTL_SECONDS"
mount_smbfs "//$STORAGE_ACCOUNT@$SMB_HOST/$FILE_SHARE" "$MOUNT_PATH"
clear_clipboard
mount | grep -F " on $MOUNT_PATH " >/dev/null || fail "the SMB share did not mount"

SUCCESS=1
printf 'SMB mounted at %s. Run scripts/smb-close.sh when finished.\n' "$MOUNT_PATH"
