#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PROOF_TMP="$(mktemp -d)"
OPERATOR_ROOT="$PROOF_TMP/operator-root"
CODEX_VM_TEST_MODE=1 "$ROOT/scripts/codex-vm.sh" __extract-helpers "$OPERATOR_ROOT"
SCRIPT="$OPERATOR_ROOT/scripts/dot-codex-bootstrap.sh"

cleanup() {
  rm -rf "$PROOF_TMP"
}
trap cleanup EXIT

fail() {
  printf 'Dot Codex VM bootstrap proof failed: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  grep -Fqx "$expected" "$path" || fail "$path does not contain expected line: $expected"
}

assert_patterns_in_order() {
  local path="$1"
  shift
  local previous=0
  local pattern line
  for pattern in "$@"; do
    line="$(grep -nF "$pattern" "$path" | awk -F: -v previous="$previous" '$1 > previous { print $1; exit }')"
    [[ -n "$line" ]] || fail "$path does not contain ordered pattern after line $previous: $pattern"
    previous="$line"
  done
}

assert_backup_count() {
  local remote_home="$1"
  local expected="$2"
  local actual
  actual="$(find "$remote_home" -maxdepth 1 -name '.codex.backup.*' -print | wc -l | tr -d ' ')"
  [[ "$actual" == "$expected" ]] || fail "expected $expected backup(s), found $actual"
}

make_origin() {
  local fixture="$1"
  local origin="$fixture/origin.git"
  local seed="$fixture/seed"

  git init --bare --initial-branch=main "$origin" >/dev/null
  git init --initial-branch=main "$seed" >/dev/null
  git -C "$seed" config user.email proof@example.invalid
  git -C "$seed" config user.name "Bootstrap Proof"
  printf '*\n!.gitignore\n!AGENTS.md\n!revision.txt\n!local.txt\n!upstream.txt\n' >"$seed/.gitignore"
  printf 'tracked config from origin\n' >"$seed/AGENTS.md"
  printf 'one\n' >"$seed/revision.txt"
  git -C "$seed" add .gitignore AGENTS.md revision.txt
  git -C "$seed" commit -m "initial fixture" >/dev/null
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -u origin main >/dev/null
  printf '%s\n' "$origin"
}

make_harness() {
  local fixture="$1"
  local harness="$fixture/harness"
  mkdir -p "$harness/scripts" "$fixture/bin"
  cp "$SCRIPT" "$harness/scripts/dot-codex-bootstrap.sh"
  chmod +x "$harness/scripts/dot-codex-bootstrap.sh"

  cat >"$harness/scripts/remote-control-recover.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'recover\n' >>"$FAKE_LIFECYCLE_LOG"
[[ "${FAKE_MAC_RECOVERY_FAIL:-0}" != "1" ]] || exit 31
SH
  cat >"$fixture/bin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
cat >"$fixture/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" BatchMode=yes "* ]]; then
  printf 'ssh-probe\n' >>"$FAKE_LIFECYCLE_LOG"
  [[ "${FAKE_VPN_UNREACHABLE:-0}" != "1" && "${FAKE_SSH_FAIL:-0}" != "1" ]] || exit 23
  [[ "${*: -2:1}" == "$FAKE_EXPECTED_SSH_ALIAS" ]] || exit 92
  exit 0
fi
printf 'ssh\n' >>"$FAKE_LIFECYCLE_LOG"
[[ "${FAKE_SSH_FAIL:-0}" != "1" ]] || exit 23
[[ "$#" == "2" ]] || exit 91
[[ "$1" == "$FAKE_EXPECTED_SSH_ALIAS" ]] || exit 92
[[ "$2" == "bash -s -- "* ]] || exit 93
HOME="$FAKE_REMOTE_HOME" bash -c "$2"
SH
  chmod +x \
    "$harness/scripts/remote-control-recover.sh" \
    "$fixture/bin/uname" \
    "$fixture/bin/ssh"
}

