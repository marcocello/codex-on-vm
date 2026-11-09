#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CODEX_VM_TEST_MODE=1 "$ROOT/scripts/codex-vm.sh" __extract-helpers "$TMP/extracted"
bash -n "$TMP/extracted/vm-scripts/prepare-codex-vm.sh"
"$ROOT/docs/features/vm-memory-protection/proof/memory-guard-scenario.sh" "$TMP/extracted/vm-scripts/prepare-codex-vm.sh" "$TMP"
"$ROOT/docs/features/remote-control-managed-workspace/proof/prepare-machine-scenario.sh" "$TMP/extracted" "$TMP"
