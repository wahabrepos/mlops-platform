# Azure Data Lake Storage Gen2 = a Storage Account with a hierarchical
# namespace turned on. There is no separate "ADLS" product to buy; the one
# flag below is the whole difference.
#
# WHY THE FLAG MATTERS: without it, "folders" are a naming convention over a
# flat key space, so renaming a prefix means copying every blob under it. With
# it, directories are real, rename is an O(1) metadata operation, and POSIX-ish
# ACLs apply per directory. For a data lake where pipelines move partitions
# around constantly, that is the difference between seconds and hours.
#
# COST: LRS (locally redundant) at the Hot tier is roughly $0.02/GB/month in
# West Europe, so a few GB of demo data is cents. Transactions cost more than
# storage at this size. GRS doubles the price for cross-region durability that
# a portfolio project does not need.
resource "azurerm_storage_account" "this" {
  name                     = var.name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = var.replication
  account_kind             = "StorageV2"

  is_hns_enabled = true # <- this is what makes it ADLS Gen2

  # Refuse plaintext. Costs nothing, and "why is this here?" has a good answer:
  # it is the control an auditor looks for first.
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  # Public blob access is off. A data lake holding camera footage that is
  # anonymously readable is the single worst outcome this platform could have,
  # so it is disabled at the account level rather than per container.
  allow_nested_items_to_be_public = false

  blob_properties {
    # Soft delete is a cheap undo for the day a pipeline bug deletes a
    # partition. Seven days of retention on a few GB costs almost nothing.
    delete_retention_policy {
      days = 7
    }
    versioning_enabled = false # DVC provides content versioning; this would duplicate it
  }

  tags = var.tags
}

# Containers are the top-level namespace. These mirror the MinIO buckets the
# local stack creates, so the same code path works against either by changing
# an endpoint. Keeping the names identical is deliberate.
resource "azurerm_storage_container" "this" {
  for_each = toset(var.containers)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Lifecycle management: move anything untouched for 30 days to Cool, and delete
# raw data past its retention window. On a portfolio budget the saving is
# pennies — the reason it is here is that "what is your data retention policy?"
# is a governance question (Project 6) and this is the answer in code.
resource "azurerm_storage_management_policy" "this" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "cool-then-expire-raw"
    enabled = true

    filters {
      prefix_match = ["raw/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = 30
        delete_after_days_since_modification_greater_than       = var.raw_retention_days
      }
    }
  }
}
