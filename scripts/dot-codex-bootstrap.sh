#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_ALIAS="${CODEX_VM_SSH_ALIAS:-codex-on-vm}"
REPOSITORY_URL="${DOT_CODEX_REPOSITORY_URL:-https://github.com/marcocello/dot-codex}"
REMOTE_DIR="${DOT_CODEX_REMOTE_DIR:-}"
REMOTE_RECOVERY_HELPER="${DOT_CODEX_REMOTE_RECOVERY_HELPER:-/usr/local/sbin/ensure-codex-remote-control}"
REMOTE_CONTROL_RETRY_SECONDS="${DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS:-2}"
SSH_OPENED=0
STEP_NUMBER=0
CURRENT_PHASE="initialization"

fail() {
  printf 'Dot Codex bootstrap failed: %s\n' "$1" >&2
  exit 1
}

step() {
  STEP_NUMBER=$((STEP_NUMBER + 1))
  CURRENT_PHASE="$1"
  printf '\n[%d/8] %s\n' "$STEP_NUMBER" "$CURRENT_PHASE"
}

note() {
  printf '  - %s\n' "$1"
}

cleanup_on_exit() {
  local status=$?
  local close_status=0
  trap - EXIT
  set +e
  if [[ "$SSH_OPENED" == "1" ]]; then
    printf '\n[cleanup] Closing temporary SSH after failure or interruption.\n'
    "$ROOT/scripts/ssh-close.sh"
    close_status=$?
  fi
  if [[ "$status" == "0" && "$close_status" != "0" ]]; then
    status=$close_status
  elif [[ "$status" != "0" && "$close_status" != "0" ]]; then
    printf 'Dot Codex bootstrap cleanup warning: temporary SSH could not be closed; run scripts/ssh-close.sh\n' >&2
  fi
  if [[ "$status" != "0" ]]; then
    printf '\n[FAILED] %s\n' "$CURRENT_PHASE" >&2
  fi
  exit "$status"
}

trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