make_remote_codex_home() {
  local fixture="$1"
  local remote_home="$fixture/remote-home"
  local codex_home="$remote_home/.codex"
  mkdir -p "$remote_home/projects" "$codex_home/packages/standalone/current"
  printf 'stale tracked config\n' >"$codex_home/AGENTS.md"
  printf 'preserved auth\n' >"$codex_home/auth.json"
  printf 'preserved runtime\n' >"$codex_home/runtime-state.bin"
  cat >"$codex_home/packages/standalone/current/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_CODEX_LOG"
if [[ "$*" == "login status" && "${FAKE_CODEX_NOT_LOGGED_IN:-0}" == "1" ]]; then
  exit 42
fi
if [[ "$*" == "remote-control start --json" ]]; then
  if [[ "${FAKE_CODEX_FAIL_START:-0}" == "1" ]]; then
    exit 41
  fi
  if [[ "${FAKE_CONNECTING_ONCE:-0}" == "1" && ! -e "$FAKE_REMOTE_CONNECTING_FILE" ]]; then
    : >"$FAKE_REMOTE_CONNECTING_FILE"
    printf '%s\n' '{"mode":"daemon","status":"connecting","environmentId":"env_proof","timedOut":false,"daemon":{"status":"alreadyRunning"}}'
    exit 0
  fi
  if [[ "${FAKE_REQUIRE_REMOTE_HELPER:-0}" == "1" && ! -e "$FAKE_REMOTE_RECOVERED_FILE" ]]; then
    exit 43
  fi
  if [[ "${FAKE_INVALID_CONNECTED_SEQUENCE:-0}" == "1" ]]; then
    invalid_count=0
    if [[ -f "$FAKE_REMOTE_INVALID_COUNT_FILE" ]]; then
      invalid_count="$(<"$FAKE_REMOTE_INVALID_COUNT_FILE")"
    fi
    invalid_count=$((invalid_count + 1))
    printf '%s\n' "$invalid_count" >"$FAKE_REMOTE_INVALID_COUNT_FILE"
    if [[ "$invalid_count" == "1" ]]; then
      printf '%s\n' '{"mode":"daemon","status":"connected","environmentId":"env_proof","timedOut":true,"daemon":{"status":"alreadyRunning"}}'
      exit 0
    fi
    if [[ "$invalid_count" == "2" ]]; then
      printf '%s\n' '{"mode":"daemon","status":"connected","environmentId":"","timedOut":false,"daemon":{"status":"alreadyRunning"}}'
      exit 0
    fi
  fi
  printf '%s\n' '{"mode":"daemon","status":"connected","environmentId":"env_proof","timedOut":false,"daemon":{"status":"alreadyRunning"}}'
fi
SH
  chmod +x "$codex_home/packages/standalone/current/codex"

  cat >"$remote_home/ensure-codex-remote-control" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'remote-recover\n' >>"$FAKE_REMOTE_RECOVERY_LOG"
[[ "${FAKE_REMOTE_RECOVERY_FAIL:-0}" != "1" ]] || exit 44
: >"$FAKE_REMOTE_RECOVERED_FILE"
SH
  chmod +x "$remote_home/ensure-codex-remote-control"
}

run_helper() {
  local fixture="$1"
  local origin="$2"
  local remote_dir="$3"
  PATH="$fixture/bin:$PATH" \
    FAKE_LIFECYCLE_LOG="$fixture/lifecycle.log" \
    FAKE_CODEX_LOG="$fixture/codex.log" \
    FAKE_REMOTE_RECOVERY_LOG="$fixture/remote-recovery.log" \
    FAKE_REMOTE_RECOVERED_FILE="$fixture/remote-recovered" \
    FAKE_REMOTE_CONNECTING_FILE="$fixture/remote-connecting" \
    FAKE_REMOTE_INVALID_COUNT_FILE="$fixture/remote-invalid-count" \
    FAKE_REMOTE_HOME="$fixture/remote-home" \
    FAKE_EXPECTED_SSH_ALIAS="codex-on-vm-vpn" \
    DOT_CODEX_REPOSITORY_URL="$origin" \
    DOT_CODEX_REMOTE_DIR="$remote_dir" \
    DOT_CODEX_REMOTE_CONTROL_RETRY_SECONDS="0" \
    DOT_CODEX_REMOTE_RECOVERY_HELPER="$fixture/remote-home/ensure-codex-remote-control" \
    CODEX_VM_VPN_SSH_ALIAS="codex-on-vm-vpn" \
    "$fixture/harness/scripts/dot-codex-bootstrap.sh"
}

