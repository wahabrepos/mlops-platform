variable "name" {
  description = "Globally unique ACR name: alphanumeric only, 5-50 chars."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.name))
    error_message = "ACR name must be 5-50 alphanumeric characters, no hyphens or underscores."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "sku" {
  description = "Basic is sufficient for this platform. See the cost note in main.tf."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be Basic, Standard, or Premium."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
