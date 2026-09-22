variable "subscription_id" {
  description = "Azure subscription GUID."
  type        = string
}

variable "owner" {
  type    = string
  default = "abdiwahab"
}

variable "location" {
  description = "Must match envs/shared, or every image pull and blob read crosses regions and is billed."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Separate from the shared group so destroy here is always safe."
  type        = string
  default     = "mlops-platform-burst-rg"
}

variable "cluster_name" {
  type    = string
  default = "mlops-burst"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "vm_size" {
  description = "Standard_B2ms: 2 vCPU / 8 GB. Two of them fit KServe + Istio + Knative + a model."
  type        = string
  default     = "Standard_B2ms"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}
