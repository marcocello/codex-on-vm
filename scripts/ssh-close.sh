#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
STATE_FILE="${CODEX_SSH_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/ssh-access.json}"
LOCK_DIR="${STATE_FILE}.lock"
RULE_NAME=""
LOCK_HELD=0

fail() {
  printf 'SSH close failed: %s\n' "$1" >&2
  exit 1
}

cleanup_on_exit() {
  local status=$?
  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

for command in az python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
install -d -m 0700 "$(dirname "$STATE_FILE")"
mkdir "$LOCK_DIR" 2>/dev/null || fail "another temporary SSH operation is running"
LOCK_HELD=1

if [[ -f "$STATE_FILE" ]]; then
  IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP NSG_NAME RULE_NAME <<<"$(STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json
import os

with open(os.environ["STATE_FILE"], encoding="utf-8") as handle:
    value = json.load(handle)
print("\t".join(value[key] for key in ("subscription_id", "resource_group", "nsg_name", "rule_name")))
PY
)"
else
  CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
  IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP NSG_NAME RULE_NAME <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["CONNECTION"])
print("\t".join(value[key] for key in ("subscription_id", "resource_group_name", "network_security_group_name", "temporary_ssh_rule_name")))
PY
)"
fi

[[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] || fail "Azure CLI is using a different subscription; recovery state was retained"

if az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
  az network nsg rule delete --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null
fi
for _attempt in {1..30}; do
  if ! az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
    rm -f "$STATE_FILE"
    printf 'Temporary SSH rule is closed.\n'
    exit 0
  fi
  sleep 2
done
fail "temporary SSH rule is still present; recovery state was retained"
