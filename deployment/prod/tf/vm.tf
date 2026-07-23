resource "azurerm_linux_virtual_machine" "this" {
  name                            = lower(join("-", [local.prefix, "vm"]))
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  size                            = local.vm.vm_size
  admin_username                  = local.vm.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.this.id]
  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml", {
    admin_username         = local.vm.admin_username
    workspace_mount_path   = local.vm.workspace_mount_path
    workspace_disk_lun     = local.vm.workspace_disk_lun
    codex_version          = local.provisioning.codex_version
    codex_package_url      = local.provisioning.codex_package_url
    codex_package_sha256   = local.provisioning.codex_package_sha256
    verified_fetch_script  = file("${path.module}/scripts/fetch-verified-artifact.sh")
    codex_installer_script = file("${path.module}/scripts/install-verified-codex.sh")
    codex_recovery_script  = file("${path.module}/scripts/ensure-codex-remote-control.sh")
  }))
  tags = local.custom_tags

  dynamic "admin_ssh_key" {
    for_each = local.vm.admin_ssh_public_keys

    content {
      username   = local.vm.admin_username
      public_key = admin_ssh_key.value
    }
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

}
