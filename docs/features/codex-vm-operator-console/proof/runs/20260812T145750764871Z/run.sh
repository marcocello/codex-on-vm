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
    current_line="$(rg -n -F "$expected_pattern" "$target_file" | awk -F: -v previous="$previous_line" '$1 > previous { print $1; exit }' || true)"
    [[ -n "$current_line" ]] || fail "$target_file omits ordered output after line $previous_line: $expected_pattern"
    previous_line="$current_line"
  done
}

printf 'Bash: %s | %s\n' "$(command -v bash)" "$(bash --version | sed -n '1p')"
printf 'Console: %s\n' "$CONSOLE"
printf 'Proof mode: production parser, pseudo-terminal menu, visible checks, fake disconnected VPN, and embedded extraction\n'

[[ -x "$CONSOLE" ]] || fail "production console is not executable"
command -v expect >/dev/null || fail "pseudo-terminal driver is unavailable"
bash -n "$CONSOLE"
"$CONSOLE" help >"$TMP/help.txt"

for command in setup sign-in pair dot-codex telegram-to-agents vpn-setup menu help; do
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

MENU_FAKE_BIN="$TMP/menu-bin"
MENU_FAKE_HELPERS="$TMP/menu-helpers"
MENU_HELPER_LOG="$TMP/menu-helper.log"
MENU_OPENVPN_PROFILE="$TMP/menu-codex-on-vm.ovpn"
mkdir -p "$MENU_FAKE_BIN" "$MENU_FAKE_HELPERS"
: >"$MENU_OPENVPN_PROFILE"
cat >"$MENU_FAKE_BIN/terraform" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"subscription_id":"00000000-0000-0000-0000-000000000000","resource_group_name":"prod-codex-on-vm-rg","vm_name":"prod-codex-on-vm-vm","workspace_mount_path":"/home/azureadmin/projects","codex_version":"0.144.3"}
JSON
SH
cat >"$MENU_FAKE_BIN/az" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" account show "* ]]; then
  printf '00000000-0000-0000-0000-000000000000\n'
  exit 0
fi
if [[ " $* " == *" vm run-command invoke "* ]]; then
  if [[ "${MENU_AZ_DELAY_SECONDS:-0}" != "0" ]]; then
    sleep "$MENU_AZ_DELAY_SECONDS"
  fi
  printf '%s\n' '{"value":[{"message":"CODEX_ON_VM_PREPARED=1"}]}'
  exit 0
fi
exit 90
SH
cat >"$MENU_FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
chmod +x "$MENU_FAKE_BIN/terraform" "$MENU_FAKE_BIN/az" "$MENU_FAKE_BIN/ssh"
for helper in prepare-machine.sh codex-pair.sh dot-codex-bootstrap.sh telegram-to-agents-bootstrap.sh openvpn-setup.sh; do
  cat >"$MENU_FAKE_HELPERS/$helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'VISIBLE_HELPER:%s' "$(basename "$0")"
