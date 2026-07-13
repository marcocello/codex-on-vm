#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${CODEX_SMB_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/smb-access.json}"
LOCK_DIR="${STATE_FILE}.lock"
LOCK_HELD=0

fail() {
  printf 'SMB close failed: %s\n' "$1" >&2
  return 1
}

fingerprint() {
  shasum -a 256 | awk '{print $1}'
}

cleanup_on_exit() {
  local status=$?
  pbcopy </dev/null 2>/dev/null || true
  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

for command in az python3 diskutil pbcopy shasum awk; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

install -d -m 0700 "$(dirname "$STATE_FILE")"
if ! mkdir "$LOCK_DIR"; then
  fail "another SMB lifecycle operation is already running"
fi
LOCK_HELD=1
[[ -f "$STATE_FILE" ]] || fail "no SMB access session is recorded"

IFS=$'\t' read -r RESOURCE_GROUP STORAGE_ACCOUNT PUBLIC_IP MOUNT_PATH KEY2_FINGERPRINT <<<"$(STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json
import os

with open(os.environ["STATE_FILE"], encoding="utf-8") as handle:
    value = json.load(handle)
print("\t".join(value.get(key, "") for key in ("resource_group", "storage_account", "public_ip", "mount_path", "key2_fingerprint")))
PY
)"

if mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
  diskutil unmount "$MOUNT_PATH" >/dev/null || fail "could not unmount $MOUNT_PATH"
fi

az storage account network-rule remove \
  --resource-group "$RESOURCE_GROUP" \
  --account-name "$STORAGE_ACCOUNT" \
  --ip-address "$PUBLIC_IP" \
  --only-show-errors >/dev/null

for _attempt in {1..30}; do
  RULE_COUNT="$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT" --query "networkRuleSet.ipRules[?ipAddressOrRange=='$PUBLIC_IP'] | length(@)" --output tsv)"
  [[ "$RULE_COUNT" == "0" ]] && break
  sleep 2
done
[[ "$RULE_COUNT" == "0" ]] || fail "temporary storage firewall rule is still present"

NEW_KEY="$(az storage account keys renew \
  --resource-group "$RESOURCE_GROUP" \
  --account-name "$STORAGE_ACCOUNT" \
  --key key2 \
  --query "[?keyName=='key2'].value | [0]" \
  --output tsv \
  --only-show-errors)" || fail "could not rotate Storage key2; recovery state was retained"
[[ -n "$NEW_KEY" ]] || fail "Storage key2 rotation returned no key; recovery state was retained"
NEW_FINGERPRINT="$(printf '%s' "$NEW_KEY" | fingerprint)"
unset NEW_KEY
[[ -z "$KEY2_FINGERPRINT" || "$NEW_FINGERPRINT" != "$KEY2_FINGERPRINT" ]] || fail "Storage key2 did not change; recovery state was retained"

rm -f "$STATE_FILE"
printf 'SMB unmounted, temporary firewall rule removed, and Storage key2 rotated.\n'
