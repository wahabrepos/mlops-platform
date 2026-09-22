# A resource group is a management and billing boundary, not a runtime thing.
# Everything inside it is deleted when it is deleted — which is exactly the
# property the burst environment relies on to guarantee nothing is left running.
resource "azurerm_resource_group" "this" {
  name     = var.name
  location = var.location
  tags     = var.tags
}