if [[ $# -gt 0 ]]; then
  printf ' %s' "$@"
fi
printf '\n'
printf '%s' "$(basename "$0")" >>"$MENU_HELPER_LOG"
if [[ $# -gt 0 ]]; then
  printf ' %s' "$@" >>"$MENU_HELPER_LOG"
fi
printf '\n' >>"$MENU_HELPER_LOG"
SH
  chmod +x "$MENU_FAKE_HELPERS/$helper"
done

for selection in 1 2 3 4 5 6; do
  MENU_OUTPUT="$TMP/menu-$selection.txt"
  menu_az_delay_seconds=0
  if [[ "$selection" == "2" ]]; then
    menu_az_delay_seconds=2
  fi
  : >"$MENU_HELPER_LOG"
  if ! CONSOLE_PATH="$CONSOLE" \
    MENU_SELECTION="$selection" \
    MENU_AZ_DELAY_SECONDS="$menu_az_delay_seconds" \
    MENU_PATH="$MENU_FAKE_BIN:$PATH" \
    MENU_HELPER_DIR="$MENU_FAKE_HELPERS" \
    MENU_HELPER_LOG="$MENU_HELPER_LOG" \
    MENU_PROFILE="$MENU_OPENVPN_PROFILE" \
    expect >"$MENU_OUTPUT" 2>&1 <<'EXPECT'; then
set timeout 10
spawn env \
  PATH=$env(MENU_PATH) \
  CODEX_VM_TEST_MODE=1 \
  CODEX_VM_PREPARATION_PROGRESS_SECONDS=1 \
  CODEX_VM_TEST_HELPER_DIR=$env(MENU_HELPER_DIR) \
  CODEX_VM_OPENVPN_PROFILE_PATH=$env(MENU_PROFILE) \
  MENU_AZ_DELAY_SECONDS=$env(MENU_AZ_DELAY_SECONDS) \
  MENU_HELPER_LOG=$env(MENU_HELPER_LOG) \
  $env(CONSOLE_PATH) --no-color
expect "Choose an action:"
send "$env(MENU_SELECTION)\r"
expect eof
lassign [wait] pid spawn_id os_error exit_code
exit $exit_code
EXPECT
    fail "menu option $selection did not complete successfully"
  fi

  [[ "$(rg -c -F 'Codex VM operator console' "$MENU_OUTPUT")" == "1" ]] ||
    fail "menu option $selection did not return after one action"
  case "$selection" in
    1) expected_helper='prepare-machine.sh' ;;
    2) expected_helper='codex-pair.sh sign-in' ;;
    3) expected_helper='codex-pair.sh pair' ;;
    4) expected_helper='dot-codex-bootstrap.sh' ;;
    5) expected_helper='telegram-to-agents-bootstrap.sh' ;;
    6) expected_helper='openvpn-setup.sh' ;;
  esac
  [[ "$(<"$MENU_HELPER_LOG")" == "$expected_helper" ]] ||
    fail "menu option $selection mapped to $(<"$MENU_HELPER_LOG"), expected $expected_helper"
  rg -F "VISIBLE_HELPER:$expected_helper" "$MENU_OUTPUT" >/dev/null ||
    fail "menu option $selection hid successful helper output"
  if [[ "$selection" == "1" ]]; then
    if rg -F 'Check OpenVPN connection' "$MENU_OUTPUT" >/dev/null; then
      fail "menu setup incorrectly required OpenVPN"
    fi
  else
    assert_patterns_in_order \
      "$MENU_OUTPUT" \
      '==> Check VM preparation' \
      'Done: VM preparation is current' \
      '==> Check OpenVPN connection' \
      'Done: OpenVPN is connected' \
      "VISIBLE_HELPER:$expected_helper" \
      'Done:'
  fi
  if [[ "$selection" == "2" ]]; then
    assert_patterns_in_order \
      "$MENU_OUTPUT" \
      '    Terraform: read current VM target' \
      '    Azure: verify active subscription' \
      '    Azure: inspect preparation marker on prod-codex-on-vm-vm' \
      '    Azure: still checking VM preparation (1s elapsed)' \
      'Done: VM preparation is current'
  fi
done

MENU_OUTPUT="$TMP/menu-1.txt" python3 - <<'PY'
import os
import pathlib
import re

text = pathlib.Path(os.environ["MENU_OUTPUT"]).read_text(encoding="utf-8")
def clears_terminal(value: str) -> bool:
    return "\x1bc" in value or "\x0c" in value or re.search(r"\x1b\[[0-9;?]*J", value) is not None

known_clear_sequences = ("\x1bc", "\x0c", "\x1b[H\x1b[2J", "\x1b[3J\x1b[H\x1b[2J")
if not all(clears_terminal(sequence) for sequence in known_clear_sequences):
    raise SystemExit("terminal-clear oracle does not recognize a known reset/erase sequence")
if clears_terminal(text):
    raise SystemExit("menu emitted a terminal reset or erase-display sequence")
numbered = [
    line.rstrip("\r")
    for line in text.splitlines()
    if re.fullmatch(r"  [0-9]+\) .+", line.rstrip("\r"))
]
expected = [
    "  1) Set up or repair Codex on the VM",
    "  2) Sign in to Codex",
    "  3) Pair a device",
    "  4) Clone or update dot-codex from GitHub",
    "  5) Install or update telegram-to-agents",
    "  6) Repair OpenVPN",
]
if numbered != expected:
    raise SystemExit(f"menu numbered options differ: {numbered!r}")
PY
printf 'Menu fixture: exact options 1-6, exact mappings, visible helper output, then return\n'

EXTRACTED="$TMP/extracted"
CODEX_VM_TEST_MODE=1 "$CONSOLE" __extract-helpers "$EXTRACTED"
expected_mac="prepare-machine.sh codex-pair.sh dot-codex-bootstrap.sh telegram-to-agents-bootstrap.sh openvpn-setup.sh remote-control-recover.sh"
expected_vm="ensure-codex-remote-control.sh ensure-ssh-keys.sh fetch-verified-artifact.sh install-verified-codex.sh configure-codex-openvpn.sh prepare-codex-vm.sh prepare-persistent-codex-home.sh"
[[ "$(find "$EXTRACTED/scripts" -type f -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')" == "6" ]] ||
  fail "extracted Mac helper count is not six"
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

