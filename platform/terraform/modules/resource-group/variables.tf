variable "name" {
  description = "Resource group name."
  type        = string
}

variable "location" {
  description = "Azure region. Keep every resource in one region: cross-region traffic is billed, same-region traffic inside a VNet is not."
  type        = string
}

variable "tags" {
  description = "Tags applied to the group."
  type        = map(string)
  default     = {}
}
