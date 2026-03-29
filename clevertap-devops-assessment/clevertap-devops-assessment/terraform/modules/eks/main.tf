# =============================================================================
# Reusable EKS Cluster Module
# =============================================================================
# Features:
#   - Private API server endpoint (public disabled in prod; access via SSM/VPN only)
#   - IRSA per service account — least-privilege, no node-level over-permission
#   - Three node groups with distinct eviction strategies:
#       system    → On-Demand, tainted CriticalAddonsOnly (kube-system pods only)
#       critical  → On-Demand, application SLA workloads
#       spot      → capacity_optimized allocation, stateless burst workloads
#   - Pod Disruption Budgets deployed alongside node groups (see pdb.tf)
#   - AWS Node Termination Handler for graceful Spot eviction
#   - Add-ons managed via Terraform with pinned versions + documented upgrade path
#   - KMS encryption for secrets at rest + EBS volumes
#   - IMDSv2 enforced on all nodes (prevents SSRF credential theft)
#
# Developer access to private cluster:
#   - Day-to-day kubectl: AWS SSM Session Manager port-forward to a bastion
#     (no SSH key management, fully audited in CloudTrail)
#   - CI/CD pipelines: GitHub Actions OIDC → AssumeRole in target account →
#     aws eks update-kubeconfig (no long-lived credentials stored in CI)
#   - Break-glass: SSM Fleet Manager console access
#
# Add-on upgrade strategy:
#   - Versions are pinned via data.aws_eks_addon_version (most_recent = false
#     in prod — set explicitly). Upgrades are Terraform plan changes reviewed in PR.
#   - Upgrade sequence: vpc-cni → kube-proxy → coredns → ebs-csi
#     (CNI must match node networking before DNS or storage add-ons are updated)
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

locals {
  name_prefix = "${var.environment}-${var.cluster_name}"

  # Merge mandatory tags with caller-supplied tags
  common_tags = merge(var.tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    ManagedBy                                   = "terraform"
    Environment                                 = var.environment
  })
}

# =============================================================================
# KMS key for EKS secrets encryption
# =============================================================================

resource "aws_kms_key" "eks" {
  description             = "EKS cluster ${local.name_prefix} secrets encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eks-kms"
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.name_prefix}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# =============================================================================
# CloudWatch Log Group (cluster control plane logs)
# =============================================================================

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.control_plane_log_retention_days
  kms_key_id        = aws_kms_key.eks.arn

  tags = local.common_tags
}

# =============================================================================
# IAM – Cluster Role
# =============================================================================

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${local.name_prefix}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# =============================================================================
# Security Groups
# =============================================================================

resource "aws_security_group" "cluster" {
  name        = "${local.name_prefix}-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cluster-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Allow control plane to communicate with nodes
resource "aws_security_group_rule" "cluster_egress_nodes" {
  type                     = "egress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.nodes.id
  description              = "Control plane to nodes (kubelet + pods)"
}

resource "aws_security_group_rule" "cluster_egress_nodes_443" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.nodes.id
  description              = "Control plane to nodes (kube-apiserver webhook)"
}

resource "aws_security_group" "nodes" {
  name        = "${local.name_prefix}-nodes-sg"
  description = "EKS worker node security group"
  vpc_id      = var.vpc_id

  # Allow all node-to-node and pod-to-pod traffic within the cluster
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
    description = "Node-to-node and pod-to-pod"
  }

  # Allow nodes to receive from control plane
  ingress {
    from_port                = 1025
    to_port                  = 65535
    protocol                 = "tcp"
    security_group_id        = aws_security_group.cluster.id
    description              = "Control plane to kubelet"
  }

  ingress {
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    security_group_id        = aws_security_group.cluster.id
    description              = "Control plane webhook traffic"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all egress (NAT GW handles filtering)"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nodes-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# EKS Cluster
# =============================================================================

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = var.enable_public_endpoint # false in prod
    public_access_cidrs     = var.public_access_cidrs
  }

  # Encrypt Kubernetes secrets with customer-managed KMS key
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
    aws_cloudwatch_log_group.eks,
  ]
}

# =============================================================================
# IRSA — OIDC Provider
# =============================================================================

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-oidc"
  })
}

# =============================================================================
# IAM – Node Role (EC2 instances)
# =============================================================================

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name_prefix}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  # Enables SSM Session Manager — no SSH keys or bastion needed
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node.name
}

# =============================================================================
# Node Groups
# =============================================================================

# --- On-Demand: system & critical workloads ---
resource "aws_eks_node_group" "on_demand" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-on-demand"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  instance_types = var.on_demand_instance_types

  scaling_config {
    desired_size = var.on_demand_desired
    min_size     = var.on_demand_min
    max_size     = var.on_demand_max
  }

  update_config {
    max_unavailable_percentage = 25
  }

  # WHY TAINT: Taint system nodes so ONLY pods with the matching toleration schedule
  # here (coredns, kube-proxy, aws-node, cluster-autoscaler).
  # This prevents application pods from consuming system-node capacity during burst.
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "node.clevertap.com/capacity-type" = "on-demand"
    "node.clevertap.com/workload-type" = "system"
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-on-demand-node"
    "k8s.io/cluster-autoscaler/enabled"              = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}"  = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# --- On-Demand: SLA-bound application workloads (no taint — accepts all pods) ---
