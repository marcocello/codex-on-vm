#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TF_DIR="$ROOT/deployment/prod/tf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
OPERATOR_ROOT="$TMP/operator-root"

fail() {
  printf 'Remote-control managed workspace proof failed: %s\n' "$1" >&2
  exit 1
}

printf 'Terraform: %s\n' "$(terraform version | sed -n '1p')"
printf 'Bash: %s | %s\n' "$(command -v bash)" "$(bash --version | sed -n '1p')"
printf 'Proof mode: mocked Azure transport with production Terraform and extracted payloads\n'

"$ROOT/docs/features/pinned-root-provisioning/proof/run.sh"
"$ROOT/docs/features/dot-codex-vm-bootstrap/proof/run.sh"
terraform -chdir="$TF_DIR" test -filter=tests/remote_control_managed_workspace.tftest.hcl

if rg -n '^[[:space:]]*custom_data[[:space:]]*=|resource[[:space:]]+"azurerm_virtual_machine_run_command"|provisioner[[:space:]]+"remote-exec"'   "$TF_DIR" --glob '*.tf' --glob '!**/tests/**' >/dev/null; then
  fail "Terraform owns guest preparation"
fi
STANDING_RULES="$(rg -n 'resource[[:space:]]+"azurerm_network_security_rule"' "$TF_DIR" --glob '*.tf' --glob '!**/tests/**' || true)"
[[ "$(printf '%s\n' "$STANDING_RULES" | rg -c 'resource[[:space:]]+"azurerm_network_security_rule"')" == "1" ]] ||
  fail "Terraform does not contain exactly one standing NSG rule"
[[ "$STANDING_RULES" == *'resource "azurerm_network_security_rule" "openvpn"'* ]] ||
  fail "the standing rule is not OpenVPN"
if rg -n 'destination_port_ranges?[[:space:]]*=[^#]*"22"' "$TF_DIR" --glob '*.tf' --glob '!**/tests/**' >/dev/null; then
  fail "Terraform exposes TCP/22"
fi
rg -n '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TF_DIR/storage.tf" >/dev/null ||
  fail "workspace disk destruction guard is missing"

CODEX_VM_TEST_MODE=1 "$ROOT/scripts/codex-vm.sh" __extract-helpers "$OPERATOR_ROOT"
for script in "$OPERATOR_ROOT"/scripts/*.sh "$OPERATOR_ROOT"/vm-scripts/*.sh; do
  bash -n "$script"
done
"$ROOT/docs/features/remote-control-managed-workspace/proof/prepare-machine-scenario.sh" "$OPERATOR_ROOT" "$TMP"

HOME_HELPER="$OPERATOR_ROOT/vm-scripts/prepare-persistent-codex-home.sh"
ADMIN_USER="$(id -un)"

FRESH="$TMP/home-fresh"
mkdir -p "$FRESH/home" "$FRESH/projects"
FRESH_SELECTED="$("$HOME_HELPER" "$ADMIN_USER" "$FRESH/home" "$FRESH/projects")"
[[ "$FRESH_SELECTED" == "$FRESH/projects/.codex" ]] || fail "fresh persistent home selected the wrong path"
[[ "$(readlink -f "$FRESH/home/.codex")" == "$(readlink -f "$FRESH_SELECTED")" ]] ||
  fail "fresh persistent home symlink is wrong"

EXISTING="$TMP/home-existing"
mkdir -p "$EXISTING/home" "$EXISTING/projects/.codex"
printf 'preserved\n' >"$EXISTING/projects/.codex/auth.json"
EXISTING_SELECTED="$("$HOME_HELPER" "$ADMIN_USER" "$EXISTING/home" "$EXISTING/projects")"
[[ "$(<"$EXISTING_SELECTED/auth.json")" == "preserved" ]] || fail "existing persistent state changed"
[[ "$(readlink -f "$EXISTING/home/.codex")" == "$(readlink -f "$EXISTING_SELECTED")" ]] ||
  fail "existing persistent home symlink is wrong"

DOT="$TMP/home-dot-codex"
mkdir -p "$DOT/home" "$DOT/projects/.codex" "$DOT/projects/dot-codex/.git"
printf 'active\n' >"$DOT/projects/dot-codex/auth.json"
DOT_SELECTED="$("$HOME_HELPER" "$ADMIN_USER" "$DOT/home" "$DOT/projects")"
[[ "$DOT_SELECTED" == "$DOT/projects/dot-codex" ]] || fail "dot-codex was not preferred"
[[ "$(<"$DOT_SELECTED/auth.json")" == "active" ]] || fail "dot-codex state changed"

printf 'Remote-control managed workspace proof passed.\n'
