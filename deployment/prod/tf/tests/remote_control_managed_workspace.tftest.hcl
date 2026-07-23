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
  owner           = "managed-workspace-proof"
}

run "remote_control_managed_workspace_plan" {
  command = plan

  assert {
    condition     = azurerm_managed_disk.workspace.storage_account_type == "StandardSSD_LRS" && azurerm_managed_disk.workspace.disk_size_gb == 256
    error_message = "The live Git workspace must use the separately managed 256 GiB Standard SSD disk."
  }

  assert {
    condition     = !azurerm_managed_disk.workspace.public_network_access_enabled && azurerm_managed_disk.workspace.network_access_policy == "DenyAll"
    error_message = "The managed disk must deny public network access."
  }

  assert {
    condition     = azurerm_virtual_machine_data_disk_attachment.workspace.lun == 0
    error_message = "The workspace managed disk must be attached to the VM at LUN 0."
  }

  assert {
    condition     = azurerm_management_lock.workspace_disk.lock_level == "CanNotDelete"
    error_message = "The workspace disk must have a CanNotDelete management lock."
  }

  assert {
    condition     = azurerm_managed_disk.workspace.name == "prod-codex-on-vm-workspace-disk"
    error_message = "The persistent disk must use a stable name independent of the VM resource."
  }

  assert {
    condition     = azurerm_backup_protected_vm.workspace.include_disk_luns == toset([0]) && azurerm_backup_policy_vm.workspace.retention_daily[0].count == 30
    error_message = "Daily VM backup must include workspace LUN 0 and retain 30 daily recovery points."
  }

  assert {
    condition     = output.connection.workspace_mount_path == "/home/azureadmin/projects" && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "/dev/disk/azure/data/by-lun/0") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "CREATED_PARTITION") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "wipefs --no-act") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "mkfs.ext4") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "UUID=") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "/home/azureadmin/projects")
    error_message = "Cloud-init must prepare the managed LUN as ext4 and persist the /home/azureadmin/projects mount by UUID."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "runuser -u \"$ADMIN_USER\"") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "app-server daemon bootstrap --remote-control") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "app-server daemon bootstrap\n") && !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "/root/.codex")
    error_message = "Cloud-init must bootstrap the managed daemon as the admin user, never root."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "CODEX_HOME=\"$ADMIN_CODEX_HOME\" \\\n        /usr/local/sbin/install-verified-codex") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "\"$ADMIN_HOME/.codex/packages/standalone/current/codex\"") && !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "/opt/codex")
    error_message = "Cloud-init must install and verify the managed standalone package under azureadmin's CODEX_HOME, where remote-control start resolves it."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "  - bubblewrap") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "  - apparmor-profiles") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "  - apparmor-utils") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "command -v bwrap") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "/usr/share/apparmor/extra-profiles/bwrap-userns-restrict") && length(regexall("(?s)install -m 0644 \"[$]BWRAP_PROFILE_SOURCE\" \"[$]BWRAP_PROFILE_TARGET\".*apparmor_parser -r \"[$]BWRAP_PROFILE_TARGET\".*app-server daemon bootstrap --remote-control", base64decode(azurerm_linux_virtual_machine.this.custom_data))) == 1
    error_message = "Cloud-init must install bubblewrap and load the Ubuntu 24.04 AppArmor profile before starting the Codex daemon."
  }

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "/usr/local/sbin/ensure-codex-remote-control") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "codex-remote-control-bootstrap.service") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "codex-remote-control-health.service") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "codex-remote-control-health.timer") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "After=network-online.target") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "User=azureadmin") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "OnUnitInactiveSec=1min") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "Persistent=true") && length(regexall("(?s)app-server daemon bootstrap --remote-control.*systemctl daemon-reload.*systemctl enable codex-remote-control-bootstrap[.]service codex-remote-control-health[.]timer.*systemctl start codex-remote-control-health[.]timer", base64decode(azurerm_linux_virtual_machine.this.custom_data))) == 1
    error_message = "Cloud-init must install reboot bootstrap and a one-minute managed-daemon health timer without creating another app-server owner."
  }

  assert {
    condition     = !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "azfilesauth") && !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "sec=krb5") && !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "mount.cifs")
    error_message = "The VM workspace must no longer depend on Azure Files or SMB authentication."
  }

  assert {
    condition     = output.connection.vm_name == "prod-codex-on-vm-vm"
    error_message = "The connection output must expose the VM name required by Azure Run Command recovery."
  }
}
