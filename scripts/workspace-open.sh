#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
SUCCESS=0
SSH_OPENED=0
MOUNT_PATH=""

fail() {
  printf 'Workspace open failed: %s\n' "$1" >&2
  exit 1
}

cleanup_on_exit() {
  local status=$?
  set +e
  if [[ "$SUCCESS" != "1" ]]; then
    if [[ -n "$MOUNT_PATH" ]] && mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
      diskutil unmount "$MOUNT_PATH" >/dev/null 2>&1 || true
    fi
    if [[ "$SSH_OPENED" == "1" ]]; then
      "$ROOT/scripts/ssh-close.sh" >/dev/null 2>&1 || true
    fi
  fi
  return "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
for command in diskutil find mount python3 sshfs terraform; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

CONNECTION="$(terraform -chdir="$TF_DIR" output -json connection)"
IFS=$'\t' read -r SSH_ALIAS REMOTE_PATH DEFAULT_MOUNT <<<"$(CONNECTION="$CONNECTION" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["CONNECTION"])
print("\t".join(value[key] for key in ("ssh_alias", "workspace_mount_path", "local_mount_path")))
PY
)"
MOUNT_PATH="${CODEX_WORKSPACE_LOCAL_MOUNT_PATH:-$DEFAULT_MOUNT}"
mkdir -p "$MOUNT_PATH"
if mount | grep -F " on $MOUNT_PATH " >/dev/null 2>&1; then
  fail "$MOUNT_PATH is already mounted"
fi
[[ -z "$(find "$MOUNT_PATH" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "$MOUNT_PATH must be empty"

"$ROOT/scripts/ssh-open.sh"
SSH_OPENED=1
sshfs "$SSH_ALIAS:$REMOTE_PATH" "$MOUNT_PATH" \
  -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,volname=codex-on-vm
mount | grep -F " on $MOUNT_PATH " >/dev/null || fail "SSHFS mount read-back failed"

SUCCESS=1
printf 'Workspace mounted at %s. Run scripts/workspace-close.sh when finished.\n' "$MOUNT_PATH"
