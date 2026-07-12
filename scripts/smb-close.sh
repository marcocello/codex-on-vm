#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${CODEX_SMB_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/smb-access.json}"

fail() {
  printf 'SMB close failed: %s\n' "$1" >&2
  exit 1
}

for command in az python3 diskutil; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
[[ -f "$STATE_FILE" ]] || fail "no SMB access session is recorded"

IFS=$'\t' read -r RESOURCE_GROUP STORAGE_ACCOUNT PUBLIC_IP MOUNT_PATH <<<"$(STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json
import os

with open(os.environ["STATE_FILE"], encoding="utf-8") as handle:
    value = json.load(handle)
print("\t".join(value[key] for key in ("resource_group", "storage_account", "public_ip", "mount_path")))
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

rm -f "$STATE_FILE"
printf 'SMB unmounted and temporary storage firewall rule removed.\n'
