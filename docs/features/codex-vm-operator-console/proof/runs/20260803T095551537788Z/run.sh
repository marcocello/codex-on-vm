#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CONSOLE="$ROOT/scripts/codex-vm.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() {
  printf 'Codex VM operator console proof failed: %s\n' "$1" >&2
  exit 1
}

assert_patterns_in_order() {
  local target_file="$1"
  shift
  local previous_line=0 expected_pattern current_line
  for expected_pattern in "$@"; do
    current_line="$(rg -n -F "$expected_pattern" "$target_file" | awk -F: -v previous="$previous_line" '$1 > previous { print $1; exit }')"
    [[ -n "$current_line" ]] || fail "$target_file omits ordered output after line $previous_line: $expected_pattern"
    previous_line="$current_line"
  done
}

printf 'Bash: %s | %s\n' "$(command -v bash)" "$(bash --version | sed -n '1p')"
printf 'Console: %s\n' "$CONSOLE"
printf 'Proof mode: production parser, pseudo-terminal menu, visible checks, fake disconnected VPN, and embedded extraction\n'

[[ -x "$CONSOLE" ]] || fail "production console is not executable"
command -v script >/dev/null || fail "pseudo-terminal driver is unavailable"
bash -n "$CONSOLE"
"$CONSOLE" help >"$TMP/help.txt"

for command in setup sign-in pair dot-codex vpn-setup menu help; do
  rg -n "^  $command([[:space:]]|$)" "$TMP/help.txt" >/dev/null ||
    fail "help omits retained command: $command"
done
for removed in shell status ssh-open ssh-close workspace-open workspace-close deploy prepare sync-config repair; do
  if "$CONSOLE" --dry-run "$removed" >"$TMP/removed-$removed.txt" 2>&1; then
    fail "parser accepted removed command: $removed"
  fi
done
if rg -n '^  (shell|status|ssh-open|ssh-close|workspace-open|workspace-close)([[:space:]]|$)' "$TMP/help.txt" >/dev/null; then
  fail "help retains a removed command"
fi

printf '4\n' |
  script -q "$TMP/menu.typescript" "$CONSOLE" --dry-run --no-color >/dev/null 2>&1 ||
  fail "single-action menu invocation failed"
MENU_OUTPUT="$TMP/menu.typescript"
for menu_line in \
  '  1) Set up or repair Codex on the VM' \
  '  2) Sign in to Codex' \
  '  3) Pair a device' \
  '  4) Clone or update dot-codex from GitHub' \
  '  5) Repair or rotate OpenVPN'; do
  rg -F "$menu_line" "$MENU_OUTPUT" >/dev/null || fail "menu omits: $menu_line"
done
if rg -n '^[[:space:]]*(0|6|7)[)]' "$MENU_OUTPUT" >/dev/null; then
  fail "menu retains option 0, 6, or 7"
fi
[[ "$(rg -c -F 'Codex VM operator console' "$MENU_OUTPUT")" == "1" ]] ||
  fail "menu did not return after one selected action"
rg -F 'embedded helper: dot-codex-bootstrap.sh' "$MENU_OUTPUT" >/dev/null ||
  fail "menu option 4 did not visibly activate dot-codex"
printf 'Menu fixture: exactly options 1-5, one visible action, then return\n'

EXTRACTED="$TMP/extracted"
CODEX_VM_TEST_MODE=1 "$CONSOLE" __extract-helpers "$EXTRACTED"
expected_mac="prepare-machine.sh codex-pair.sh dot-codex-bootstrap.sh openvpn-setup.sh remote-control-recover.sh"
expected_vm="ensure-codex-remote-control.sh ensure-ssh-keys.sh fetch-verified-artifact.sh install-verified-codex.sh configure-codex-openvpn.sh prepare-codex-vm.sh prepare-persistent-codex-home.sh"
[[ "$(find "$EXTRACTED/scripts" -type f -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')" == "5" ]] ||
  fail "extracted Mac helper count is not five"
[[ "$(find "$EXTRACTED/vm-scripts" -type f -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')" == "7" ]] ||
  fail "extracted VM payload count is not seven"
for helper in $expected_mac; do
  [[ -x "$EXTRACTED/scripts/$helper" ]] || fail "missing Mac helper: $helper"
  bash -n "$EXTRACTED/scripts/$helper"
done
for helper in $expected_vm; do
  [[ -x "$EXTRACTED/vm-scripts/$helper" ]] || fail "missing VM payload: $helper"
  bash -n "$EXTRACTED/vm-scripts/$helper"
done
for removed in ssh-open.sh ssh-close.sh workspace-open.sh workspace-close.sh; do
  [[ ! -e "$EXTRACTED/scripts/$removed" ]] || fail "removed helper was extracted: $removed"
