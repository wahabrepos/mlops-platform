# SHARED ENVIRONMENT — the cheap half of the platform, left running.
#
# Contains: resource group, container registry, data lake, budget alarm.
# Costs:    ~$5/month, essentially all of it the ACR Basic tier.
#
# Apply this once and leave it. Everything expensive lives in envs/burst,
# which you create and destroy per demo session. That split is the single
# most important decision in this repo for a $100 credit: it means the
# question "am I burning money right now?" always has the same answer
# ("about 17 cents a day") unless you have deliberately started a burst.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pessimistic constraint: accept 4.x updates, never 5.x. Providers follow
      # semver and a major bump is allowed to break your config. Without this,
      # a `terraform init` six months from now can break a config you never
      # touched.
      version = "~> 4.0"
    }
  }

  # LOCAL STATE, deliberately.
  #
  # Remote state (an Azure Storage backend with a lease-based lock) is the
  # correct answer for a team, and you should say so. It is not used here
  # because the backend storage account would have to exist before the config
  # that creates storage accounts can run — a bootstrapping problem whose usual
  # solution is a second tiny Terraform config or a shell script. That is real
  # work for zero benefit on a single-operator project.
  #
  # What this costs you: no locking (irrelevant with one operator), and state
  # lives on one machine (so back it up — see the Makefile's `tf-backup`).
  # docs/AZURE-BUDGET.md has the migration to a remote backend when you want it.
}

provider "azurerm" {
  # Required even when empty: it is where provider-wide behaviours are toggled,
  # such as whether deleting a resource group also purges soft-deleted vaults.
  features {}

  subscription_id = var.subscription_id
}

locals {
  # One tag set, applied everywhere. `env` and `cost-center` are what make the
  # Cost Analysis blade in the portal able to answer "what is this project
  # costing me?" — untagged resources are invisible to that question.
  tags = {
    project     = "mlops-platform"
    environment = "shared"
    lifecycle   = "persistent"
    managed-by  = "terraform"
    owner       = var.owner
  }
}

module "rg" {
  source   = "../../modules/resource-group"
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

module "acr" {
  source              = "../../modules/acr"
  name                = var.acr_name
  resource_group_name = module.rg.name
  location            = module.rg.location
  sku                 = "Basic"
  tags                = local.tags
}

module "storage" {
  source              = "../../modules/storage"
  name                = var.storage_account_name
  resource_group_name = module.rg.name
  location            = module.rg.location
  replication         = "LRS"
  tags                = local.tags
}

# THE BUDGET ALARM — the most important resource in this file.
#
# It does not stop spending; nothing in Azure does that automatically without
# extra automation. What it does is email you when you cross a threshold, so a
# cluster you forgot to destroy is a $12 mistake instead of a $100 one.
#
# The 80% "Forecasted" notification is the useful one: it fires based on
# projected month-end spend, so it warns you while there is still time to act,
# not after the money is gone.
resource "azurerm_consumption_budget_subscription" "guard" {
  name            = "mlops-platform-guard"
  subscription_id = "/subscriptions/${var.subscription_id}"

  amount     = var.monthly_budget
  time_grain = "Monthly"

  time_period {
    # Must be the first of a month, and not in the past.
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
}
