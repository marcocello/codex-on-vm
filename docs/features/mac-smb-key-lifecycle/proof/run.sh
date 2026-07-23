#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
FAKE_STATE="$TMP/fake-state"
SESSION_STATE="$TMP/session/smb-access.json"
MOUNT_PATH="$TMP/mount"
mkdir -p "$FAKE_BIN" "$FAKE_STATE" "$MOUNT_PATH"
printf '%s' 'initial-key' >"$FAKE_STATE/key2"
: >"$FAKE_STATE/clipboard"
: >"$FAKE_STATE/events"

cat >"$FAKE_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF

cat >"$FAKE_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
{"subscription_id":"00000000-0000-0000-0000-000000000000","resource_group_name":"proof-rg","storage_account_name":"proofstorage","file_share_name":"workspace","local_mount_path":"$TEST_MOUNT_PATH"}
JSON
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '1.1.1.1'
EOF

cat >"$FAKE_BIN/nc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat >"$TEST_FAKE_STATE/clipboard"
EOF

cat >"$FAKE_BIN/mount_smbfs" <<'EOF'
#!/usr/bin/env bash
printf 'mount\n' >>"$TEST_FAKE_STATE/events"
[[ "$(cat "$TEST_FAKE_STATE/clipboard")" == "$(cat "$TEST_FAKE_STATE/key2")" ]]
[[ "${TEST_FAIL_MOUNT:-0}" != "1" ]] || exit 42
touch "$TEST_FAKE_STATE/mounted"
EOF

cat >"$FAKE_BIN/mount" <<'EOF'
#!/usr/bin/env bash
if [[ -f "$TEST_FAKE_STATE/mounted" ]]; then
  printf '//proofstorage.file.core.windows.net/workspace on %s (smbfs)\n' "$TEST_MOUNT_PATH"
fi
EOF

cat >"$FAKE_BIN/diskutil" <<'EOF'
#!/usr/bin/env bash
printf 'unmount\n' >>"$TEST_FAKE_STATE/events"
rm -f "$TEST_FAKE_STATE/mounted"
EOF

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
/bin/sleep 0.01
EOF

cat >"$FAKE_BIN/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "account show"*)
    printf '00000000-0000-0000-0000-000000000000\n'
    ;;
  "storage account network-rule add"*)
    printf 'rule-add\n' >>"$TEST_FAKE_STATE/events"
    touch "$TEST_FAKE_STATE/rule"
    ;;
  "storage account network-rule remove"*)
    printf 'rule-remove\n' >>"$TEST_FAKE_STATE/events"
    rm -f "$TEST_FAKE_STATE/rule"
    ;;
  "storage account show"*)
    if [[ -f "$TEST_FAKE_STATE/rule" ]]; then printf '1\n'; else printf '0\n'; fi
    ;;
  "storage account keys list"*)
    printf 'key-list\n' >>"$TEST_FAKE_STATE/events"
    cat "$TEST_FAKE_STATE/key2"
    printf '\n'
    ;;
  "storage account keys renew"*)
    printf 'key-renew\n' >>"$TEST_FAKE_STATE/events"
    [[ "${TEST_FAIL_RENEW:-0}" != "1" ]] || exit 43
    printf 'rotated-%s' "$(wc -l <"$TEST_FAKE_STATE/events" | tr -d ' ')" >"$TEST_FAKE_STATE/key2"
    cat "$TEST_FAKE_STATE/key2"
    printf '\n'
    ;;
  *)
    printf 'unexpected az invocation: %s\n' "$*" >&2
    exit 90
    ;;
esac
EOF