[[ -x "$SCRIPT" ]] || fail "production helper is missing or not executable: $SCRIPT"
printf 'Bash: %s | %s\n' "$(command -v bash)" "$(bash --version | head -n 1)"
printf 'Git: %s | %s\n' "$(command -v git)" "$(git --version)"
printf 'Production helper: %s\n' "$SCRIPT"

MAIN_FIXTURE="$PROOF_TMP/main"
mkdir -p "$MAIN_FIXTURE"
MAIN_ORIGIN="$(make_origin "$MAIN_FIXTURE")"
MAIN_BASE_REVISION="$(git -C "$MAIN_FIXTURE/seed" rev-parse HEAD)"
make_harness "$MAIN_FIXTURE"
make_remote_codex_home "$MAIN_FIXTURE"
MAIN_REMOTE_DIR="$MAIN_FIXTURE/remote-home/projects/dot-codex"
printf 'Remote fixture ready: %s\n' "$MAIN_FIXTURE/remote-home"

if ! FAKE_REQUIRE_REMOTE_HELPER=1 FAKE_CONNECTING_ONCE=1 FAKE_INVALID_CONNECTED_SEQUENCE=1 \
  run_helper "$MAIN_FIXTURE" "$MAIN_ORIGIN" "" >"$MAIN_FIXTURE/first-output.log" 2>&1; then
  sed -n '1,240p' "$MAIN_FIXTURE/first-output.log" >&2
  fail "fresh bootstrap and Remote Control repair failed"
fi
sed -n '1,200p' "$MAIN_FIXTURE/first-output.log"
[[ -d "$MAIN_REMOTE_DIR/.git" ]] || fail "remote clone was not created"
[[ "$(git -C "$MAIN_REMOTE_DIR" remote get-url origin)" == "$MAIN_ORIGIN" ]] || fail "clone origin mismatch"
assert_file_contains "$MAIN_REMOTE_DIR/AGENTS.md" "tracked config from origin"
assert_file_contains "$MAIN_REMOTE_DIR/auth.json" "preserved auth"
assert_file_contains "$MAIN_REMOTE_DIR/runtime-state.bin" "preserved runtime"
[[ -x "$MAIN_REMOTE_DIR/packages/standalone/current/codex" ]] || fail "managed Codex executable was not migrated"
[[ -L "$MAIN_FIXTURE/remote-home/.codex" ]] || fail ".codex is not a symlink"
[[ "$(readlink -f "$MAIN_FIXTURE/remote-home/.codex")" == "$(readlink -f "$MAIN_REMOTE_DIR")" ]] || fail ".codex resolves to the wrong target"
assert_backup_count "$MAIN_FIXTURE/remote-home" 1
assert_patterns_in_order \
  "$MAIN_FIXTURE/lifecycle.log" \
  "ssh-probe" \
  "ssh" \
  "recover" \
  "ssh" \
  "recover"
[[ "$(tail -n 1 "$MAIN_FIXTURE/lifecycle.log")" == "recover" ]] || fail "final Azure recovery did not run"
assert_patterns_in_order \
  "$MAIN_FIXTURE/first-output.log" \
  "[1/6] Validate local inputs and helper availability" \
  'Remote clone: $HOME/projects/dot-codex' \
  "[2/6] Verify OpenVPN SSH access" \
  "[3/6] Reconcile and repair current Remote Control" \
  "[4/6] Bootstrap or repair dot-codex on the VM" \
  "[5/6] Verify Remote Control" \
  "Remote Control verified connected." \
  "[6/6] Complete"
