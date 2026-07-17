#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
STATE_FILE="${CODEX_SSH_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-on-vm/ssh-access.json}"
LOCK_DIR="${STATE_FILE}.lock"
RULE_NAME=""
LOCK_HELD=0
RULE_CREATED=0
SUCCESS=0
RESOURCE_GROUP=""
NSG_NAME=""

fail() {
  printf 'SSH open failed: %s\n' "$1" >&2
  exit 1
}

cleanup_on_exit() {
  local status=$?
  set +e
  if [[ "$SUCCESS" != "1" && "$RULE_CREATED" == "1" ]]; then
    az network nsg rule delete --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1
    if ! az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
      rm -f "$STATE_FILE"
    else
      printf 'SSH open cleanup warning: the temporary rule may remain; run scripts/ssh-close.sh\n' >&2
    fi
  fi
  if [[ "$LOCK_HELD" == "1" ]]; then
    rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

for command in az curl python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
install -d -m 0700 "$(dirname "$STATE_FILE")"
mkdir "$LOCK_DIR" 2>/dev/null || fail "another temporary SSH operation is running"
LOCK_HELD=1
[[ ! -e "$STATE_FILE" ]] || fail "temporary SSH state already exists; run scripts/ssh-close.sh"

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP NSG_NAME RULE_NAME SSH_ALIAS <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["CONNECTION"])
print("\t".join(value[key] for key in ("subscription_id", "resource_group_name", "network_security_group_name", "temporary_ssh_rule_name", "ssh_alias")))
PY
)"
[[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] || fail "Azure CLI is using a different subscription"

PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org)"
PUBLIC_IP_CIDR="$(PUBLIC_IP="$PUBLIC_IP" python3 - <<'PY'
import ipaddress
import os

address = ipaddress.IPv4Address(os.environ["PUBLIC_IP"])
if not address.is_global:
    raise SystemExit("current public IPv4 address is not globally routable")
print(f"{address}/32")
PY
)"
if az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --only-show-errors >/dev/null 2>&1; then
  fail "the temporary SSH rule already exists; run scripts/ssh-close.sh"
fi

STATE_FILE="$STATE_FILE" SUBSCRIPTION_ID="$SUBSCRIPTION_ID" RESOURCE_GROUP="$RESOURCE_GROUP" NSG_NAME="$NSG_NAME" RULE_NAME="$RULE_NAME" PUBLIC_IP_CIDR="$PUBLIC_IP_CIDR" SSH_ALIAS="$SSH_ALIAS" python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["STATE_FILE"])
value = {key.lower(): os.environ[key] for key in ("SUBSCRIPTION_ID", "RESOURCE_GROUP", "NSG_NAME", "RULE_NAME", "PUBLIC_IP_CIDR", "SSH_ALIAS")}
temporary = path.with_suffix(path.suffix + ".tmp")
temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.chmod(0o600)
temporary.replace(path)
PY

az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "$RULE_NAME" \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes "$PUBLIC_IP_CIDR" \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges 22 \
  --only-show-errors >/dev/null
RULE_CREATED=1

SOURCE="$(az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --query sourceAddressPrefix --output tsv --only-show-errors)"
PORT="$(az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --query destinationPortRange --output tsv --only-show-errors)"
ACCESS="$(az network nsg rule show --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" --name "$RULE_NAME" --query access --output tsv --only-show-errors)"
[[ "$SOURCE" == "$PUBLIC_IP_CIDR" && "$PORT" == "22" && "$ACCESS" == "Allow" ]] || fail "temporary rule read-back did not match the requested /32 TCP/22 access"

SUCCESS=1
printf 'Temporary SSH opened for %s. Connect with: ssh %s\n' "$PUBLIC_IP_CIDR" "$SSH_ALIAS"
printf 'Close it when finished with: scripts/ssh-close.sh\n'
