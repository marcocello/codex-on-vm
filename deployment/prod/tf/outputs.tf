output "connection" {
  description = "Non-sensitive values used by the SSH and temporary SMB connection workflows."
  value = {
    subscription_id      = var.subscription_id
    resource_group_name  = azurerm_resource_group.this.name
    storage_account_name = azurerm_storage_account.this.name
    file_share_name      = azurerm_storage_share.this.name
    local_mount_path     = pathexpand(local.vm.local_workspace_mount_path)
    ssh_alias            = local.vm.ssh_host_alias
    ssh_fqdn             = azurerm_public_ip.this.fqdn
  }
}

output "next_steps" {
  description = "Brief connection instructions shown after Terraform apply."
  value       = <<-EOT
    MAC
    1. Run: ssh ${local.vm.ssh_host_alias}
    2. On the VM run once: codex login --device-auth
    3. In the Codex/ChatGPT desktop app open Settings > Connections, enable ${local.vm.ssh_host_alias}, and select ${local.vm.workspace_mount_path}.

    MOBILE
    1. In the Mac app select Set up Remote.
    2. Open Remote in ChatGPT mobile and scan the QR code using the same account and workspace.
    3. Select the paired Mac and the ${local.vm.workspace_mount_path} remote project.

    Keep the Mac awake, online, and running the app. Do not paste the SSH private key into ChatGPT mobile.
  EOT
}
