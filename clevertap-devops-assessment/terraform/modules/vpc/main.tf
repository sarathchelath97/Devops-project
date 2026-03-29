# =============================================================================
# Multi-Region VPC Module
# =============================================================================
# Supports identical instantiation across AWS regions.
# Creates public, private, and intra (database) subnet tiers.
# Enables VPC Flow Logs shipped to S3 with lifecycle policies.
# Supports AWS Transit Gateway attachment for inter-region connectivity.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  # Derive AZ-indexed subnet names for consistent tagging
  public_subnet_tags = merge(var.tags, {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}"  = "shared"
    Tier                                         = "public"
  })

  private_subnet_tags = merge(var.tags, {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    Tier                                        = "private"
  })

  intra_subnet_tags = merge(var.tags, {
    Tier = "intra"
  })

  name_prefix = "${var.environment}-${var.region_short}"
}

# =============================================================================
# VPC
# =============================================================================

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

# =============================================================================
# Internet Gateway (public tier)
# =============================================================================

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# =============================================================================
# Subnets — Public
# =============================================================================

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false # Explicit; avoid accidental public IPs

  tags = merge(local.public_subnet_tags, {
    Name = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
  })
}

# =============================================================================
# Subnets — Private (EKS worker nodes, app workloads)
# =============================================================================

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.private_subnet_tags, {
    Name = "${local.name_prefix}-private-${var.availability_zones[count.index]}"
  })
}

# =============================================================================
# Subnets — Intra (RDS, ElastiCache — no route to internet)
# =============================================================================

resource "aws_subnet" "intra" {
  count = length(var.intra_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.intra_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.intra_subnet_tags, {
    Name = "${local.name_prefix}-intra-${var.availability_zones[count.index]}"
  })
}

# =============================================================================
# NAT Gateways (one per AZ for HA)
# =============================================================================

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? length(var.public_subnet_cidrs) : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-nat-eip-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? length(var.public_subnet_cidrs) : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-nat-${count.index}"
  })

  depends_on = [aws_internet_gateway.this]
}

# =============================================================================
# Route Tables
# =============================================================================

# Public route table — default route to IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rt-public"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables — one per AZ, each routes through its local NAT GW
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.this.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[count.index].id
    }
  }

  # Transit Gateway route for inter-region traffic (if TGW attached)
  dynamic "route" {
    for_each = var.transit_gateway_id != null ? var.tgw_destination_cidrs : []
    content {
      cidr_block         = route.value
      transit_gateway_id = var.transit_gateway_id
    }
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rt-private-${count.index}"
  })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Intra route table — no internet route (isolated)
resource "aws_route_table" "intra" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rt-intra"
  })
}

resource "aws_route_table_association" "intra" {
  count          = length(aws_subnet.intra)
  subnet_id      = aws_subnet.intra[count.index].id
  route_table_id = aws_route_table.intra.id
}

# =============================================================================
# Transit Gateway Attachment (preferred over VPC Peering for multi-region mesh)
# See docs/assessment-written.md §1b for justification.
# =============================================================================

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.transit_gateway_id != null ? 1 : 0

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.private[*].id

  dns_support                                     = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-tgw-attachment"
  })
}

# =============================================================================
# VPC Flow Logs → S3
# =============================================================================

resource "aws_s3_bucket" "flow_logs" {
  count  = var.create_flow_logs_bucket ? 1 : 0
  bucket = "${local.name_prefix}-vpc-flow-logs-${data.aws_caller_identity.current.account_id}"

  tags = merge(var.tags, {
    Name    = "${local.name_prefix}-flow-logs"
    Purpose = "vpc-flow-logs"
  })
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  count  = var.create_flow_logs_bucket ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  count  = var.create_flow_logs_bucket ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  count  = var.create_flow_logs_bucket ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  count  = var.create_flow_logs_bucket ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    id     = "flow-logs-lifecycle"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.flow_logs_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "flow_logs" {
  count  = var.create_flow_logs_bucket ? 1 : 0
  bucket = aws_s3_bucket.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_bucket[0].json
}

data "aws_iam_policy_document" "flow_logs_bucket" {
  count = var.create_flow_logs_bucket ? 1 : 0

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.flow_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.flow_logs[0].arn]
  }

  statement {
    sid    = "DenyNonSSL"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [
      aws_s3_bucket.flow_logs[0].arn,
      "${aws_s3_bucket.flow_logs[0].arn}/*"
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_flow_log" "this" {
  log_destination_type = "s3"
  log_destination      = var.create_flow_logs_bucket ? aws_s3_bucket.flow_logs[0].arn : var.flow_logs_bucket_arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.this.id

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-flow-log"
  })
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}
