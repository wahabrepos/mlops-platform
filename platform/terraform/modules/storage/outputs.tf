output "id" {
  value = azurerm_storage_account.this.id
}

output "name" {
  value = azurerm_storage_account.this.name
}

output "dfs_endpoint" {
  description = "The ADLS Gen2 (Data Lake) endpoint. abfss:// URIs are built from this."
  value       = azurerm_storage_account.this.primary_dfs_endpoint
}

output "blob_endpoint" {
  description = "The blob endpoint. Tools speaking the S3/blob API use this one."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

# Marked sensitive so Terraform redacts it in plan/apply output and in CI logs.
# It still lands in state in plaintext — which is the reason state belongs in a
# remote backend with access control, not in git.
output "primary_access_key" {
  value     = azurerm_storage_account.this.primary_access_key
  sensitive = true
}