TTA_HELPER="$EXTRACTED/scripts/telegram-to-agents-bootstrap.sh"
TTA_FIXTURE="$TMP/telegram-to-agents"
TTA_ORIGIN="$TTA_FIXTURE/origin.git"
TTA_SEED="$TTA_FIXTURE/seed"
TTA_REMOTE_HOME="$TTA_FIXTURE/home"
TTA_REMOTE_DIR="$TTA_REMOTE_HOME/projects/telegram-to-agents"
TTA_REMOTE_BIN="$TTA_FIXTURE/remote-bin"
TTA_FAKE_BIN="$TTA_FIXTURE/fake-bin"
TTA_ACTION_LOG="$TTA_FIXTURE/actions.log"
TTA_SERVICE_MARKER="$TTA_FIXTURE/service-enabled"
TTA_ACTIVE_MARKER="$TTA_FIXTURE/service-active"
mkdir -p "$TTA_SEED" "$TTA_REMOTE_HOME" "$TTA_REMOTE_BIN" "$TTA_FAKE_BIN"
: >"$TTA_ACTION_LOG"
mkdir -p "$TTA_REMOTE_HOME/.codex" "$TTA_REMOTE_HOME/.claude"
printf 'model = "native-codex"\n' >"$TTA_REMOTE_HOME/.codex/config.toml"
printf '{"model":"native-claude"}\n' >"$TTA_REMOTE_HOME/.claude/settings.json"
TTA_NATIVE_CONFIG_BEFORE="$(shasum -a 256 \
  "$TTA_REMOTE_HOME/.codex/config.toml" \
  "$TTA_REMOTE_HOME/.claude/settings.json")"
rg -F 'https://github.com/marcocello/telegram-to-agents' "$TTA_HELPER" >/dev/null ||
  fail "telegram-to-agents helper omits the authoritative default repository"
rg -F '$HOME/projects/telegram-to-agents' "$TTA_HELPER" >/dev/null ||
  fail "telegram-to-agents helper omits the persistent default clone path"
git -C "$TTA_SEED" init -b main >/dev/null
printf '.venv/\n' >"$TTA_SEED/.gitignore"
git -C "$TTA_SEED" add .gitignore
git -C "$TTA_SEED" -c user.name=Proof -c user.email=proof@example.invalid \
  commit -m initial >/dev/null
git clone --bare "$TTA_SEED" "$TTA_ORIGIN" >/dev/null
git -C "$TTA_SEED" remote add origin "$TTA_ORIGIN"
git -C "$TTA_SEED" push -u origin main >/dev/null

cat >"$TTA_REMOTE_BIN/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-m" && "${2:-}" == "venv" && $# == 3 ]] || exit 91
venv="$3"
mkdir -p "$venv/bin"
cat >"$venv/bin/python" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-m" && "${2:-}" == "pip" && "${3:-}" == "install" ]] || exit 92
[[ "${4:-}" == "--upgrade" && "${5:-}" == "$TTA_EXPECTED_INSTALL_TARGET" && $# == 5 ]] || exit 96
printf 'pip-install:%s\n' "${*:4}" >>"$TTA_ACTION_LOG"
bin_dir="$(cd "$(dirname "$0")" && pwd)"
cat >"$bin_dir/telegram-to-agents" <<'CLI'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  onboarding)
    mkdir -p "$HOME/.telegram-to-agents/config"
    printf '{}\n' >"$HOME/.telegram-to-agents/config/config.json"
    : >"$TTA_SERVICE_MARKER"
    : >"$TTA_ACTIVE_MARKER"
    printf 'onboarding\n' >>"$TTA_ACTION_LOG"
    ;;
  restart)
    printf 'restart\n' >>"$TTA_ACTION_LOG"
    if [[ "${TTA_RESTART_ACTIVATES:-1}" == "1" ]]; then
      : >"$TTA_ACTIVE_MARKER"
    fi
    ;;
  *) exit 93 ;;
esac
CLI
chmod +x "$bin_dir/telegram-to-agents"
PYTHON
chmod +x "$venv/bin/python"
SH
cat >"$TTA_REMOTE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' is-enabled telegram-to-agents.service '*) [[ -f "$TTA_SERVICE_MARKER" ]] ;;
  *' is-active telegram-to-agents.service '*) [[ -f "$TTA_ACTIVE_MARKER" ]] ;;
  *) exit 94 ;;
