resource "azurerm_storage_account" "this" {
  name                            = lower(join("", [local.prefix_cut, "strgacc"]))
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  public_network_access_enabled   = true
  shared_access_key_enabled       = true
  allow_nested_items_to_be_public = false
  tags                            = local.custom_tags

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    ip_rules                   = []
    virtual_network_subnet_ids = [azurerm_subnet.this.id]
  }

  share_properties {
    retention_policy {
      days = 14
    }

    smb {
      versions             = ["SMB3.0", "SMB3.1.1"]
      authentication_types = ["NTLMv2", "Kerberos"]
    }
  }
}

resource "azapi_update_resource" "storage_smb_oauth" {
  type        = "Microsoft.Storage/storageAccounts@2025-06-01"
  resource_id = azurerm_storage_account.this.id

  body = {
    properties = {
      azureFilesIdentityBasedAuthentication = {
        directoryServiceOptions = "None"
        smbOAuthSettings = {
          isSmbOAuthEnabled = true
        }
      }
    }
  }
}

resource "azurerm_storage_share" "this" {
  name               = local.vm.file_share_name
  storage_account_id = azurerm_storage_account.this.id
  quota              = local.vm.file_share_quota_gb
  enabled_protocol   = "SMB"
}

resource "azurerm_user_assigned_identity" "storage" {
  name                = lower(join("-", [local.prefix, "storage-identity"]))
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.custom_tags
}

resource "azurerm_role_assignment" "vm_storage_smb" {
  scope                            = azurerm_storage_account.this.id
  role_definition_name             = "Storage File Data SMB MI Admin"
  principal_id                     = azurerm_user_assigned_identity.storage.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_management_lock" "storage" {
  name       = "protect-workspace-storage"
  scope      = azurerm_storage_account.this.id
  lock_level = "CanNotDelete"
  notes      = "Protects the persistent Codex workspace storage account from accidental deletion."
}
