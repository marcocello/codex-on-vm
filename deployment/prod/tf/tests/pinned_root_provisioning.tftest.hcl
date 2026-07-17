mock_provider "azurerm" {}
mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        mac_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB5W3zliMg6KTJYc9jZJeJf/jMeTsYPbIcZ1OmVG6ngw mock-mac"
      }
    }
  }
}
mock_provider "local" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  owner           = "provisioning-proof"
}

run "pinned_root_provisioning_plan" {
  command = plan

  assert {
    condition     = azurerm_linux_virtual_machine.this.source_image_reference[0].offer == "ubuntu-24_04-lts" && azurerm_linux_virtual_machine.this.source_image_reference[0].sku == "server" && azurerm_linux_virtual_machine.this.source_image_reference[0].version == "24.04.202606060"
    error_message = "The VM image must use the reviewed stable Ubuntu 24.04 image available in Austria East instead of latest or a daily-build version."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "https://github.com/openai/codex/releases/download/rust-v0.144.3/codex-package-x86_64-unknown-linux-musl.tar.gz") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "1c3c1f1f636da56a197ce0b5084d44b86f58f0fb32983278fa55c2544d221af4")
    error_message = "Cloud-init must declare the exact Codex 0.144.3 package URL and SHA-256 digest."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "fetch-verified-artifact") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "sha256")
    error_message = "Cloud-init must use the repository-owned verified artifact boundary."
  }

  assert {
    condition     = !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "https://chatgpt.com/codex/install.sh") && !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "CODEX_RELEASE:-latest")
    error_message = "Cloud-init must not execute the mutable Codex installer."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "\"$ADMIN_HOME/.codex/packages/standalone/current/codex\"") && !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "/opt/codex")
    error_message = "The verified package must be published in the managed standalone path used by the azureadmin daemon."
  }

}