esac
SH
cat >"$TTA_FAKE_BIN/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' true '* ]]; then
  exit 0
fi
if [[ " $* " == *' onboarding '* ]]; then
  HOME="$TTA_REMOTE_HOME" PATH="$TTA_REMOTE_BIN:/usr/bin:/bin" \
    TTA_ACTIVE_MARKER="$TTA_ACTIVE_MARKER" \
    TTA_RESTART_ACTIVATES="${TTA_RESTART_ACTIVATES:-1}" \
    "$TTA_REMOTE_HOME/.local/bin/telegram-to-agents" onboarding
  exit 0
fi
if [[ " $* " == *' bash -s -- '* ]]; then
  HOME="$TTA_REMOTE_HOME" PATH="$TTA_REMOTE_BIN:/usr/bin:/bin" \
    TTA_ACTION_LOG="$TTA_ACTION_LOG" \
    TTA_SERVICE_MARKER="$TTA_SERVICE_MARKER" \
    TTA_ACTIVE_MARKER="$TTA_ACTIVE_MARKER" \
    TTA_EXPECTED_INSTALL_TARGET="$TTA_REMOTE_DIR" \
    TTA_RESTART_ACTIVATES="${TTA_RESTART_ACTIVATES:-1}" \
    bash -s -- "$TTA_ORIGIN" "$TTA_REMOTE_DIR"
  exit 0
fi
exit 95
SH
chmod +x "$TTA_REMOTE_BIN/python3" "$TTA_REMOTE_BIN/systemctl" "$TTA_FAKE_BIN/ssh"

run_tta_helper() {
  PATH="$TTA_FAKE_BIN:$PATH" \
  CODEX_VM_VPN_SSH_ALIAS=proof-vm \
  TELEGRAM_TO_AGENTS_REPOSITORY_URL="$TTA_ORIGIN" \
  TELEGRAM_TO_AGENTS_REMOTE_DIR="$TTA_REMOTE_DIR" \
  TTA_REMOTE_HOME="$TTA_REMOTE_HOME" \
  TTA_REMOTE_DIR="$TTA_REMOTE_DIR" \
  TTA_REMOTE_BIN="$TTA_REMOTE_BIN" \
  TTA_ORIGIN="$TTA_ORIGIN" \
  TTA_ACTION_LOG="$TTA_ACTION_LOG" \
  TTA_SERVICE_MARKER="$TTA_SERVICE_MARKER" \
  TTA_ACTIVE_MARKER="$TTA_ACTIVE_MARKER" \
  TTA_EXPECTED_INSTALL_TARGET="$TTA_REMOTE_DIR" \
  TTA_RESTART_ACTIVATES="${TTA_RESTART_ACTIVATES:-1}" \
  "$TTA_HELPER"
}

run_tta_helper
[[ "$(git -C "$TTA_REMOTE_DIR" remote get-url origin)" == "$TTA_ORIGIN" ]] ||
  fail "telegram-to-agents first install used the wrong origin"
[[ -L "$TTA_REMOTE_HOME/.local/bin/telegram-to-agents" ]] ||
  fail "telegram-to-agents CLI link was not created"
[[ "$(readlink "$TTA_REMOTE_HOME/.local/bin/telegram-to-agents")" == \
  "$TTA_REMOTE_DIR/.venv/bin/telegram-to-agents" ]] ||
  fail "telegram-to-agents CLI link does not target the checkout virtual environment"
rg -F "pip-install:--upgrade $TTA_REMOTE_DIR" "$TTA_ACTION_LOG" >/dev/null ||
  fail "telegram-to-agents did not install the checked-out repository"
[[ "$(rg -c '^onboarding$' "$TTA_ACTION_LOG")" == "1" ]] ||
  fail "telegram-to-agents first install did not onboard exactly once"

printf 'updated\n' >"$TTA_SEED/version.txt"
git -C "$TTA_SEED" add version.txt
git -C "$TTA_SEED" -c user.name=Proof -c user.email=proof@example.invalid \
  commit -m update >/dev/null
git -C "$TTA_SEED" push origin main >/dev/null
rm -f "$TTA_ACTIVE_MARKER"
run_tta_helper
[[ "$(<"$TTA_REMOTE_DIR/version.txt")" == "updated" ]] ||
  fail "telegram-to-agents update did not fast-forward"
[[ "$(rg -c '^onboarding$' "$TTA_ACTION_LOG")" == "1" ]] ||
  fail "telegram-to-agents update repeated onboarding"
[[ "$(rg -c '^restart$' "$TTA_ACTION_LOG")" == "1" ]] ||
  fail "telegram-to-agents update did not restart the installed service"
