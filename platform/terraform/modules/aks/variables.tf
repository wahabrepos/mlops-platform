variable "name" {
  description = "Cluster name. Also used as the DNS prefix."
  type        = string
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "kubernetes_version" {
  description = "Pin it. Check what your region offers: az aks get-versions --location westeurope -o table"
  type        = string
  default     = "1.31"
}

variable "node_count" {
  description = "Fixed pool size. Every node is billed per hour it exists."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 2
    error_message = <<-EOT
      node_count is capped at 2 on purpose. The subscription has a hard quota of
      4 Total Regional vCPUs, and the default Standard_B2ms is 2 vCPU per node,
      so 3 nodes is 6 vCPU and Azure rejects the deployment with QuotaExceeded
      part-way through the create, leaving a resource group to clean up by hand.
      Raise the quota first (portal -> Subscriptions -> Usage + quotas), then
      raise this cap.
    EOT
  }
}

variable "vm_size" {
  description = <<-EOT
    Standard_B2ms = 2 vCPU / 8 GB, ~$0.096/hr in West Europe.
    B-series are burstable: they accumulate CPU credits while idle and spend
    them under load. That fits a demo cluster well and fits a steady
    high-CPU workload badly — know the difference before quoting it.
    Standard_B2s (4 GB) is cheaper but too small for KServe + Istio + Knative.
  EOT
  type        = string
  default     = "Standard_B2ms"
}

variable "acr_id" {
  description = "ACR resource id to grant AcrPull on. Empty string skips the role assignment."
  type        = string
  default     = ""
}

variable "storage_account_id" {
  description = "Storage account id to grant blob access on. Empty string skips it."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
