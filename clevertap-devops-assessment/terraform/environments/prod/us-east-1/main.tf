# =============================================================================
# prod / us-east-1 — Environment Root
# =============================================================================
# Instantiates VPC and EKS modules for production us-east-1.
# Equivalent file exists for ap-south-1 with different CIDR ranges.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  # Remote state: S3 backend with DynamoDB locking
  # State path: {account}/{region}/{component}.tfstate
  backend "s3" {
    bucket         = "clevertap-tfstate-prod"
    key            = "prod/us-east-1/eks.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "alias/clevertap-tfstate-kms"
    dynamodb_table = "clevertap-tfstate-locks"

    # Workspace isolation — each team/PR uses its own lock
    workspace_key_prefix = "workspaces"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  # Assume a deployment role — no long-lived credentials in CI/CD
  assume_role {
    role_arn     = "arn:aws:iam::${var.aws_account_id}:role/TerraformDeployRole"
    session_name = "terraform-prod-use1"
  }

  default_tags {
    tags = {
      Environment   = "prod"
      Region        = "us-east-1"
      ManagedBy     = "terraform"
      CostCenter    = "platform-engineering"
      BusinessUnit  = "clevertap-core"
    }
  }
}

# =============================================================================
# Data
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# VPC
# =============================================================================

module "vpc" {
  source = "../../../modules/vpc"

  environment  = "prod"
  region_short = "use1"
  cluster_name = local.cluster_name
  vpc_cidr     = "10.10.0.0/16"

  availability_zones   = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnet_cidrs  = ["10.10.0.0/24", "10.10.1.0/24", "10.10.2.0/24"]
  private_subnet_cidrs = ["10.10.10.0/23", "10.10.12.0/23", "10.10.14.0/23"]
  intra_subnet_cidrs   = ["10.10.100.0/24", "10.10.101.0/24", "10.10.102.0/24"]

  # Transit Gateway for inter-region connectivity (us-east-1 ↔ ap-south-1)
  transit_gateway_id    = var.transit_gateway_id
  tgw_destination_cidrs = ["10.20.0.0/16"] # ap-south-1 VPC CIDR

  create_flow_logs_bucket  = true
  flow_logs_retention_days = 365

  tags = local.common_tags
}

# =============================================================================
# EKS
# =============================================================================

module "eks" {
  source = "../../../modules/eks"

  cluster_name       = local.cluster_name
  environment        = "prod"
  kubernetes_version = "1.29"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  # Private-only API endpoint in production
  enable_public_endpoint = false

  # On-Demand: system components + critical services
  on_demand_instance_types = ["m5.xlarge", "m5a.xlarge", "m5n.xlarge"]
  on_demand_desired        = 6
  on_demand_min            = 3
  on_demand_max            = 20

  # Spot: app workloads; sized for 10–50x burst
  spot_instance_types = ["c5.2xlarge", "c5d.2xlarge", "c5n.2xlarge", "m5.2xlarge", "m5d.2xlarge"]
  spot_desired        = 10
  spot_min            = 5
  spot_max            = 100

  tags = local.common_tags
}

# =============================================================================
# Locals
# =============================================================================

locals {
  cluster_name = "clevertap-prod-use1"

  common_tags = {
    Environment  = "prod"
    Region       = "us-east-1"
    ManagedBy    = "terraform"
    CostCenter   = "platform-engineering"
    BusinessUnit = "clevertap-core"
    Cluster      = local.cluster_name
  }
}