step "Validate local inputs and helper availability"
[[ "$#" == "0" ]] || fail "this command accepts no positional arguments"
[[ "$(uname -s)" == "Darwin" ]] || fail "this helper is for macOS"
[[ -n "$REPOSITORY_URL" ]] || fail "DOT_CODEX_REPOSITORY_URL must not be empty"
[[ "$REPOSITORY_URL" != *$'\n'* && "$REPOSITORY_URL" != *$'\r'* && "$REPOSITORY_URL" != *$'\t'* ]] || fail "repository URL must not contain control characters"
[[ -n "$SSH_ALIAS" && "$SSH_ALIAS" != -* ]] || fail "CODEX_VM_SSH_ALIAS is invalid"
[[ "$SSH_ALIAS" != *$'\n'* && "$SSH_ALIAS" != *$'\r'* && "$SSH_ALIAS" != *$'\t'* && "$SSH_ALIAS" != *' '* ]] || fail "SSH alias must not contain whitespace"
[[ "$REMOTE_RECOVERY_HELPER" == /* ]] || fail "DOT_CODEX_REMOTE_RECOVERY_HELPER must be an absolute remote path"
[[ "$REMOTE_RECOVERY_HELPER" != *$'\n'* && "$REMOTE_RECOVERY_HELPER" != *$'\r'* && "$REMOTE_RECOVERY_HELPER" != *$'\t'* ]] || fail "remote recovery-helper path must not contain control characters"
[[ "$REMOTE_CONTROL_RETRY_SECONDS" =~ ^[0-9]+$ ]] || fail "DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS must be an integer"
((REMOTE_CONTROL_RETRY_SECONDS <= 30)) || fail "DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS must be between 0 and 30"
if [[ -n "$REMOTE_DIR" ]]; then
  [[ "$REMOTE_DIR" == /* ]] || fail "DOT_CODEX_REMOTE_DIR must be an absolute remote path"
  [[ "$REMOTE_DIR" != *$'\n'* && "$REMOTE_DIR" != *$'\r'* && "$REMOTE_DIR" != *$'\t'* ]] || fail "remote path must not contain control characters"
fi

command -v ssh >/dev/null || fail "missing required command: ssh"
[[ -x "$ROOT/scripts/ssh-open.sh" ]] || fail "missing SSH open helper"
[[ -x "$ROOT/scripts/ssh-close.sh" ]] || fail "missing SSH close helper"
[[ -x "$ROOT/scripts/remote-control-recover.sh" ]] || fail "missing Remote Control recovery helper"
note "Repository: $REPOSITORY_URL"
note "VM SSH alias: $SSH_ALIAS"
note "Remote clone: ${REMOTE_DIR:-\$HOME/dot-codex}"
note "Local validation passed."

step "Normalize temporary SSH state"
note "Closing any retained state or deterministic provider rule before opening a fresh session."
"$ROOT/scripts/ssh-close.sh"
note "Temporary SSH state is clean."

step "Open restricted temporary SSH"
"$ROOT/scripts/ssh-open.sh"
SSH_OPENED=1
note "Restricted SSH is open for this operation."

step "Reconcile and repair current Remote Control"
note "Checking Codex login before any daemon recovery."
printf -v REMOTE_PREFLIGHT_COMMAND 'bash -s -- %q' "packages/standalone/current/codex"
ssh "$SSH_ALIAS" "$REMOTE_PREFLIGHT_COMMAND" <<'REMOTE_PREFLIGHT'
set -euo pipefail
MANAGED_RELATIVE_PATH="$1"
CODEX_BIN="$HOME/.codex/$MANAGED_RELATIVE_PATH"
[[ -x "$CODEX_BIN" ]] || {
  printf 'Remote bootstrap preflight failed: managed Codex is missing at %s\n' "$CODEX_BIN" >&2
  exit 1
}
"$CODEX_BIN" login status >/dev/null 2>&1 || {
  printf 'Remote bootstrap preflight failed: Codex is not logged in; run: codex login --device-auth\n' >&2
  exit 1
}
printf '  [remote] Codex login is ready.\n'
REMOTE_PREFLIGHT
note "Using Azure Run Command to install the checked-in recovery helper when needed."
if "$ROOT/scripts/remote-control-recover.sh"; then
  note "Pre-migration Remote Control recovery completed."
else
  note "Pre-migration recovery did not complete; the SSH phase will diagnose login and retry safely."
fi

step "Bootstrap or repair dot-codex on the VM"
printf -v REMOTE_COMMAND \
  'bash -s -- %q %q %q %q' \
  "$REPOSITORY_URL" \
  "$REMOTE_DIR" \
  "$REMOTE_RECOVERY_HELPER" \
  "$REMOTE_CONTROL_RETRY_SECONDS"
ssh "$SSH_ALIAS" "$REMOTE_COMMAND" <<'REMOTE_SCRIPT'
set -euo pipefail

REPOSITORY_URL="$1"
REMOTE_DIR_OVERRIDE="$2"
RECOVERY_HELPER="$3"
RETRY_SECONDS="$4"
DOT_CODEX_DIR="${REMOTE_DIR_OVERRIDE:-$HOME/dot-codex}"
CODEX_LINK="$HOME/.codex"
MANAGED_RELATIVE_PATH="packages/standalone/current/codex"
BACKUP_PATH=""
MOVED_OLD_CODEX=0
CREATED_LINK=0
DAEMON_STOPPED=0

fail() {
  printf 'Remote Dot Codex bootstrap failed: %s\n' "$1" >&2
  exit 1
}

remote_note() {
  printf '  [remote] %s\n' "$1"
}

remote_control_connected_once() {
  local attempt="$1"
  local bin output status timed_out environment_id
  bin="$CODEX_LINK/$MANAGED_RELATIVE_PATH"
  if ! output="$("$bin" remote-control start --json 2>&1)"; then
    remote_note "Remote Control check $attempt: start command failed."
    return 1
  fi
  status="$(jq -r '.status // "unknown"' <<<"$output" 2>/dev/null || printf 'invalid-json')"
  timed_out="$(jq -r 'if has("timedOut") then (.timedOut | tostring) else "unknown" end' <<<"$output" 2>/dev/null || printf 'invalid-json')"
  environment_id="$(jq -r '.environmentId // ""' <<<"$output" 2>/dev/null || true)"
  remote_note "Remote Control check $attempt: status=$status timedOut=$timed_out."
  jq -e '
    .status == "connected" and
    .timedOut == false and
    (.environmentId | type == "string" and length > 0) and
    (.daemon.status | type == "string" and length > 0)
  ' <<<"$output" >/dev/null 2>&1 && [[ -n "$environment_id" ]]
}

wait_for_remote_control() {
  local phase="$1"
  local attempt
  for attempt in 1 2 3; do
    if remote_control_connected_once "$phase.$attempt"; then
      return 0
    fi
    if [[ "$attempt" != "3" && "$RETRY_SECONDS" != "0" ]]; then
      remote_note "Waiting ${RETRY_SECONDS}s before the next connection check."
      sleep "$RETRY_SECONDS"
    fi
  done
  return 1
}

repair_remote_control() {
  local context="$1"
  local bin
  bin="$CODEX_LINK/$MANAGED_RELATIVE_PATH"
  [[ -x "$bin" ]] || {
    remote_note "Managed Codex executable is missing at $bin."
    return 1
  }
  "$bin" login status >/dev/null 2>&1 || {
    remote_note "Codex login is missing; run: codex login --device-auth"
    return 1
  }
  remote_note "Checking Remote Control for $context."
  if wait_for_remote_control "start"; then
    remote_note "Remote Control is connected."
    return 0
  fi
  remote_note "Supported start did not connect; invoking $RECOVERY_HELPER."
  if ! "$RECOVERY_HELPER"; then
    remote_note "The VM recovery helper returned failure; checking connection once more."
  fi
  if wait_for_remote_control "repair"; then
    remote_note "Remote Control recovered and is connected."
    return 0
  fi
  remote_note "Remote Control is not connected after bounded repair attempts."
  return 1
}

rollback_on_exit() {
  local status=$?
  trap - EXIT
  set +e
  if [[ "$status" != "0" && "$MOVED_OLD_CODEX" == "1" ]]; then
    remote_note "Rolling back the Codex-home migration."
    if [[ "$CREATED_LINK" == "1" && -L "$CODEX_LINK" ]]; then
      rm -- "$CODEX_LINK"
    fi
    if [[ ! -e "$CODEX_LINK" && ! -L "$CODEX_LINK" && ( -e "$BACKUP_PATH" || -L "$BACKUP_PATH" ) ]]; then
      mv -- "$BACKUP_PATH" "$CODEX_LINK"
    fi
  fi
  if [[ "$status" != "0" && "$DAEMON_STOPPED" == "1" && -x "$CODEX_LINK/$MANAGED_RELATIVE_PATH" ]]; then
    remote_note "Attempting Remote Control recovery on the restored Codex home."
    repair_remote_control "the restored Codex home" ||
      printf 'Remote Dot Codex bootstrap rollback warning: the prior Remote Control connection did not recover\n' >&2
  fi
  exit "$status"
}

next_backup_path() {
  local base candidate suffix
  base="$HOME/.codex.backup.$(date +%Y%m%d-%H%M%S)"
  candidate="$base"
  suffix=0
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    candidate="$base.$suffix"
  done
  printf '%s\n' "$candidate"
}

trap rollback_on_exit EXIT
trap 'exit 130' INT TERM

for command in git jq readlink sleep tar; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done
[[ "$DOT_CODEX_DIR" == /* ]] || fail "remote clone path must be absolute"
[[ "$DOT_CODEX_DIR" != "$CODEX_LINK" ]] || fail "remote clone path must differ from ~/.codex"
[[ "$RECOVERY_HELPER" == /* && -x "$RECOVERY_HELPER" ]] || fail "VM recovery helper is unavailable or not executable at $RECOVERY_HELPER"
[[ "$RETRY_SECONDS" =~ ^[0-9]+$ ]] || fail "remote retry delay must be an integer"
((RETRY_SECONDS <= 30)) || fail "remote retry delay must be between 0 and 30"

if [[ -e "$DOT_CODEX_DIR" || -L "$DOT_CODEX_DIR" ]]; then
  remote_note "Inspecting existing clone at $DOT_CODEX_DIR."
  [[ -d "$DOT_CODEX_DIR" && ! -L "$DOT_CODEX_DIR" ]] || fail "clone target exists but is not a real directory: $DOT_CODEX_DIR"
  [[ "$(git -C "$DOT_CODEX_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] ||
    fail "clone target is not a Git worktree: $DOT_CODEX_DIR"
  CLONE_ROOT="$(git -C "$DOT_CODEX_DIR" rev-parse --show-toplevel)"
  [[ "$(readlink -f "$CLONE_ROOT")" == "$(readlink -f "$DOT_CODEX_DIR")" ]] ||
    fail "clone target is nested inside a different Git worktree: $DOT_CODEX_DIR"
  ACTUAL_ORIGIN="$(git -C "$DOT_CODEX_DIR" remote get-url origin 2>/dev/null)" ||
    fail "clone target has no origin remote"
  [[ "$ACTUAL_ORIGIN" == "$REPOSITORY_URL" ]] ||
    fail "clone origin is $ACTUAL_ORIGIN, expected $REPOSITORY_URL"
  [[ -z "$(git -C "$DOT_CODEX_DIR" status --porcelain --untracked-files=normal)" ]] ||
    fail "clone has local worktree or index changes: $DOT_CODEX_DIR"
  CURRENT_BRANCH="$(git -C "$DOT_CODEX_DIR" symbolic-ref --quiet --short HEAD)" ||
    fail "clone is detached"
  UPSTREAM="$(git -C "$DOT_CODEX_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" ||
    fail "branch $CURRENT_BRANCH has no upstream"
  [[ "$UPSTREAM" == origin/* ]] || fail "branch $CURRENT_BRANCH does not track origin"
  ORIGINAL_HEAD="$(git -C "$DOT_CODEX_DIR" rev-parse HEAD)"
  remote_note "Fetching origin before the default rebase."
  git -C "$DOT_CODEX_DIR" fetch --prune origin
  FORK_POINT="$(git -C "$DOT_CODEX_DIR" merge-base --fork-point "$UPSTREAM" "$ORIGINAL_HEAD" 2>/dev/null)" ||
    fail "could not determine a reflog-aware fork point for $CURRENT_BRANCH and $UPSTREAM"
  git -C "$DOT_CODEX_DIR" merge-base --is-ancestor "$FORK_POINT" "$ORIGINAL_HEAD" ||
    fail "reflog-aware fork point is not an ancestor of the original branch"
  remote_note "Rebasing VM-only commits after the reflog-aware fork point onto $UPSTREAM."
  if ! git -C "$DOT_CODEX_DIR" rebase --onto "$UPSTREAM" "$FORK_POINT" "$CURRENT_BRANCH"; then
    ABSOLUTE_GIT_DIR="$(git -C "$DOT_CODEX_DIR" rev-parse --absolute-git-dir)"
    if [[ -d "$ABSOLUTE_GIT_DIR/rebase-merge" || -d "$ABSOLUTE_GIT_DIR/rebase-apply" ]]; then
      remote_note "Rebase did not apply cleanly; aborting it."
      git -C "$DOT_CODEX_DIR" rebase --abort ||
        fail "rebase failed and automatic abort could not restore the original branch"
    fi
    [[ "$(git -C "$DOT_CODEX_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)" == "$CURRENT_BRANCH" ]] ||
      fail "rebase failed and did not restore branch $CURRENT_BRANCH"
    [[ "$(git -C "$DOT_CODEX_DIR" rev-parse HEAD)" == "$ORIGINAL_HEAD" ]] ||
      fail "rebase failed and did not restore the original branch commit"
    [[ -z "$(git -C "$DOT_CODEX_DIR" status --porcelain --untracked-files=normal)" ]] ||
      fail "rebase failed and did not restore a clean worktree"
    fail "rebase conflicted; original branch restored"
  fi
  git -C "$DOT_CODEX_DIR" merge-base --is-ancestor "$UPSTREAM" HEAD ||
    fail "rebase completed without placing $UPSTREAM behind the local branch"
else
  remote_note "Clone is missing; cloning $REPOSITORY_URL."
  git clone -- "$REPOSITORY_URL" "$DOT_CODEX_DIR"
fi

if [[ -L "$CODEX_LINK" ]] &&
  [[ "$(readlink -f "$CODEX_LINK")" == "$(readlink -f "$DOT_CODEX_DIR")" ]]; then
  remote_note "Symlink already correct; no backup or migration needed."
  repair_remote_control "the existing dot-codex home" ||
    fail "Remote Control is not connected after bounded repair attempts"
  printf 'Remote Dot Codex clone and symlink are ready at %s.\n' "$DOT_CODEX_DIR"
  ls -ld "$CODEX_LINK"
  exit 0
fi

if [[ -x "$CODEX_LINK/$MANAGED_RELATIVE_PATH" ]]; then
  remote_note "Checking Codex login before changing the active home."
  "$CODEX_LINK/$MANAGED_RELATIVE_PATH" login status >/dev/null 2>&1 ||
    fail "Codex is not logged in; authenticate on the VM with: codex login --device-auth"
  remote_note "Stopping the managed daemon before migration."
  "$CODEX_LINK/$MANAGED_RELATIVE_PATH" app-server daemon stop
  DAEMON_STOPPED=1
fi

if [[ -e "$CODEX_LINK" || -L "$CODEX_LINK" ]]; then
  BACKUP_PATH="$(next_backup_path)"
  remote_note "Moving the previous Codex home to $BACKUP_PATH."
  mv -- "$CODEX_LINK" "$BACKUP_PATH"
  MOVED_OLD_CODEX=1
  if [[ -d "$BACKUP_PATH" ]]; then
    remote_note "Migrating VM-local ignored state while preserving Git-owned files."
    (
      cd "$BACKUP_PATH"
      tar --exclude='.git' -cf - .
    ) | (
      cd "$DOT_CODEX_DIR"
      tar -xf -
    )
    git -C "$DOT_CODEX_DIR" restore --source=HEAD --staged --worktree -- .
  fi
fi

remote_note "Creating ~/.codex -> $DOT_CODEX_DIR."
ln -s -- "$DOT_CODEX_DIR" "$CODEX_LINK"
CREATED_LINK=1
[[ -L "$CODEX_LINK" ]] || fail "~/.codex was not created as a symlink"
[[ "$(readlink -f "$CODEX_LINK")" == "$(readlink -f "$DOT_CODEX_DIR")" ]] ||
  fail "~/.codex does not resolve to $DOT_CODEX_DIR"

repair_remote_control "the migrated dot-codex home" ||
  fail "Remote Control is not connected after bounded repair attempts"

printf 'Remote Dot Codex clone is ready at %s.\n' "$DOT_CODEX_DIR"
if [[ -n "$BACKUP_PATH" ]]; then
  printf 'Previous ~/.codex preserved at %s.\n' "$BACKUP_PATH"
fi
ls -ld "$CODEX_LINK"
REMOTE_SCRIPT

step "Close temporary SSH"
"$ROOT/scripts/ssh-close.sh"
SSH_OPENED=0
note "Temporary SSH is closed."

step "Verify Remote Control after SSH closure"
"$ROOT/scripts/remote-control-recover.sh" ||
  fail "final Remote Control verification failed; run scripts/remote-control-recover.sh after checking VM login and network access"
printf 'Remote Control verified connected.\n'

step "Complete"
printf 'Dot Codex bootstrap and repair completed successfully.\n'
printf '  Clone: %s\n' "${REMOTE_DIR:-\$HOME/dot-codex}"
printf '  Symlink: \$HOME/.codex -> %s\n' "${REMOTE_DIR:-\$HOME/dot-codex}"
printf '  SSH: closed\n'
printf '  Remote Control: connected\n'
