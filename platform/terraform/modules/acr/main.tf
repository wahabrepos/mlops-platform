# Azure Container Registry.
#
# COST: Basic is ~$0.167/day (~$5/month) and includes 10 GB of storage. It is
# the only always-on Azure resource in this platform, and it is worth the money
# because every other project pushes images to it. Standard and Premium add
# throughput, geo-replication and private endpoints that a portfolio does not
# need — but know what they add, because "why Basic?" is a fair question.
#
# The registry name becomes <name>.azurecr.io, a public DNS record, so it must
# be globally unique across all of Azure: alphanumeric only, 5-50 characters.
# A collision surfaces at apply time, not at plan time.
resource "azurerm_container_registry" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  # Admin user is a shared username/password pair on the registry. It is the
  # easy path and the wrong one: it cannot be scoped, rotated per-consumer, or
  # attributed to a person. AKS pulls with a managed identity instead — see the
  # AcrPull role assignment in the aks module.
  admin_enabled = false

  tags = var.tags
}