chmod +x "$FAKE_BIN"/*

export PATH="$FAKE_BIN:$PATH"
export TEST_FAKE_STATE="$FAKE_STATE"
export TEST_MOUNT_PATH="$MOUNT_PATH"
export CODEX_SMB_STATE_FILE="$SESSION_STATE"
export CODEX_SMB_CLIPBOARD_TTL_SECONDS=60

reset_scenario() {
  rm -f "$SESSION_STATE" "$SESSION_STATE.lock" "$FAKE_STATE/rule" "$FAKE_STATE/mounted"
  rm -rf "$SESSION_STATE.lock"
  printf '%s' 'initial-key' >"$FAKE_STATE/key2"
  : >"$FAKE_STATE/clipboard"
  : >"$FAKE_STATE/events"
}

assert_clean() {
  [[ ! -e "$SESSION_STATE" ]]
  [[ ! -e "$SESSION_STATE.lock" ]]
  [[ ! -e "$FAKE_STATE/rule" ]]
  [[ ! -e "$FAKE_STATE/mounted" ]]
  [[ ! -s "$FAKE_STATE/clipboard" ]]
}

reset_scenario
mkdir -p "$(dirname "$SESSION_STATE")" "$SESSION_STATE.lock"
if "$ROOT/scripts/smb-open.sh"; then
  printf 'expected occupied lifecycle lock to reject smb-open\n' >&2
  exit 1
fi
[[ -d "$SESSION_STATE.lock" ]]
[[ ! -e "$SESSION_STATE" ]]
[[ ! -s "$FAKE_STATE/events" ]]
[[ "$(cat "$FAKE_STATE/key2")" == "initial-key" ]]
rmdir "$SESSION_STATE.lock"

printf '{}\n' >"$SESSION_STATE"
mkdir "$SESSION_STATE.lock"
if "$ROOT/scripts/smb-close.sh"; then
  printf 'expected occupied lifecycle lock to reject smb-close\n' >&2
  exit 1
fi
[[ -d "$SESSION_STATE.lock" ]]
[[ -f "$SESSION_STATE" ]]
[[ ! -s "$FAKE_STATE/events" ]]
[[ "$(cat "$FAKE_STATE/key2")" == "initial-key" ]]
rm -f "$SESSION_STATE"
rmdir "$SESSION_STATE.lock"

"$ROOT/scripts/smb-open.sh"
[[ -f "$SESSION_STATE" ]]
[[ -f "$FAKE_STATE/rule" ]]
[[ -f "$FAKE_STATE/mounted" ]]
[[ ! -s "$FAKE_STATE/clipboard" ]]
[[ "$(cat "$FAKE_STATE/key2")" == "initial-key" ]]
python3 - "$SESSION_STATE" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(value) == {"key2_fingerprint", "mount_path", "public_ip", "resource_group", "storage_account"}
assert len(value["key2_fingerprint"]) == 64
assert "initial-key" not in json.dumps(value)
PY
"$ROOT/scripts/smb-close.sh"
assert_clean
[[ "$(cat "$FAKE_STATE/key2")" != "initial-key" ]]
python3 - "$FAKE_STATE/events" <<'PY'
import sys

events = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert events.index("rule-add") < events.index("mount") < events.index("unmount") < events.index("rule-remove") < events.index("key-renew")
PY

reset_scenario
export TEST_FAIL_MOUNT=1
if "$ROOT/scripts/smb-open.sh"; then
  printf 'expected failed mount to fail smb-open\n' >&2
  exit 1
fi
unset TEST_FAIL_MOUNT
assert_clean
[[ "$(cat "$FAKE_STATE/key2")" != "initial-key" ]]

reset_scenario
"$ROOT/scripts/smb-open.sh"
export TEST_FAIL_RENEW=1
if "$ROOT/scripts/smb-close.sh"; then
  printf 'expected failed key rotation to fail smb-close\n' >&2
  exit 1
fi
unset TEST_FAIL_RENEW
[[ -f "$SESSION_STATE" ]]
[[ ! -e "$SESSION_STATE.lock" ]]
[[ ! -e "$FAKE_STATE/rule" ]]
[[ ! -e "$FAKE_STATE/mounted" ]]
"$ROOT/scripts/smb-close.sh"
assert_clean
[[ "$(cat "$FAKE_STATE/key2")" != "initial-key" ]]

bash -n "$ROOT/scripts/smb-open.sh" "$ROOT/scripts/smb-close.sh"
printf 'Mac SMB key lifecycle proof passed.\n'