assert_file_contains "$MAIN_FIXTURE/codex.log" "app-server daemon stop"
assert_file_contains "$MAIN_FIXTURE/codex.log" "remote-control start --json"
assert_file_contains "$MAIN_FIXTURE/remote-recovery.log" "remote-recover"
[[ "$(<"$MAIN_FIXTURE/remote-invalid-count")" == "3" ]] ||
  fail "Remote Control fixture did not present both independently invalid connected responses"
assert_patterns_in_order \
  "$MAIN_FIXTURE/first-output.log" \
  "Remote Control check start.1: status=connecting timedOut=false." \
  "Remote Control check repair.1: status=connected timedOut=true." \
  "Remote Control check repair.2: status=connected timedOut=false." \
  "Remote Control check repair.3: status=connected timedOut=false." \
  "Remote Control recovered and is connected."

printf 'two\n' >"$MAIN_FIXTURE/seed/revision.txt"
git -C "$MAIN_FIXTURE/seed" add revision.txt
git -C "$MAIN_FIXTURE/seed" commit -m "update fixture" >/dev/null
git -C "$MAIN_FIXTURE/seed" push >/dev/null

: >"$MAIN_FIXTURE/codex.log"
: >"$MAIN_FIXTURE/remote-recovery.log"
if ! FAKE_REQUIRE_REMOTE_HELPER=1 FAKE_CONNECTING_ONCE=1 \
  run_helper "$MAIN_FIXTURE" "$MAIN_ORIGIN" "" >"$MAIN_FIXTURE/second-output.log" 2>&1; then
  sed -n '1,240p' "$MAIN_FIXTURE/second-output.log" >&2
  fail "idempotent bootstrap and Remote Control verification failed"
fi
assert_file_contains "$MAIN_REMOTE_DIR/revision.txt" "two"
assert_backup_count "$MAIN_FIXTURE/remote-home" 1
if grep -Fqx 'app-server daemon stop' "$MAIN_FIXTURE/codex.log"; then
  fail "idempotent rerun stopped the daemon"
fi
assert_file_contains "$MAIN_FIXTURE/codex.log" "login status"
assert_file_contains "$MAIN_FIXTURE/codex.log" "remote-control start --json"
[[ ! -s "$MAIN_FIXTURE/remote-recovery.log" ]] || fail "idempotent rerun invoked unnecessary VM process recovery"
[[ "$(tail -n 1 "$MAIN_FIXTURE/lifecycle.log")" == "recover" ]] || fail "second run did not perform final recovery"
grep -F 'Symlink already correct; no backup or migration needed.' "$MAIN_FIXTURE/second-output.log" >/dev/null ||
  fail "idempotent rerun did not explain the no-op symlink decision"

MAIN_OLD_UPSTREAM_REVISION="$(git -C "$MAIN_REMOTE_DIR" rev-parse HEAD)"

git -C "$MAIN_FIXTURE/seed" switch --detach "$MAIN_BASE_REVISION" >/dev/null
git -C "$MAIN_FIXTURE/seed" switch -c rewritten-main >/dev/null
printf 'first rewritten origin revision\n' >"$MAIN_FIXTURE/seed/revision.txt"
printf 'first force-updated origin state\n' >"$MAIN_FIXTURE/seed/upstream.txt"
git -C "$MAIN_FIXTURE/seed" add revision.txt upstream.txt
git -C "$MAIN_FIXTURE/seed" commit -m "rewrite upstream main" >/dev/null
MAIN_REWRITTEN_REVISION="$(git -C "$MAIN_FIXTURE/seed" rev-parse HEAD)"
git -C "$MAIN_FIXTURE/seed" push --force origin rewritten-main:main >/dev/null

: >"$MAIN_FIXTURE/codex.log"
: >"$MAIN_FIXTURE/remote-recovery.log"
if ! run_helper "$MAIN_FIXTURE" "$MAIN_ORIGIN" "" >"$MAIN_FIXTURE/rewrite-only-output.log" 2>&1; then
  sed -n '1,240p' "$MAIN_FIXTURE/rewrite-only-output.log" >&2
  fail "reflog-aware rebase replayed obsolete upstream history"
