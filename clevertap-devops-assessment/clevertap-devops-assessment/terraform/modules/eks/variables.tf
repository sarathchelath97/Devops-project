# =============================================================================
# EKS Module – Variables
# =============================================================================

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster and managed node groups"
  type        = string
  default     = "1.29"
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EKS control plane ENIs and node groups"
  type        = list(string)
}

# =============================================================================
# Endpoint Access
# =============================================================================

variable "enable_public_endpoint" {
  description = "Enable public EKS API endpoint. Should be false in production; use kubectl via VPN or bastion."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (if enabled). Restrict to VPN/office CIDRs."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# =============================================================================
# Node Groups — On-Demand
# =============================================================================

variable "on_demand_instance_types" {
  description = "Instance types for the on-demand node group. Using similar sizes improves Cluster Autoscaler bin-packing."
  type        = list(string)
  default     = ["m5.xlarge", "m5a.xlarge", "m5n.xlarge"]
}

variable "on_demand_desired" {
  description = "Desired number of on-demand nodes"
  type        = number
  default     = 3
}

variable "on_demand_min" {
  description = "Minimum number of on-demand nodes (should be >= 2 for HA)"
  type        = number
  default     = 2
}

variable "on_demand_max" {
  description = "Maximum number of on-demand nodes"
  type        = number
  default     = 10
}

# =============================================================================
# Node Groups — Spot
# =============================================================================

variable "spot_instance_types" {
  description = <<-EOT
    Instance types for the Spot node group. Diversify across families to reduce
    correlated interruption risk. Mix c5/c5d/c5n (compute-optimized) and m5/m5d/m5n
    (general) of similar memory-to-CPU ratios for predictable bin-packing.
  EOT
  type        = list(string)
  default     = ["c5.2xlarge", "c5d.2xlarge", "c5n.2xlarge", "m5.2xlarge", "m5d.2xlarge", "m5n.2xlarge"]
}

variable "spot_desired" {
  description = "Desired number of Spot nodes"
  type        = number
  default     = 5
}

variable "spot_min" {
  description = "Minimum Spot nodes. Set to 0 for cost-sensitive dev, >= 2 for staging/prod."
  type        = number
  default     = 2
}

variable "spot_max" {
  description = "Maximum Spot nodes (supports 10-50x burst for campaign spikes)"
  type        = number
  default     = 50
}

# =============================================================================
# Node Configuration
# =============================================================================

variable "node_disk_size_gb" {
  description = "Root EBS volume size in GB for worker nodes"
  type        = number
  default     = 100
}

# =============================================================================
# Node Groups — On-Demand (Application SLA tier)
# =============================================================================

variable "on_demand_app_instance_types" {
  description = "Instance types for the SLA application node group (no Spot risk)"
  type        = list(string)
  default     = ["m5.2xlarge", "m5a.2xlarge"]
}

variable "on_demand_app_desired" {
  type    = number
  default = 4
}

variable "on_demand_app_min" {
  type    = number
  default = 2
}

variable "on_demand_app_max" {
  type    = number
  default = 30
}

# =============================================================================
# Add-on version control
# =============================================================================

variable "addon_most_recent" {
  description = <<-EOT
    If true, always resolves the latest compatible add-on version.
    Set false in production and pin explicit versions via addon_versions map
    to control upgrades through the PR review process.
  EOT
  type    = bool
  default = false
}

variable "addon_versions" {
  description = <<-EOT
    Explicit add-on version overrides. Only used when addon_most_recent = false.
    Example: { vpc_cni = "v1.16.0-eksbuild.1", coredns = "v1.10.1-eksbuild.7" }
  EOT
  type    = map(string)
  default = {}
}



# =============================================================================
# Tagging
# =============================================================================

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
