resource "azurerm_recovery_services_vault" "workspace" {
  name                          = lower(join("-", [local.prefix, "recovery-vault"]))
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  sku                           = "Standard"
  storage_mode_type             = "LocallyRedundant"
  public_network_access_enabled = true
  tags                          = local.custom_tags
}

resource "azurerm_backup_container_storage_account" "workspace" {
  resource_group_name = azurerm_resource_group.this.name
  recovery_vault_name = azurerm_recovery_services_vault.workspace.name
  storage_account_id  = azurerm_storage_account.this.id
}

resource "azurerm_backup_policy_file_share" "workspace" {
  name                = lower(join("-", [local.prefix, "daily-30d"]))
  resource_group_name = azurerm_resource_group.this.name
  recovery_vault_name = azurerm_recovery_services_vault.workspace.name
  timezone            = "UTC"
  backup_tier         = "snapshot"

  backup {
    frequency = "Daily"
    time      = "02:00"
  }

  retention_daily {
    count = 30
  }
}

resource "azurerm_backup_protected_file_share" "workspace" {
  resource_group_name       = azurerm_resource_group.this.name
  recovery_vault_name       = azurerm_recovery_services_vault.workspace.name
  source_storage_account_id = azurerm_backup_container_storage_account.workspace.storage_account_id
  source_file_share_name    = azurerm_storage_share.this.name
  backup_policy_id          = azurerm_backup_policy_file_share.workspace.id

  depends_on = [azurerm_backup_container_storage_account.workspace]
}