fi
[[ "$(git -C "$MAIN_REMOTE_DIR" rev-parse HEAD)" == "$MAIN_REWRITTEN_REVISION" ]] ||
  fail "branch with no VM-only commits did not move directly to rewritten origin"
if git -C "$MAIN_REMOTE_DIR" merge-base --is-ancestor "$MAIN_OLD_UPSTREAM_REVISION" HEAD; then
  fail "obsolete former-upstream commit remained after the empty replay"
fi
assert_file_contains "$MAIN_REMOTE_DIR/revision.txt" "first rewritten origin revision"
assert_file_contains "$MAIN_REMOTE_DIR/upstream.txt" "first force-updated origin state"
assert_backup_count "$MAIN_FIXTURE/remote-home" 1
grep -F 'Rebasing VM-only commits after the reflog-aware fork point onto origin/main.' "$MAIN_FIXTURE/rewrite-only-output.log" >/dev/null ||
  fail "reflog-aware rebase did not explain its convergence boundary"
if grep -Fqx 'app-server daemon stop' "$MAIN_FIXTURE/codex.log"; then
  fail "upstream-only rewrite repeated daemon migration"
fi

printf 'local commit retained through rebase\n' >"$MAIN_REMOTE_DIR/local.txt"
git -C "$MAIN_REMOTE_DIR" config user.email proof@example.invalid
git -C "$MAIN_REMOTE_DIR" config user.name "Bootstrap Proof"
git -C "$MAIN_REMOTE_DIR" add local.txt
git -C "$MAIN_REMOTE_DIR" commit -m "retain local VM commit" >/dev/null
MAIN_ORIGINAL_LOCAL_HEAD="$(git -C "$MAIN_REMOTE_DIR" rev-parse HEAD)"

git -C "$MAIN_FIXTURE/seed" switch --detach "$MAIN_BASE_REVISION" >/dev/null
git -C "$MAIN_FIXTURE/seed" switch -c rewritten-main-2 >/dev/null
printf 'second rewritten origin revision\n' >"$MAIN_FIXTURE/seed/revision.txt"
printf 'second force-updated origin state\n' >"$MAIN_FIXTURE/seed/upstream.txt"
git -C "$MAIN_FIXTURE/seed" add revision.txt upstream.txt
git -C "$MAIN_FIXTURE/seed" commit -m "rewrite upstream main again" >/dev/null
MAIN_SECOND_REWRITTEN_REVISION="$(git -C "$MAIN_FIXTURE/seed" rev-parse HEAD)"
git -C "$MAIN_FIXTURE/seed" push --force origin rewritten-main-2:main >/dev/null

: >"$MAIN_FIXTURE/codex.log"
: >"$MAIN_FIXTURE/remote-recovery.log"
if ! run_helper "$MAIN_FIXTURE" "$MAIN_ORIGIN" "" >"$MAIN_FIXTURE/rebase-output.log" 2>&1; then
  sed -n '1,240p' "$MAIN_FIXTURE/rebase-output.log" >&2
  fail "reflog-aware rebase did not preserve the VM-only commit"
fi
git -C "$MAIN_REMOTE_DIR" merge-base --is-ancestor "$MAIN_SECOND_REWRITTEN_REVISION" HEAD ||
  fail "second rewritten origin is not an ancestor after default rebase"
[[ "$(git -C "$MAIN_REMOTE_DIR" rev-list --count "$MAIN_SECOND_REWRITTEN_REVISION..HEAD")" == "1" ]] ||
  fail "reflog-aware rebase did not produce exactly one replayed VM-only commit"
[[ "$(git -C "$MAIN_REMOTE_DIR" log --format=%s "$MAIN_SECOND_REWRITTEN_REVISION..HEAD")" == "retain local VM commit" ]] ||
  fail "reflog-aware rebase did not replay only the expected VM-side commit"
[[ -z "$(git -C "$MAIN_REMOTE_DIR" rev-list --merges "$MAIN_SECOND_REWRITTEN_REVISION..HEAD")" ]] ||
  fail "reflog-aware rebase produced a merge commit"
