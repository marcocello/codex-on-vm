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
    workspace_disk_lun          = local.vm.workspace_disk_lun
    workspace_mount_path        = local.vm.workspace_mount_path
    local_mount_path            = pathexpand(local.vm.local_workspace_mount_path)
    mac_private_key_path        = local.vm.mac_private_key_path
    ssh_host_config_path        = pathexpand(local.vm.local_ssh_host_config_path)
    ssh_known_hosts_path        = local.vm.local_ssh_known_hosts_path
    codex_version               = local.provisioning.codex_version
    codex_package_url           = local.provisioning.codex_package_url
    codex_package_sha256        = local.provisioning.codex_package_sha256
  }
}

output "next_steps" {
  description = "Brief connection instructions shown after Terraform apply."
  value       = <<-EOT
    1. Set up or repair Codex with: scripts/codex-vm.sh setup
    2. Authenticate, start Remote Control, and print a pairing code with: scripts/codex-vm.sh pair
    3. Optionally clone or update dot-codex from GitHub with: scripts/codex-vm.sh dot-codex

    Run scripts/codex-vm.sh with no arguments for every interactive operator workflow.
    If preparation is required, interactive workflows ask before running setup; non-interactive commands stop with an explicit setup instruction.
    Terraform creates infrastructure only. The local console launches all one-time VM preparation and authentication.
    The base NSG has no inbound SSH allow rule. Repositories and Codex state persist on the managed disk at ${local.vm.workspace_mount_path}.
    If Codex or Remote Control is unavailable, rerun without SSH from the repository root: scripts/codex-vm.sh setup
  EOT
}