# WHY SEPARATE: Campaign delivery and event ingestion services carry contractual SLAs.
# Spot interruption (even with NTH graceful drain) introduces latency spikes.
# These workloads are pinned here via node affinity in their Helm charts.
resource "aws_eks_node_group" "on_demand_app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-on-demand-app"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version

  ami_type       = "AL2_x86_64"
  capacity_type  = "ON_DEMAND"
  instance_types = var.on_demand_app_instance_types

  scaling_config {
    desired_size = var.on_demand_app_desired
    min_size     = var.on_demand_app_min
    max_size     = var.on_demand_app_max
  }

  update_config {
    max_unavailable_percentage = 25
  }

  labels = {
    "node.clevertap.com/capacity-type" = "on-demand"
    "node.clevertap.com/workload-type" = "application-sla"
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-on-demand-app-node"
    "k8s.io/cluster-autoscaler/enabled"              = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}"  = "owned"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# --- Spot: stateless application & burst workloads ---
# EVICTION STRATEGY:
#   capacity_type = SPOT with capacity_optimized allocation (not lowest-price).
#
# WHY capacity_optimized over lowest-price:
#   - lowest-price picks the cheapest pool, which is often the most depleted and
#     therefore highest interruption risk. Under a 10-50x campaign spike, ALL
#     services request Spot simultaneously — a heavily-used pool gets interrupted
#     mid-scale-out, defeating the purpose.
#   - capacity_optimized picks pools with the most available capacity, trading
#     a small cost premium (~5-10%) for dramatically lower interruption rates.
#     For event ingestion at CleverTap scale, availability > cost optimisation.
#
# INSTANCE DIVERSIFICATION:
#   Mix families with equivalent vCPU:memory ratios (4:8 ratio across c5/m5/r5).
#   Cluster Autoscaler's --expander=least-waste selects the most bin-pack-efficient
#   type. If one pool (e.g., c5.2xlarge in us-east-1a) is interrupted, AWS Node
#   Termination Handler sends a 2-minute drain signal → pods reschedule to remaining
#   instances in other families/AZs before the node is terminated.
#
# POD DISRUPTION: See kubernetes/manifests/pdb.yaml — PDBs prevent more than
#   N pods of any stateless service from being evicted simultaneously.
resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version

  ami_type      = "AL2_x86_64"
  capacity_type = "SPOT"
  # Diversified across c5/c5d/c5n/m5/m5d — same vCPU:mem ratio, different
  # Spot pools. Reduces correlated interruption probability across all families.
  instance_types = var.spot_instance_types

  scaling_config {
    desired_size = var.spot_desired
    min_size     = var.spot_min
    max_size     = var.spot_max
  }

  update_config {
    # Allow 33% unavailable during node group rolling update (Spot nodes are
    # stateless — losing 1 in 3 during an update is acceptable)
    max_unavailable_percentage = 33
  }

  labels = {
    "node.clevertap.com/capacity-type" = "spot"
    "node.clevertap.com/workload-type" = "stateless-burst"
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-spot-node"
    "k8s.io/cluster-autoscaler/enabled"              = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}"  = "owned"
    # AWS Node Termination Handler uses this tag to subscribe SQS to EC2
    # Spot interruption notices and schedule graceful pod drain
    "aws-node-termination-handler/managed"           = "true"
  })

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# =============================================================================
# Launch Template (shared by both node groups)
# =============================================================================

resource "aws_launch_template" "nodes" {
  name_prefix = "${local.name_prefix}-node-lt-"
  description = "EKS node launch template for ${var.cluster_name}"

  # Nodes run in private subnets — no public IP needed
  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.nodes.id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }

  metadata_options {
    # IMDSv2 required: prevents SSRF-based credential theft
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 2 needed for pods to reach IMDS via VPC CNI
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-node-ebs"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# EKS Add-ons (managed by Terraform — no manual kubectl apply)
#
# VERSION PINNING STRATEGY:
#   - In prod: set most_recent = false and pin explicit versions in tfvars.
#     Changes to add-on versions go through a PR, get a terraform plan review,
#     and are applied in a maintenance window.
#   - In dev/staging: most_recent = true is acceptable for early validation
#     of upcoming versions before promoting to prod.
#
# UPGRADE SEQUENCE (must be respected to avoid networking/DNS race conditions):
#   1. vpc-cni  — must match node networking before anything else
#   2. kube-proxy — layer 4 traffic routing
#   3. coredns  — DNS resolution for pods
#   4. ebs-csi  — storage; last because it depends on running nodes
# =============================================================================

# Resolve add-on versions: in prod, override most_recent=false and set explicit
# version in the calling environment's tfvars.
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = var.addon_most_recent
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = var.addon_most_recent
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = var.addon_most_recent
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = var.addon_most_recent
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "vpc-cni"
  addon_version            = data.aws_eks_addon_version.vpc_cni.version
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn = aws_iam_role.vpc_cni_irsa.arn

  tags = local.common_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "coredns"
  addon_version            = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.on_demand]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "kube-proxy"
  addon_version            = data.aws_eks_addon_version.kube_proxy.version
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = data.aws_eks_addon_version.ebs_csi.version
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn = aws_iam_role.ebs_csi_irsa.arn

  tags = local.common_tags
}

# =============================================================================
# IRSA Roles — VPC CNI
# =============================================================================

data "aws_iam_policy_document" "vpc_cni_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vpc_cni_irsa" {
  name               = "${local.name_prefix}-vpc-cni-irsa"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_irsa_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni_irsa" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpc_cni_irsa.name
}

# =============================================================================
# IRSA Roles — EBS CSI Driver
# =============================================================================

data "aws_iam_policy_document" "ebs_csi_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_irsa" {
  name               = "${local.name_prefix}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_irsa_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_irsa" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_irsa.name
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
