# =============================================================================
# VPC Module – Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (one per AZ)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (one per AZ) — use for EKS node groups"
  value       = aws_subnet.private[*].id
}

output "intra_subnet_ids" {
  description = "List of intra subnet IDs (one per AZ) — use for RDS subnet groups"
  value       = aws_subnet.intra[*].id
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs"
  value       = aws_nat_gateway.this[*].id
}

output "tgw_attachment_id" {
  description = "Transit Gateway VPC attachment ID (null if TGW not configured)"
  value       = length(aws_ec2_transit_gateway_vpc_attachment.this) > 0 ? aws_ec2_transit_gateway_vpc_attachment.this[0].id : null
}

output "flow_logs_bucket_arn" {
  description = "ARN of the S3 bucket receiving VPC flow logs"
  value       = var.create_flow_logs_bucket ? aws_s3_bucket.flow_logs[0].arn : var.flow_logs_bucket_arn
}

output "private_route_table_ids" {
  description = "List of private route table IDs (one per AZ)"
  value       = aws_route_table.private[*].id
}
