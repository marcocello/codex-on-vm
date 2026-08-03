#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FEATURE_DIR="$ROOT/docs/features/self-hosted-openvpn-access"
TF_DIR="$ROOT/deployment/prod/tf"
CONSOLE="$ROOT/scripts/codex-vm.sh"

fail() {
  printf 'Self-hosted OpenVPN proof failed: %s\n' "$1" >&2
  exit 1
}

printf 'Terraform: %s\n' "$(terraform version | sed -n '1p')"
printf 'Bash: %s | %s\n' "$(command -v bash)" "$(bash --version | sed -n '1p')"
printf 'Python: %s | %s\n' "$(command -v python3)" "$(python3 --version 2>&1)"
printf 'OpenSSL: %s | %s\n' "$(command -v openssl)" "$(openssl version)"
printf 'Proof mode: production Terraform and console with fake provider, VPN SSH, SCP, systemd, and OpenVPN edges\n'

[[ -x "$CONSOLE" ]] || fail "production console is missing or not executable"
bash -n "$CONSOLE"
terraform -chdir="$TF_DIR" test -filter=tests/openvpn_access.tftest.hcl

STANDING_RULES="$(rg -n 'resource[[:space:]]+"azurerm_network_security_rule"' "$TF_DIR" --glob '*.tf' || true)"
[[ "$(printf '%s\n' "$STANDING_RULES" | rg -c 'resource[[:space:]]+"azurerm_network_security_rule"')" == "1" ]] ||
  fail "production Terraform must contain exactly one standalone NSG rule"
[[ "$STANDING_RULES" == *'resource "azurerm_network_security_rule" "openvpn"'* ]] ||
  fail "the only standing NSG rule is not the accepted OpenVPN rule"
if rg -n '^[[:space:]]*security_rule[[:space:]]*[{=]' "$TF_DIR" --glob '*.tf' >/dev/null; then
  fail "production Terraform contains an inline NSG rule outside the accepted OpenVPN resource"
fi
if rg -n 'destination_port_ranges?[[:space:]]*=[^#]*"22"' "$TF_DIR" --glob '*.tf' >/dev/null; then
  fail "production Terraform contains permanent TCP/22 ingress"
fi
if rg -n 'resource[[:space:]]+"azurerm_virtual_network_gateway"|resource[[:space:]]+"azurerm_bastion_host"|resource[[:space:]]+"azurerm_security_center_subscription_pricing"' \
  "$TF_DIR" --glob '*.tf' >/dev/null; then
  fail "a paid gateway, Bastion host, or Defender pricing resource entered the production root"
fi
if rg -n '^[[:space:]]*custom_data[[:space:]]*=' "$TF_DIR" --glob '*.tf' >/dev/null; then
  fail "OpenVPN provisioning must not use cloud-init"
fi
if rg -n 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|OpenVPN Static key' "$TF_DIR" "$FEATURE_DIR/FEATURE.md" "$FEATURE_DIR/PROOF.md" >/dev/null; then
  fail "private VPN material entered tracked configuration or contracts"
fi
if rg -n 'AllowTemporarySsh|temporary_ssh_rule_name|local_mount_path|^[[:space:]]*ssh_alias[[:space:]]*=' \
  "$TF_DIR" "$ROOT/README.md" "$ROOT/docs/ARCHITECTURE.md" "$ROOT/docs/OPERATIONS.md" \
  --glob '!**/tests/**' >/dev/null; then
  fail "legacy public SSH or SSHFS configuration remains in production configuration or documentation"
fi
for marker in ssh-open.sh ssh-close.sh workspace-open.sh workspace-close.sh; do
  if rg -F "__CODEX_VM_HELPER_BEGIN__ $marker" "$CONSOLE" >/dev/null; then
    fail "removed helper remains embedded: $marker"
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
EXTRACTED="$TMP/extracted"
CODEX_VM_TEST_MODE=1 "$CONSOLE" __extract-helpers "$EXTRACTED"
for helper in openvpn-setup.sh; do
  [[ -x "$EXTRACTED/scripts/$helper" ]] || fail "missing embedded Mac helper: $helper"
  bash -n "$EXTRACTED/scripts/$helper"
done
for removed in ssh-open.sh ssh-close.sh workspace-open.sh workspace-close.sh; do
  [[ ! -e "$EXTRACTED/scripts/$removed" ]] || fail "removed helper was materialized: $removed"
done
[[ -x "$EXTRACTED/vm-scripts/configure-codex-openvpn.sh" ]] ||
  fail "missing embedded OpenVPN VM configurator"
bash -n "$EXTRACTED/vm-scripts/configure-codex-openvpn.sh"

"$CONSOLE" --dry-run vpn-setup >"$TMP/vpn-setup-dry-run.txt"
rg -F 'embedded helper: openvpn-setup.sh' "$TMP/vpn-setup-dry-run.txt" >/dev/null ||
  fail "public vpn-setup command did not dispatch to the embedded helper"
"$CONSOLE" --dry-run vpn-setup --rotate >"$TMP/vpn-rotate-dry-run.txt"
rg -F 'embedded helper: openvpn-setup.sh --rotate' "$TMP/vpn-rotate-dry-run.txt" >/dev/null ||
  fail "public vpn-setup rotation did not preserve the explicit flag"
if "$CONSOLE" --dry-run vpn-setup --unexpected >"$TMP/vpn-invalid.txt" 2>&1; then
  fail "public vpn-setup accepted an unexpected argument"
fi
for removed in shell status ssh-open ssh-close workspace-open workspace-close; do
  if "$CONSOLE" --dry-run "$removed" >"$TMP/removed-$removed.txt" 2>&1; then
    fail "removed public command unexpectedly succeeded: $removed"
  fi
done

"$ROOT/docs/features/codex-vm-operator-console/proof/run.sh"

"$ROOT/docs/features/remote-control-managed-workspace/proof/prepare-machine-scenario.sh" "$EXTRACTED" "$TMP"

"$FEATURE_DIR/proof/openvpn-scenario.sh" "$EXTRACTED" "$TMP"

printf 'Self-hosted OpenVPN proof completed.\n'
