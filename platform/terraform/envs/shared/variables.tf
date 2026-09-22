variable "subscription_id" {
  description = "Azure subscription GUID. Find it with: az account show --query id -o tsv"
  type        = string
}

variable "owner" {
  description = "Tag value identifying who owns these resources."
  type        = string
  default     = "abdiwahab"
}

variable "location" {
  description = "Azure region. West Europe is the closest low-latency region to Poland with full AKS feature availability."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  type    = string
  default = "mlops-platform-shared-rg"
}

variable "acr_name" {
  description = "Globally unique. Alphanumeric only."
  type        = string
}

variable "storage_account_name" {
  description = "Globally unique. 3-24 lowercase alphanumeric characters."
  type        = string
}

variable "monthly_budget" {
  description = "Budget alarm threshold in your billing currency. Set below your remaining credit, not equal to it."
  type        = number
  default     = 30
}

variable "budget_start_date" {
  description = "First day of a month, RFC3339. Must not be in the past when first applied."
  type        = string
  default     = "2026-09-01T00:00:00Z"
}

variable "alert_email" {
  description = "Where budget notifications go."
  type        = string
}
