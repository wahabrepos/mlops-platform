output "resource_group_name" {
  value = module.rg.name
}

output "acr_login_server" {
  description = "Image prefix for docker push. Example: <this>/dataset-api:v1"
  value       = module.acr.login_server
}

output "acr_id" {
  description = "Feed this into envs/burst so AKS can pull without a password."
  value       = module.acr.id
}

output "storage_account_name" {
  value = module.storage.name
}

output "storage_account_id" {
  value = module.storage.id
}

output "dfs_endpoint" {
  value = module.storage.dfs_endpoint
}
