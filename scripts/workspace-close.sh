#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"

fail() {
  printf 'Workspace close failed: %s\n' "$1" >&2
  exit 1
}

for command in diskutil mount python3 terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
DEFAULT_MOUNT="$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["CONNECTION"])["local_mount_path"])
PY
)"
MOUNT_PATH="${CODEX_WORKSPACE_LOCAL_MOUNT_PATH:-$DEFAULT_MOUNT}"

if mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
  diskutil unmount "$MOUNT_PATH" >/dev/null || fail "could not unmount $MOUNT_PATH; SSH access remains open for recovery"
fi
if mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
  fail "$MOUNT_PATH is still mounted; SSH access remains open for recovery"
fi
"$ROOT/scripts/ssh-close.sh"
printf 'Workspace unmounted and temporary SSH closed.\n'
