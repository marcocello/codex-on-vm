resource "azurerm_virtual_machine_run_command" "ssh_host_key" {
  name               = "capture-ssh-host-key"
  location           = azurerm_linux_virtual_machine.this.location
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  tags               = local.custom_tags

  source {
    script = <<-SCRIPT
      set -eu
      awk 'NF >= 2 && $1 == "ssh-ed25519" { print $1 " " $2; found = 1; exit } END { if (!found) exit 1 }' /etc/ssh/ssh_host_ed25519_key.pub
    SCRIPT
  }
}

locals {
  ssh_host_public_key = regex(
    "ssh-ed25519 [A-Za-z0-9+/=]+",
    azurerm_virtual_machine_run_command.ssh_host_key.instance_view[0].output,
  )
}

resource "local_file" "ssh_known_hosts" {
  filename             = local.vm.local_ssh_known_hosts_path
  file_permission      = "0600"
  directory_permission = "0700"
  content              = "${azurerm_public_ip.this.fqdn} ${local.ssh_host_public_key}\n"
}

resource "local_file" "ssh_host" {
  filename             = pathexpand(local.vm.local_ssh_host_config_path)
  file_permission      = "0600"
  directory_permission = "0700"
  content              = <<-EOT
    Host ${local.vm.ssh_host_alias}
      HostName ${azurerm_public_ip.this.fqdn}
      User ${local.vm.admin_username}
      IdentityFile ${local.vm.mac_private_key_path}
      IdentitiesOnly yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${local.vm.local_ssh_known_hosts_path}
  EOT

  depends_on = [local_file.ssh_known_hosts]
}
