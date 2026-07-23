#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"

fail() {
  printf 'Remote Control recovery failed: %s\n' "$1" >&2
  exit 1
}

for command in az python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r SUBSCRIPTION_ID RESOURCE_GROUP VM_NAME SSH_USERNAME <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os
import re

value = json.loads(os.environ["CONNECTION"])
fields = [value[key] for key in ("subscription_id", "resource_group_name", "vm_name", "ssh_username")]
patterns = [
    r"[0-9a-fA-F-]{36}",
    r"[A-Za-z0-9._()/-]{1,90}",
    r"[A-Za-z0-9-]{1,64}",
    r"[a-z_][a-z0-9_-]{0,31}",
]
if any(re.fullmatch(pattern, field) is None for pattern, field in zip(patterns, fields)):
    raise SystemExit("Terraform connection output contains an unsafe recovery identifier")
print("\t".join(fields))
PY
)"

[[ "$(az account show --query id --output tsv)" == "$SUBSCRIPTION_ID" ]] || fail "Azure CLI is using a different subscription"

REMOTE_SCRIPT="runuser -u $SSH_USERNAME -- env HOME=/home/$SSH_USERNAME CODEX_HOME=/home/$SSH_USERNAME/.codex /usr/local/sbin/ensure-codex-remote-control"
az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --only-show-errors >/dev/null

printf 'Remote Control recovery completed through Azure Run Command; SSH remained closed.\n'