if git -C "$MAIN_REMOTE_DIR" merge-base --is-ancestor "$MAIN_ORIGINAL_LOCAL_HEAD" HEAD; then
  fail "original local tip remained in history instead of being replayed"
fi
if git -C "$MAIN_REMOTE_DIR" merge-base --is-ancestor "$MAIN_REWRITTEN_REVISION" HEAD; then
  fail "first rewritten upstream remained after the second force-update"
fi
assert_file_contains "$MAIN_REMOTE_DIR/upstream.txt" "second force-updated origin state"
assert_file_contains "$MAIN_REMOTE_DIR/revision.txt" "second rewritten origin revision"
assert_file_contains "$MAIN_REMOTE_DIR/local.txt" "local commit retained through rebase"
assert_backup_count "$MAIN_FIXTURE/remote-home" 1
grep -F 'Rebasing VM-only commits after the reflog-aware fork point onto origin/main.' "$MAIN_FIXTURE/rebase-output.log" >/dev/null ||
  fail "VM-only rebase did not explain its Git convergence boundary"
if grep -Fqx 'app-server daemon stop' "$MAIN_FIXTURE/codex.log"; then
  fail "history-only rebase repeated daemon migration"
fi

DIRTY_FIXTURE="$PROOF_TMP/dirty-clone"
mkdir -p "$DIRTY_FIXTURE"
DIRTY_ORIGIN="$(make_origin "$DIRTY_FIXTURE")"
make_harness "$DIRTY_FIXTURE"
make_remote_codex_home "$DIRTY_FIXTURE"
DIRTY_REMOTE_DIR="$DIRTY_FIXTURE/remote-home/dot-codex"
git clone "$DIRTY_ORIGIN" "$DIRTY_REMOTE_DIR" >/dev/null
printf 'local tracked edit that must survive\n' >"$DIRTY_REMOTE_DIR/AGENTS.md"
if run_helper "$DIRTY_FIXTURE" "$DIRTY_ORIGIN" "$DIRTY_REMOTE_DIR"; then
  fail "existing clone with tracked work unexpectedly succeeded"
fi
assert_file_contains "$DIRTY_REMOTE_DIR/AGENTS.md" "local tracked edit that must survive"
[[ -d "$DIRTY_FIXTURE/remote-home/.codex" && ! -L "$DIRTY_FIXTURE/remote-home/.codex" ]] || fail "dirty-clone refusal changed .codex"
assert_backup_count "$DIRTY_FIXTURE/remote-home" 0
! rg -n '^(open|close)$' "$DIRTY_FIXTURE/lifecycle.log" >/dev/null || fail "dirty-clone refusal used a public SSH lifecycle"
assert_file_contains "$DIRTY_FIXTURE/codex.log" "login status"
if grep -Fqx 'app-server daemon stop' "$DIRTY_FIXTURE/codex.log" ||
  grep -Fqx 'remote-control start --json' "$DIRTY_FIXTURE/codex.log"; then
  fail "dirty-clone refusal changed daemon state"
fi

CONFLICT_FIXTURE="$PROOF_TMP/rebase-conflict"
mkdir -p "$CONFLICT_FIXTURE"
CONFLICT_ORIGIN="$(make_origin "$CONFLICT_FIXTURE")"
make_harness "$CONFLICT_FIXTURE"
make_remote_codex_home "$CONFLICT_FIXTURE"
CONFLICT_REMOTE_DIR="$CONFLICT_FIXTURE/remote-home/dot-codex"
git clone "$CONFLICT_ORIGIN" "$CONFLICT_REMOTE_DIR" >/dev/null
git -C "$CONFLICT_REMOTE_DIR" config user.email proof@example.invalid
git -C "$CONFLICT_REMOTE_DIR" config user.name "Bootstrap Proof"
printf 'local conflicting revision\n' >"$CONFLICT_REMOTE_DIR/revision.txt"
git -C "$CONFLICT_REMOTE_DIR" add revision.txt
git -C "$CONFLICT_REMOTE_DIR" commit -m "local conflicting revision" >/dev/null
CONFLICT_LOCAL_HEAD="$(git -C "$CONFLICT_REMOTE_DIR" rev-parse HEAD)"
printf 'origin conflicting revision\n' >"$CONFLICT_FIXTURE/seed/revision.txt"
git -C "$CONFLICT_FIXTURE/seed" add revision.txt
git -C "$CONFLICT_FIXTURE/seed" commit -m "origin conflicting revision" >/dev/null
git -C "$CONFLICT_FIXTURE/seed" push >/dev/null
if run_helper \
  "$CONFLICT_FIXTURE" \
  "$CONFLICT_ORIGIN" \
  "$CONFLICT_REMOTE_DIR" >"$CONFLICT_FIXTURE/output.log" 2>&1; then
  fail "conflicting default rebase unexpectedly succeeded"
