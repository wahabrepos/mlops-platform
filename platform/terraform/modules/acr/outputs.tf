output "id" {
  value = azurerm_container_registry.this.id
}

output "login_server" {
  description = "Use as the image prefix: <login_server>/dataset-api:<tag>"
  value       = azurerm_container_registry.this.login_server
}

output "name" {
  value = azurerm_container_registry.this.name
}