[[ -f "$TTA_ACTIVE_MARKER" ]] ||
  fail "telegram-to-agents update did not activate the installed service"
[[ "$(shasum -a 256 \
  "$TTA_REMOTE_HOME/.codex/config.toml" \
  "$TTA_REMOTE_HOME/.claude/settings.json")" == "$TTA_NATIVE_CONFIG_BEFORE" ]] ||
  fail "telegram-to-agents action changed native Codex or Claude configuration"

rm -f "$TTA_ACTIVE_MARKER"
if TTA_RESTART_ACTIVATES=0 run_tta_helper >"$TMP/tta-inactive.txt" 2>&1; then
  fail "telegram-to-agents update succeeded while its service stayed inactive"
fi
[[ ! -f "$TTA_ACTIVE_MARKER" ]] ||
  fail "telegram-to-agents inactive-service fixture activated unexpectedly"

touch "$TTA_REMOTE_DIR/dirty.txt"
if run_tta_helper >"$TMP/tta-dirty.txt" 2>&1; then
  fail "telegram-to-agents update accepted a dirty checkout"
fi
rm "$TTA_REMOTE_DIR/dirty.txt"
git -C "$TTA_REMOTE_DIR" remote set-url origin "$TTA_FIXTURE/wrong.git"
if run_tta_helper >"$TMP/tta-wrong-origin.txt" 2>&1; then
  fail "telegram-to-agents update accepted the wrong origin"
fi
git -C "$TTA_REMOTE_DIR" remote set-url origin "$TTA_ORIGIN"
git -C "$TTA_REMOTE_DIR" checkout --detach >/dev/null
if run_tta_helper >"$TMP/tta-detached.txt" 2>&1; then
  fail "telegram-to-agents update accepted a detached checkout"
fi
git -C "$TTA_REMOTE_DIR" checkout main >/dev/null

printf 'local\n' >"$TTA_REMOTE_DIR/local.txt"
git -C "$TTA_REMOTE_DIR" add local.txt
git -C "$TTA_REMOTE_DIR" -c user.name=Proof -c user.email=proof@example.invalid \
  commit -m local >/dev/null
printf 'remote\n' >"$TTA_SEED/remote.txt"
git -C "$TTA_SEED" add remote.txt
git -C "$TTA_SEED" -c user.name=Proof -c user.email=proof@example.invalid \
  commit -m remote >/dev/null
git -C "$TTA_SEED" push origin main >/dev/null
if run_tta_helper >"$TMP/tta-diverged.txt" 2>&1; then
  fail "telegram-to-agents update accepted a divergent checkout"
fi
printf 'telegram-to-agents fixture: clone, install, onboarding, fast-forward, restart, and safety rejection passed.\n'

"$ROOT/docs/features/self-hosted-openvpn-access/proof/openvpn-scenario.sh" \
  "$EXTRACTED" "$TMP/operator-openvpn"

for command in sign-in pair dot-codex telegram-to-agents vpn-setup; do
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
FAKE_OPENVPN_PROFILE="$TMP/codex-on-vm.ovpn"
mkdir -p "$FAKE_BIN" "$FAKE_HELPERS"
: >"$FAKE_OPENVPN_PROFILE"
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
for helper in codex-pair.sh dot-codex-bootstrap.sh telegram-to-agents-bootstrap.sh openvpn-setup.sh; do
  cat >"$FAKE_HELPERS/$helper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(basename "$0")" >>"$HELPER_CALL_LOG"
SH
  chmod +x "$FAKE_HELPERS/$helper"
done

for command in sign-in pair dot-codex telegram-to-agents vpn-setup; do
  : >"$HELPER_CALL_LOG"
  if PATH="$FAKE_BIN:$PATH" \
    CODEX_VM_TEST_MODE=1 \
    CODEX_VM_TEST_HELPER_DIR="$FAKE_HELPERS" \
    CODEX_VM_OPENVPN_PROFILE_PATH="$FAKE_OPENVPN_PROFILE" \
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
for command in setup sign-in pair dot-codex telegram-to-agents menu; do
  if "$CONSOLE" --dry-run "$command" unexpected >"$TMP/bad-$command.txt" 2>&1; then
    fail "$command accepted an unexpected argument"
  fi
done

if rg -n '__CODEX_VM_HELPER_BEGIN__ (ssh-open|ssh-close|workspace-open|workspace-close)[.]sh' "$CONSOLE" >/dev/null; then
  fail "production console retains a removed helper"
fi

printf 'Codex VM operator console proof passed.\n'
