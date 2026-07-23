output "connection" {
  description = "Non-sensitive values used by the temporary SSH and SSHFS workspace workflows."
  value = {
    subscription_id             = var.subscription_id
    resource_group_name         = azurerm_resource_group.this.name
    network_security_group_name = azurerm_network_security_group.this.name
    ssh_alias                   = local.vm.ssh_host_alias
    ssh_fqdn                    = azurerm_public_ip.this.fqdn
    ssh_username                = local.vm.admin_username
    temporary_ssh_rule_name     = local.vm.temporary_ssh_rule_name
    vm_name                     = azurerm_linux_virtual_machine.this.name
    workspace_disk_name         = azurerm_managed_disk.workspace.name
    workspace_mount_path        = local.vm.workspace_mount_path
    local_mount_path            = pathexpand(local.vm.local_workspace_mount_path)
  }
}

output "next_steps" {
  description = "Brief connection instructions shown after Terraform apply."
  value       = <<-EOT
    1. From the repository root run: scripts/ssh-open.sh
    2. Connect with: ssh ${local.vm.ssh_host_alias}
    3. On the VM run: codex login --device-auth
    4. Then run: codex remote-control start
    5. Generate a short-lived code with: codex remote-control pair
    6. Pair the other device using the same ChatGPT account, then exit SSH.
    7. Close TCP/22 with: scripts/ssh-close.sh

    The base NSG has no inbound SSH allow rule. Repositories persist on the managed disk at ${local.vm.workspace_mount_path}.
    If Remote Control is unavailable, recover it without SSH from the repository root: scripts/remote-control-recover.sh
  EOT
}