fi
if ! grep -F 'rebase conflicted; original branch restored' "$CONFLICT_FIXTURE/output.log" >/dev/null; then
  sed -n '1,240p' "$CONFLICT_FIXTURE/output.log" >&2
  fail "conflicting rebase did not report the automatic abort"
fi
[[ "$(git -C "$CONFLICT_REMOTE_DIR" rev-parse HEAD)" == "$CONFLICT_LOCAL_HEAD" ]] ||
  fail "conflicting rebase did not restore the original branch commit"
assert_file_contains "$CONFLICT_REMOTE_DIR/revision.txt" "local conflicting revision"
[[ -z "$(git -C "$CONFLICT_REMOTE_DIR" status --porcelain --untracked-files=normal)" ]] ||
  fail "conflicting rebase left worktree or index changes"
[[ ! -d "$CONFLICT_REMOTE_DIR/.git/rebase-merge" && ! -d "$CONFLICT_REMOTE_DIR/.git/rebase-apply" ]] ||
  fail "conflicting rebase left rebase metadata"
[[ -d "$CONFLICT_FIXTURE/remote-home/.codex" && ! -L "$CONFLICT_FIXTURE/remote-home/.codex" ]] ||
  fail "conflicting rebase changed .codex"
assert_backup_count "$CONFLICT_FIXTURE/remote-home" 0
! rg -n '^(open|close)$' "$CONFLICT_FIXTURE/lifecycle.log" >/dev/null ||
  fail "conflicting rebase used a public SSH lifecycle"
if grep -Fqx 'app-server daemon stop' "$CONFLICT_FIXTURE/codex.log" ||
  grep -Fqx 'remote-control start --json' "$CONFLICT_FIXTURE/codex.log"; then
  fail "conflicting rebase changed daemon state"
fi

AUTH_FIXTURE="$PROOF_TMP/missing-auth"
mkdir -p "$AUTH_FIXTURE"
AUTH_ORIGIN="$(make_origin "$AUTH_FIXTURE")"
make_harness "$AUTH_FIXTURE"
make_remote_codex_home "$AUTH_FIXTURE"
rm "$AUTH_FIXTURE/remote-home/.codex/auth.json"
AUTH_REMOTE_DIR="$AUTH_FIXTURE/remote-home/dot-codex"
if FAKE_CODEX_NOT_LOGGED_IN=1 run_helper \
  "$AUTH_FIXTURE" \
  "$AUTH_ORIGIN" \
  "$AUTH_REMOTE_DIR" >"$AUTH_FIXTURE/output.log" 2>&1; then
  fail "managed Codex home without credentials unexpectedly succeeded"
fi
grep -F 'scripts/codex-vm.sh sign-in' "$AUTH_FIXTURE/output.log" >/dev/null ||
  fail "missing-auth refusal did not direct authentication to the local sign-in entrypoint"
if grep -Fi 'on the VM' "$AUTH_FIXTURE/output.log" >/dev/null; then
  fail "missing-auth refusal still directs authentication from inside the VM"