done

for command in sign-in pair dot-codex vpn-setup; do
  "$CONSOLE" --dry-run "$command" >"$TMP/dry-$command.txt"
  assert_patterns_in_order \
    "$TMP/dry-$command.txt" \
    '==> Check VM preparation' \
    'Done: VM preparation check planned' \
    '==> Check OpenVPN connection' \
    'Done: OpenVPN connection check planned' \
    'embedded helper:' \
    'Done:'
done
"$CONSOLE" --dry-run setup >"$TMP/dry-setup.txt"
rg -F 'embedded helper: prepare-machine.sh' "$TMP/dry-setup.txt" >/dev/null ||
  fail "setup did not visibly activate machine preparation"
if rg -F 'Check OpenVPN connection' "$TMP/dry-setup.txt" >/dev/null; then
  fail "Azure Run Command setup incorrectly requires OpenVPN"
fi
"$CONSOLE" --dry-run vpn-setup --rotate >"$TMP/dry-vpn-rotate.txt"
rg -F 'embedded helper: openvpn-setup.sh --rotate' "$TMP/dry-vpn-rotate.txt" >/dev/null ||
  fail "vpn rotation flag was not preserved"
printf 'Dry-run fixture: preparation, VPN, activation, and result are visible in order\n'

FAKE_BIN="$TMP/fake-bin"
FAKE_HELPERS="$TMP/fake-helpers"
HELPER_CALL_LOG="$TMP/helper-calls.log"
mkdir -p "$FAKE_BIN" "$FAKE_HELPERS"
cat >"$FAKE_BIN/terraform" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"subscription_id":"00000000-0000-0000-0000-000000000000","resource_group_name":"prod-codex-on-vm-rg","vm_name":"prod-codex-on-vm-vm","workspace_mount_path":"/home/azureadmin/projects","codex_version":"0.144.3"}
JSON
SH
cat >"$FAKE_BIN/az" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" account show "* ]]; then
  printf '00000000-0000-0000-0000-000000000000\n'
  exit 0
fi
if [[ " $* " == *" vm run-command invoke "* ]]; then
  printf '%s\n' '{"value":[{"message":"CODEX_ON_VM_PREPARED=1"}]}'
  exit 0
fi
exit 90
SH
cat >"$FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 23
SH
chmod +x "$FAKE_BIN/terraform" "$FAKE_BIN/az" "$FAKE_BIN/ssh"
for helper in codex-pair.sh dot-codex-bootstrap.sh openvpn-setup.sh; do
  cat >"$FAKE_HELPERS/$helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(basename "$0")" >>"$HELPER_CALL_LOG"
SH
  chmod +x "$FAKE_HELPERS/$helper"
done

for command in sign-in pair dot-codex vpn-setup; do
  : >"$HELPER_CALL_LOG"
  if PATH="$FAKE_BIN:$PATH" \
    CODEX_VM_TEST_MODE=1 \
    CODEX_VM_TEST_HELPER_DIR="$FAKE_HELPERS" \
    HELPER_CALL_LOG="$HELPER_CALL_LOG" \
    "$CONSOLE" --no-color "$command" >"$TMP/disconnected-$command.txt" 2>&1; then
    fail "$command succeeded while OpenVPN was disconnected"
  fi
  assert_patterns_in_order \
    "$TMP/disconnected-$command.txt" \
    '==> Check VM preparation' \
    'Done: VM preparation is current' \
    '==> Check OpenVPN connection' \
    'OpenVPN is not connected'
  rg -F 'import it into the Mac OpenVPN client, connect it, and retry' "$TMP/disconnected-$command.txt" >/dev/null ||
    fail "$command did not provide import/connect guidance"
  [[ ! -s "$HELPER_CALL_LOG" ]] || fail "$command invoked its action helper while disconnected"
done
printf 'Disconnected fixture: options 2-5 stop visibly before helper activation\n'

if "$CONSOLE" --dry-run vpn-setup --bad >"$TMP/bad-vpn.txt" 2>&1; then
  fail "vpn-setup accepted an unexpected option"
fi
for command in setup sign-in pair dot-codex menu; do
  if "$CONSOLE" --dry-run "$command" unexpected >"$TMP/bad-$command.txt" 2>&1; then
    fail "$command accepted an unexpected argument"
  fi
done

if rg -n '__CODEX_VM_HELPER_BEGIN__ (ssh-open|ssh-close|workspace-open|workspace-close)[.]sh' "$CONSOLE" >/dev/null; then
  fail "production console retains a removed helper"
fi

printf 'Codex VM operator console proof passed.\n'
