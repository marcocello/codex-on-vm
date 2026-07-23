#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TF_DIR="$ROOT/deployment/prod/tf"

if rg -n 'Storage Account Key Operator Service Role|listKeys|/etc/smbcredentials' \
  "$TF_DIR" \
  --glob '!**/tests/**'; then
  printf 'Production Terraform still grants or uses storage-account keys on the VM.\n' >&2
  exit 1
fi

terraform -chdir="$TF_DIR" test -filter=tests/managed_identity_storage.tftest.hcl -verbose
