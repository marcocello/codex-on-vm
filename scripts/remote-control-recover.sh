#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
HELPER_PATH="$TF_DIR/scripts/ensure-codex-remote-control.sh"

fail() {
  printf 'Remote Control recovery failed: %s\n' "$1" >&2
  exit 1
}

for command in az python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
[[ -f "$HELPER_PATH" && -r "$HELPER_PATH" ]] || fail "missing VM recovery helper: $HELPER_PATH"

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

REMOTE_SCRIPT="$(HELPER_PATH="$HELPER_PATH" SSH_USERNAME="$SSH_USERNAME" python3 - <<'PY'
import base64
import hashlib
import os
import pathlib
import shlex

helper = pathlib.Path(os.environ["HELPER_PATH"]).read_bytes()
encoded_helper = base64.b64encode(helper).decode("ascii")
expected_sha = hashlib.sha256(helper).hexdigest()
username = os.environ["SSH_USERNAME"]
target = "/usr/local/sbin/ensure-codex-remote-control"
home = f"/home/{username}"
quote = shlex.quote

print(
    f"""#!/bin/sh
set -eu
target={quote(target)}
expected_sha={quote(expected_sha)}
tmp="$(mktemp)"
trap 'rm -f "$tmp"' 0 HUP INT TERM
printf '%s' {quote(encoded_helper)} | base64 --decode >"$tmp"
actual_sha="$(sha256sum "$tmp" | awk '{{print $1}}')"
if [ "$actual_sha" != "$expected_sha" ]; then
  printf 'VM recovery helper payload checksum mismatch\\n' >&2
  exit 1
fi
if ! cmp -s "$tmp" "$target"; then
  install -o root -g root -m 0755 "$tmp" "$target"
fi
if ! cmp -s "$tmp" "$target"; then
  printf 'VM recovery helper reconciliation failed\\n' >&2
  exit 1
fi
runuser -u {quote(username)} -- env HOME={quote(home)} CODEX_HOME={quote(f"{home}/.codex")} "$target"
"""
)
PY
)"
az vm run-command invoke \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$REMOTE_SCRIPT" \
  --only-show-errors >/dev/null

printf 'Remote Control recovery completed through Azure Run Command; SSH remained closed.\n'
