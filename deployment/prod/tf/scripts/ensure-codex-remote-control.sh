#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_BIN="$CODEX_HOME/packages/standalone/current/codex"
DAEMON_DIR="$CODEX_HOME/app-server-daemon"
APP_PID_FILE="$DAEMON_DIR/app-server.pid"
UPDATER_PID_FILE="$DAEMON_DIR/app-server-updater.pid"
PS_BIN="${CODEX_RECOVERY_PS:-/usr/bin/ps}"
KILL_BIN="${CODEX_RECOVERY_KILL:-/bin/kill}"
SLEEP_BIN="${CODEX_RECOVERY_SLEEP:-/usr/bin/sleep}"
CMP_BIN="${CODEX_RECOVERY_CMP:-/usr/bin/cmp}"
PROC_ROOT="${CODEX_RECOVERY_PROC_ROOT:-/proc}"
PROCESS_USER="$(id -un)"

fail() {
  printf 'Codex Remote Control recovery failed: %s\n' "$1" >&2
  exit 1
}

daemon_ready() {
  local output managed_codex_path
  output="$("$CODEX_BIN" app-server daemon version)" || return 1
  managed_codex_path="$(jq -er '
    select(
      .status == "running" and
      (.appServerVersion | type == "string" and length > 0) and
      (.managedCodexPath | type == "string" and length > 0)
    )
    | .managedCodexPath
  ' <<<"$output")" || return 1
  [[ "$managed_codex_path" -ef "$CODEX_BIN" ]]
}

try_supported_recovery() {
  if "$CODEX_BIN" remote-control start --json && daemon_ready; then
    return 0
  fi
  if "$CODEX_BIN" app-server daemon restart && \
    "$CODEX_BIN" remote-control start --json && daemon_ready; then
    return 0
  fi
  return 1
}

record_value() {
  local path="$1"
  local field="$2"
  [[ -f "$path" ]] || return 1
  jq -er --arg field "$field" '.[$field]' "$path"
}

process_value() {
  local pid="$1"
  local field="$2"
  "$PS_BIN" -p "$pid" -o "$field" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

same_executable_content() {
  local candidate="$1"
  [[ -x "$candidate" && -x "$CODEX_BIN" ]] || return 1
  [[ "$candidate" -ef "$CODEX_BIN" ]] || "$CMP_BIN" -s "$candidate" "$CODEX_BIN"
}

verified_stale_processes() {
  local updater_args updater_executable
  UPDATER_PID="$(record_value "$UPDATER_PID_FILE" pid)" || return 1
  UPDATER_STARTED="$(record_value "$UPDATER_PID_FILE" processStartTime)" || return 1
  APP_PID="$(record_value "$APP_PID_FILE" pid)" || return 1
  APP_STARTED="$(record_value "$APP_PID_FILE" processStartTime)" || return 1
  [[ "$UPDATER_PID" =~ ^[0-9]+$ && "$UPDATER_PID" -gt 1 ]] || return 1
  [[ "$APP_PID" =~ ^[0-9]+$ && "$APP_PID" -gt 1 ]] || return 1
  [[ "$(process_value "$UPDATER_PID" user=)" == "$PROCESS_USER" ]] || return 1
  [[ "$(process_value "$UPDATER_PID" lstart=)" == "$UPDATER_STARTED" ]] || return 1
  updater_args="$(process_value "$UPDATER_PID" args=)" || return 1
  updater_executable="${updater_args% app-server daemon pid-update-loop}"
  [[ -n "$updater_executable" && "$updater_executable" != "$updater_args" ]] || return 1
  same_executable_content "$updater_executable" || return 1
  same_executable_content "$PROC_ROOT/$UPDATER_PID/exe" || return 1
  [[ "$(process_value "$APP_PID" user=)" == "$PROCESS_USER" ]] || return 1
  [[ "$(process_value "$APP_PID" lstart=)" == "$APP_STARTED" ]] || return 1
  [[ "$(process_value "$APP_PID" stat=)" == Z* ]] || return 1
  [[ "$(process_value "$APP_PID" ppid=)" == "$UPDATER_PID" ]] || return 1
}

terminate_verified_stale_parent() {
  verified_stale_processes || return 1
  "$KILL_BIN" -TERM "$UPDATER_PID"
  for _attempt in {1..10}; do
    if ! process_value "$UPDATER_PID" user= >/dev/null 2>&1 && \
      ! process_value "$APP_PID" user= >/dev/null 2>&1; then
      return 0
    fi
    "$SLEEP_BIN" 1
  done
  return 1
}

command -v jq >/dev/null || fail "jq is unavailable"
[[ -x "$CMP_BIN" ]] || fail "cmp is unavailable at $CMP_BIN"
[[ -x "$CODEX_BIN" ]] || fail "managed Codex install is unavailable at $CODEX_BIN"

if try_supported_recovery; then
  printf 'Codex Remote Control is ready.\n'
  exit 0
fi

terminate_verified_stale_parent || fail "supported lifecycle recovery failed and the stale process state was not safe to terminate"
try_supported_recovery || fail "managed daemon did not recover after terminating the verified stale updater"
printf 'Codex Remote Control recovered from a verified stale updater.\n'
