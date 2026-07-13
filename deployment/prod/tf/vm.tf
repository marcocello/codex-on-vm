resource "azurerm_linux_virtual_machine" "this" {
  name                            = lower(join("-", [local.prefix, "vm"]))
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  size                            = local.vm.vm_size
  admin_username                  = local.vm.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this.id]
  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml", {
    admin_username             = local.vm.admin_username
    workspace_mount_path       = local.vm.workspace_mount_path
    storage_account_name       = azurerm_storage_account.this.name
    storage_identity_client_id = azurerm_user_assigned_identity.storage.client_id
    file_share_name            = azurerm_storage_share.this.name
    codex_version              = local.provisioning.codex_version
    codex_package_url          = local.provisioning.codex_package_url
    codex_package_sha256       = local.provisioning.codex_package_sha256
    microsoft_repo_url         = local.provisioning.microsoft_repo_package_url
    microsoft_repo_sha256      = local.provisioning.microsoft_repo_package_sha256
    azfilesauth_version        = local.provisioning.azfilesauth_version
    verified_fetch_script      = file("${path.module}/scripts/fetch-verified-artifact.sh")
    codex_installer_script     = file("${path.module}/scripts/install-verified-codex.sh")
  }))
  tags = local.custom_tags

  dynamic "admin_ssh_key" {
    for_each = local.vm.admin_ssh_public_keys

    content {
      username   = local.vm.admin_username
      public_key = admin_ssh_key.value
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.storage.id]
  }

  os_disk {
    caching              = "ReadWrite"
    disk_size_gb         = local.vm.os_disk_size_gb
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = local.ubuntu_image.publisher
    offer     = local.ubuntu_image.offer
    sku       = local.ubuntu_image.sku
    version   = local.ubuntu_image.version
  }

  depends_on = [
    azapi_update_resource.storage_smb_oauth,
    azurerm_role_assignment.vm_storage_smb,
  ]
}
