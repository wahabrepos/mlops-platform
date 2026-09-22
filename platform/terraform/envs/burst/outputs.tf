output "cluster_name" {
  value = module.aks.name
}

output "resource_group_name" {
  value = module.rg.name
}

output "acr_login_server" {
  value = data.terraform_remote_state.shared.outputs.acr_login_server
}

# The command to run next. Printing it as an output saves looking it up, and
# makes the "what do I do now?" step of the demo script one copy-paste.
output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${module.rg.name} --name ${module.aks.name} --overwrite-existing"
}

output "estimated_hourly_cost_usd" {
  description = "Rough, for awareness. Verify against the portal's Cost Analysis blade."
  value       = format("%.3f", var.node_count * 0.096 + 0.025 + 0.004)
}

# A blunt, deliberate reminder in the apply output.
output "REMINDER" {
  value = "This environment bills by the hour. Run `make azure-down` when you are finished."
}
