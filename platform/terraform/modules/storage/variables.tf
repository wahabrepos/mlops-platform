variable "name" {
  description = "Globally unique storage account name: 3-24 chars, lowercase letters and digits only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "Storage account name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "replication" {
  description = "LRS keeps three copies in one datacenter. Enough for a portfolio; GRS doubles the bill."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS"], var.replication)
    error_message = "replication must be LRS, ZRS, or GRS."
  }
}

variable "containers" {
  description = "Top-level containers. Mirrors the MinIO buckets in the local stack."
  type        = list(string)
  default     = ["raw", "curated", "annotations", "mlflow", "dvc"]
}

variable "raw_retention_days" {
  description = "Days before raw blobs are deleted by the lifecycle policy."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
