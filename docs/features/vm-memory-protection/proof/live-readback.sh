#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CODEX_VM_TEST_MODE=1 "$ROOT/scripts/codex-vm.sh" __extract-helpers "$TMP/extracted"
awk '/<<'"'"'SAMPLE'"'"'/ {capture=1; next} capture && /^SAMPLE$/ {exit} capture {print}' "$TMP/extracted/vm-scripts/prepare-codex-vm.sh" >"$TMP/expected"
[[ -s "$TMP/expected" ]]
ssh -o BatchMode=yes -o ConnectTimeout=8 codex-on-vm-vpn 'sudo -n cat /usr/local/sbin/codex-vm-memory-sample' >"$TMP/actual"
cmp "$TMP/expected" "$TMP/actual"
ssh -o BatchMode=yes -o ConnectTimeout=8 codex-on-vm-vpn 'set -eu; swapon --noheadings --show=NAME,SIZE | awk '\''$1=="/swapfile-codex-vm" && $2=="2G" {found=1} END {exit !found}'\''; sudo -n stat -c "%a" /swapfile-codex-vm | grep -Fx 600; awk '\''$1=="/swapfile-codex-vm" && $3=="swap" {found=1} END {exit !found}'\'' /etc/fstab; systemctl is-enabled --quiet codex-vm-memory-sample.timer; systemctl is-active --quiet codex-vm-memory-sample.timer; test "$(systemctl show codex-vm-memory-sample.service -p Result --value)" = success; journalctl -t codex-vm-memory --since "5 minutes ago" --no-pager -n 3 | grep -F "available_kib="; free -h'
printf 'Live swap and memory monitor read-back passed.\n'
