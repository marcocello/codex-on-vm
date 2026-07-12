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
