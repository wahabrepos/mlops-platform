# BURST ENVIRONMENT — the expensive half. Up for hours, not weeks.
#
#   ~$0.22/hour while it exists.  ~$160/month if you forget it.
#
# The workflow this is designed for:
#
#   make azure-up      # ~8 minutes, cluster ready
#   ...record the demo, take the screenshots...
#   make azure-down    # ~5 minutes, everything billable is gone
#
# It has its own state file and its own resource group, so `terraform destroy`
# here cannot touch the registry or the data lake in envs/shared. That
# separation is the safety property: the destroy you will run most often is the
# one that cannot delete anything you care about.
#
# It reads envs/shared's outputs through a remote state data source rather than
# duplicating names, so the AcrPull grant always points at the real registry.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      # AKS creates a second, node-level resource group (MC_*) that Azure
      # normally refuses to delete while it holds resources. Without this,
      # `terraform destroy` can leave orphaned disks and load balancers behind
      # — which keep billing. This is the flag that makes destroy actually mean
      # destroy, and it is the single most budget-relevant line in this file.
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

# Read the shared environment's outputs. terraform_remote_state with a local
# backend just reads the other state file off disk — no server involved. If you
# later move shared state to Azure Storage, only this block changes.
data "terraform_remote_state" "shared" {
  backend = "local"

  config = {
    path = "${path.module}/../shared/terraform.tfstate"
  }
}

locals {
  tags = {
    project     = "mlops-platform"
    environment = "burst"
    lifecycle   = "ephemeral" # <- if you see this tag on a resource, it should not be old
    managed-by  = "terraform"
    owner       = var.owner
    # Stamped at apply time. When you find a cluster in the portal and wonder
    # how long it has been running, this tag answers it without opening logs.
    created = timestamp()
  }
}

module "rg" {
  source   = "../../modules/resource-group"
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

module "aks" {
  source              = "../../modules/aks"
  name                = var.cluster_name
  resource_group_name = module.rg.name
  location            = module.rg.location

  node_count         = var.node_count
  vm_size            = var.vm_size
  kubernetes_version = var.kubernetes_version

  # Wire in the shared registry and data lake so the cluster can pull images
  # and read data using its managed identity — no secrets anywhere.
  acr_id             = data.terraform_remote_state.shared.outputs.acr_id
  storage_account_id = data.terraform_remote_state.shared.outputs.storage_account_id

  tags = local.tags
}
