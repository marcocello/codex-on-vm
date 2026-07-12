#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
STATE_FILE="${CODEX_SMB_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/smb-access.json}"
RULE_ADDED=0
RESOURCE_GROUP=""
STORAGE_ACCOUNT=""
PUBLIC_IP=""

fail() {
  printf 'SMB open failed: %s\n' "$1" >&2
  if [[ "$RULE_ADDED" == "1" ]]; then
    cleanup_failure
    RULE_ADDED=0
  fi
  exit 1
}

cleanup_failure() {
  pbcopy </dev/null 2>/dev/null || true
  if [[ "$RULE_ADDED" == "1" ]]; then
    az storage account network-rule remove \
      --resource-group "$RESOURCE_GROUP" \
      --account-name "$STORAGE_ACCOUNT" \
      --ip-address "$PUBLIC_IP" \
      --only-show-errors >/dev/null 2>&1 || true
    rm -f "$STATE_FILE"
  fi
}
trap cleanup_failure ERR INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
for command in az terraform python3 curl nc mount_smbfs pbcopy; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
[[ ! -e "$STATE_FILE" ]] || fail "an SMB access session is already recorded; run scripts/smb-close"

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

install -d -m 0700 "$(dirname "$STATE_FILE")"
STATE_FILE="$STATE_FILE" RESOURCE_GROUP="$RESOURCE_GROUP" STORAGE_ACCOUNT="$STORAGE_ACCOUNT" PUBLIC_IP="$PUBLIC_IP" MOUNT_PATH="$MOUNT_PATH" python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["STATE_FILE"])
payload = {key.lower(): os.environ[key] for key in ("RESOURCE_GROUP", "STORAGE_ACCOUNT", "PUBLIC_IP", "MOUNT_PATH")}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
path.chmod(0o600)
PY

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
printf '%s' "$STORAGE_KEY" | pbcopy
unset STORAGE_KEY

mkdir -p "$MOUNT_PATH"
printf 'Storage key2 is on the clipboard. Paste it at the macOS password prompt.\n'
mount_smbfs "//$STORAGE_ACCOUNT@$SMB_HOST/$FILE_SHARE" "$MOUNT_PATH"
pbcopy </dev/null
mount | grep -F " on $MOUNT_PATH " >/dev/null || fail "the SMB share did not mount"

trap - ERR INT TERM
printf 'SMB mounted at %s. Run scripts/smb-close when finished.\n' "$MOUNT_PATH"
