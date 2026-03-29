# =============================================================================
# VPC Module – Variables
# =============================================================================

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "region_short" {
  description = "Short region identifier for resource naming (e.g., use1, aps1, euw1)"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used for subnet tagging required by AWS Load Balancer Controller"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must not overlap with other VPCs in the TGW mesh."
  type        = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of availability zones. Must match length of subnet CIDR lists."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). Used for NAT GWs and public ALBs."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ). EKS worker nodes run here."
  type        = list(string)
}

variable "intra_subnet_cidrs" {
  description = "CIDR blocks for intra subnets (one per AZ). RDS/ElastiCache — no internet route."
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Create a NAT Gateway per AZ for private subnet egress. Disable only for cost testing in dev."
  type        = bool
  default     = true
}

# =============================================================================
# Transit Gateway
# =============================================================================

variable "transit_gateway_id" {
  description = "AWS Transit Gateway ID to attach this VPC to. Set null to skip TGW attachment."
  type        = string
  default     = null
}

variable "tgw_destination_cidrs" {
  description = "List of CIDRs reachable via the Transit Gateway (e.g., other region VPC CIDRs)."
  type        = list(string)
  default     = []
}

# =============================================================================
# Flow Logs
# =============================================================================

variable "create_flow_logs_bucket" {
  description = "If true, creates a dedicated S3 bucket for flow logs. Set false to reuse an existing bucket."
  type        = bool
  default     = true
}

variable "flow_logs_bucket_arn" {
  description = "ARN of an existing S3 bucket to ship flow logs to. Only used when create_flow_logs_bucket=false."
  type        = string
  default     = null
}

variable "flow_logs_retention_days" {
  description = "Days before flow log objects are expired from S3."
  type        = number
  default     = 365
}

# =============================================================================
# Tagging
# =============================================================================

variable "tags" {
  description = "Map of tags applied to all resources. Merged with resource-specific tags."
  type        = map(string)
  default     = {}
}
