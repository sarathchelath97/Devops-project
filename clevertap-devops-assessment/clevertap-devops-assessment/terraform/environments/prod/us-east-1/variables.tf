variable "aws_account_id" {
  description = "AWS account ID for the production environment"
  type        = string
}

variable "transit_gateway_id" {
  description = "AWS Transit Gateway ID for inter-region peering"
  type        = string
  default     = null
}
