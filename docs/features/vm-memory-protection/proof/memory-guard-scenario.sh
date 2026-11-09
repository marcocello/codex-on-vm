#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || exit 64
HELPER="$1"
TMP="$2/memory-guard"
mkdir -p "$TMP/bin" "$TMP/root/etc"
export FAKE_ROOT="$TMP/root" FAKE_STATE="$TMP/state" FAKE_CALLS="$TMP/calls"
: >"$FAKE_CALLS"
: >"$FAKE_ROOT/etc/fstab"
awk '/^configure_memory_guard\(\) \{/ {active=1} active {print} active && /^}$/ {exit}' "$HELPER" | sed "s|/run/lock/codex-vm-swap.lock|$TMP/swap.lock|g" > "$TMP/guard.sh"
cat >"$TMP/bin/swapon" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == --noheadings ]]; then [[ ! -e "$FAKE_STATE" ]] || cat "$FAKE_STATE"; exit 0; fi
printf '/swapfile-codex-vm\n' >"$FAKE_STATE"
printf 'swapon\n' >>"$FAKE_CALLS"
MOCK
cat >"$TMP/bin/fallocate" <<'MOCK'
#!/usr/bin/env bash
printf 'fallocate\n' >>"$FAKE_CALLS"
touch "${@: -1}"
MOCK
cat >"$TMP/bin/mkswap" <<'MOCK'
#!/usr/bin/env bash
printf 'mkswap\n' >>"$FAKE_CALLS"
MOCK
cat >"$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$FAKE_CALLS"
MOCK
cat >"$TMP/bin/flock" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/"*
cat >"$TMP/run" <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
TEST_MODE=0
root_path() { printf '%s%s\n' "$FAKE_ROOT" "$1"; }
fail() { echo "$1" >&2; exit 1; }
write_if_changed() {
  local mode="$1" target="$2"
  mkdir -p "$(dirname "$target")"
  cat >"$target"
  chmod "$mode" "$target"
}
source "$GUARD_SCRIPT"
configure_memory_guard
RUN
chmod +x "$TMP/run"
export PATH="$TMP/bin:$PATH" GUARD_SCRIPT="$TMP/guard.sh"
"$TMP/run"
[[ -f "$FAKE_ROOT/swapfile-codex-vm" ]]
grep -Fx '/swapfile-codex-vm none swap sw 0 0' "$FAKE_ROOT/etc/fstab" >/dev/null
[[ "$(grep -c '^swapon$' "$FAKE_CALLS")" == 1 ]]
"$TMP/run"
[[ "$(grep -c '^fallocate$' "$FAKE_CALLS")" == 1 ]]
[[ "$(grep -c '^/swapfile-codex-vm none swap sw 0 0$' "$FAKE_ROOT/etc/fstab")" == 1 ]]
rm -f "$FAKE_STATE" "$FAKE_ROOT/swapfile-codex-vm"
printf '/dev/foreign none swap sw 0 0\n' >"$FAKE_ROOT/etc/fstab"
if "$TMP/run"; then echo 'foreign swap configuration was accepted' >&2; exit 1; fi
[[ ! -e "$FAKE_ROOT/swapfile-codex-vm" ]]
grep -Fx '/dev/foreign none swap sw 0 0' "$FAKE_ROOT/etc/fstab" >/dev/null
printf 'Memory guard creation, idempotence, and existing swap checks passed.\n'