fi
[[ -d "$AUTH_FIXTURE/remote-home/.codex" && ! -L "$AUTH_FIXTURE/remote-home/.codex" ]] || fail "missing-auth refusal changed .codex"
assert_backup_count "$AUTH_FIXTURE/remote-home" 0
! rg -n '^(open|close)$' "$AUTH_FIXTURE/lifecycle.log" >/dev/null || fail "missing-auth refusal used a public SSH lifecycle"
if grep -Fqx 'recover' "$AUTH_FIXTURE/lifecycle.log"; then
  fail "missing-auth refusal invoked Azure recovery before login was established"
fi
assert_file_contains "$AUTH_FIXTURE/codex.log" "login status"
if grep -Fqx 'app-server daemon stop' "$AUTH_FIXTURE/codex.log" ||
  grep -Fqx 'remote-control start --json' "$AUTH_FIXTURE/codex.log"; then
  fail "missing-auth refusal changed daemon state"
fi

SSH_FAILURE_FIXTURE="$PROOF_TMP/ssh-failure"
mkdir -p "$SSH_FAILURE_FIXTURE"
SSH_FAILURE_ORIGIN="$(make_origin "$SSH_FAILURE_FIXTURE")"
make_harness "$SSH_FAILURE_FIXTURE"
make_remote_codex_home "$SSH_FAILURE_FIXTURE"
if FAKE_SSH_FAIL=1 run_helper \
  "$SSH_FAILURE_FIXTURE" \
  "$SSH_FAILURE_ORIGIN" \
  "$SSH_FAILURE_FIXTURE/remote-home/dot-codex"; then
  fail "transport failure unexpectedly succeeded"
fi
[[ "$(tail -n 1 "$SSH_FAILURE_FIXTURE/lifecycle.log")" == "ssh-probe" ]] || fail "disconnected VPN did not fail at the reachability probe"
[[ -d "$SSH_FAILURE_FIXTURE/remote-home/.codex" && ! -L "$SSH_FAILURE_FIXTURE/remote-home/.codex" ]] || fail "transport failure changed .codex"

ROLLBACK_FIXTURE="$PROOF_TMP/rollback"
mkdir -p "$ROLLBACK_FIXTURE"
ROLLBACK_ORIGIN="$(make_origin "$ROLLBACK_FIXTURE")"
make_harness "$ROLLBACK_FIXTURE"
make_remote_codex_home "$ROLLBACK_FIXTURE"
ROLLBACK_REMOTE_DIR="$ROLLBACK_FIXTURE/remote-home/dot codex [rollback]&state"
if FAKE_CODEX_FAIL_START=1 FAKE_REMOTE_RECOVERY_FAIL=1 run_helper \
  "$ROLLBACK_FIXTURE" \
  "$ROLLBACK_ORIGIN" \
  "$ROLLBACK_REMOTE_DIR" >"$ROLLBACK_FIXTURE/output.log" 2>&1; then
  fail "restart failure unexpectedly succeeded"
fi
! rg -n '^(open|close)$' "$ROLLBACK_FIXTURE/lifecycle.log" >/dev/null || fail "rollback used a public SSH lifecycle"
[[ -d "$ROLLBACK_REMOTE_DIR/.git" ]] || fail "quoted remote-path override did not reach the clone boundary"
assert_file_contains "$ROLLBACK_FIXTURE/codex.log" "app-server daemon stop"
assert_file_contains "$ROLLBACK_FIXTURE/codex.log" "remote-control start --json"
assert_file_contains "$ROLLBACK_FIXTURE/remote-recovery.log" "remote-recover"
grep -F 'Remote Control is not connected after bounded repair attempts' "$ROLLBACK_FIXTURE/output.log" >/dev/null ||
  fail "rollback failure did not explain the exhausted repair"
[[ -d "$ROLLBACK_FIXTURE/remote-home/.codex" && ! -L "$ROLLBACK_FIXTURE/remote-home/.codex" ]] || fail "rollback did not restore the original .codex directory"
assert_file_contains "$ROLLBACK_FIXTURE/remote-home/.codex/auth.json" "preserved auth"

bash -n "$SCRIPT"
printf 'Dot Codex VM bootstrap proof passed.\n'
