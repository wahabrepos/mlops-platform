output "name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "id" {
  value = azurerm_kubernetes_cluster.this.id
}

# The kubeconfig contains cluster credentials, so it is sensitive. In practice
# you will fetch it with `az aks get-credentials` rather than reading it out of
# Terraform — that keeps it out of your shell history and out of CI logs.
output "kube_config_raw" {
  value     = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive = true
}

output "node_resource_group" {
  description = "The MC_* group AKS creates for node VMs, disks and load balancers. Deleting the cluster deletes it."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}
