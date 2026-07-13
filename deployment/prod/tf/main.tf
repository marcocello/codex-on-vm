variable "subscription_id" {
  description = "Azure subscription used by the provider. Supply it through ignored terraform.tfvars."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "owner" {
  description = "Operator or team identifier used in Azure resource tags."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

data "azurerm_subscription" "this" {
}

data "azurerm_client_config" "this" {
}

data "azuread_client_config" "this" {
}

locals {
  prefix           = join("-", compact([local.input.stage, local.input.project, local.input.component]))
  prefix_condensed = join("", compact([local.input.stage, local.input.project, local.input.component]))
  prefix_cut       = join("", compact([substr(local.input.stage, 0, 3), substr(local.input.project, 0, 3), substr(local.input.component, 0, 3)]))
  prefix_dns       = local.input.stage == "prod" ? join(".", ["api"]) : join(".", [local.input.stage, "api"])
  custom_tags      = local.input
}

locals {
  input = {
    stage     = "prod"
    project   = "codex-on-vm"
    component = ""
    service   = ""
    cloud     = "azure"
    location  = "Austria East"
    managedBy = "terraform"
    owner     = var.owner
  }
}

locals {
  network = {
    address_space = "10.80.0.0/16"
    subnet_prefix = "10.80.1.0/24"
  }
}

locals {
  ssh_key_paths = {
    mac_private    = pathexpand("~/.ssh/codex-on-vm-mac")
    mobile_private = pathexpand("~/.ssh/codex-on-vm-mobile.pkcs8.pem")
  }
}

data "external" "ssh_keys" {
  program = ["bash", "${path.module}/scripts/ensure-ssh-keys.sh"]

  query = {
    mac_private_key_path    = local.ssh_key_paths.mac_private
    mobile_private_key_path = local.ssh_key_paths.mobile_private
  }
}

locals {
  vm = {
    vm_size                    = "Standard_B2als_v2"
    admin_username             = "azureadmin"
    admin_ssh_public_keys      = toset([data.external.ssh_keys.result.mac_public_key, data.external.ssh_keys.result.mobile_public_key])
    os_disk_size_gb            = 64
    file_share_quota_gb        = 64
    file_share_name            = "workspace"
    workspace_mount_path       = "/workspace"
    local_workspace_mount_path = "~/Volumes/codex-on-vm"
    ssh_host_alias             = "codex-on-vm"
    mac_private_key_path       = local.ssh_key_paths.mac_private
    local_ssh_host_config_path = "~/.ssh/config.d/codex-on-vm.conf"
    local_ssh_known_hosts_path = pathexpand("~/.ssh/codex-on-vm-known_hosts")
  }

  ubuntu_image = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "24.04.202606060"
  }

  provisioning = {
    codex_version                 = "0.144.3"
    codex_package_url             = "https://github.com/openai/codex/releases/download/rust-v0.144.3/codex-package-x86_64-unknown-linux-musl.tar.gz"
    codex_package_sha256          = "1c3c1f1f636da56a197ce0b5084d44b86f58f0fb32983278fa55c2544d221af4"
    microsoft_repo_package_url    = "https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb"
    microsoft_repo_package_sha256 = "c13f01ac7c3001b51a9281d40dde666db5e037e05512840c319832f7852bfec4"
    azfilesauth_version           = "1.0-11"
  }
}
