# =============================================================================
# Athena — VPC Flow Log Query Table
# =============================================================================
# Enables SQL-based analysis of VPC Flow Logs stored in S3 (Parquet/Hive).
#
# Use cases at CleverTap:
#   1. Security: find unexpected REJECT traffic (misconfigured SGs, port scans)
#   2. Cost: identify top inter-region byte counts (input to data transfer cost reduction)
#   3. Debugging: trace packet drops for a specific pod IP during an incident
#
# Example query — top inter-region data transfer by source:
#   SELECT srcaddr, dstaddr, SUM(bytes) AS total_bytes
#   FROM vpc_flow_logs
#   WHERE year='2024' AND month='06'
#     AND srcaddr LIKE '10.10.%'     -- us-east-1 VPC
#     AND dstaddr LIKE '10.20.%'     -- ap-south-1 VPC
#   GROUP BY 1,2 ORDER BY 3 DESC LIMIT 20;
# =============================================================================

resource "aws_athena_workgroup" "flow_logs" {
  name = "${local.name_prefix}-flow-logs"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${var.create_flow_logs_bucket ? aws_s3_bucket.flow_logs[0].bucket : "EXTERNAL"}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Cost guard: cap each query at 1GB scan to prevent runaway costs
    bytes_scanned_cutoff_per_query = 1073741824
  }

  tags = var.tags
}

resource "aws_glue_catalog_database" "flow_logs" {
  name = replace("${local.name_prefix}_flow_logs", "-", "_")
}

resource "aws_glue_catalog_table" "flow_logs" {
  name          = "vpc_flow_logs"
  database_name = aws_glue_catalog_database.flow_logs.name

  table_type = "EXTERNAL_TABLE"

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
  partition_keys {
    name = "hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${var.create_flow_logs_bucket ? aws_s3_bucket.flow_logs[0].bucket : "EXTERNAL"}/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcflowlogs/${data.aws_region.current.name}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns { name = "version";     type = "int" }
    columns { name = "account_id";  type = "string" }
    columns { name = "interface_id"; type = "string" }
    columns { name = "srcaddr";     type = "string" }
    columns { name = "dstaddr";     type = "string" }
    columns { name = "srcport";     type = "int" }
    columns { name = "dstport";     type = "int" }
    columns { name = "protocol";    type = "bigint" }
    columns { name = "packets";     type = "bigint" }
    columns { name = "bytes";       type = "bigint" }
    columns { name = "start";       type = "bigint" }
    columns { name = "end";         type = "bigint" }
    columns { name = "action";      type = "string" }
    columns { name = "log_status";  type = "string" }
  }

  parameters = {
    "projection.enabled"       = "true"
    "projection.year.type"     = "integer"
    "projection.year.range"    = "2024,2030"
    "projection.month.type"    = "integer"
    "projection.month.range"   = "1,12"
    "projection.month.digits"  = "2"
    "projection.day.type"      = "integer"
    "projection.day.range"     = "1,31"
    "projection.day.digits"    = "2"
    "projection.hour.type"     = "integer"
    "projection.hour.range"    = "0,23"
    "projection.hour.digits"   = "2"
    "storage.location.template" = "s3://${var.create_flow_logs_bucket ? aws_s3_bucket.flow_logs[0].bucket : "EXTERNAL"}/AWSLogs/${data.aws_caller_identity.current.account_id}/vpcflowlogs/${data.aws_region.current.name}/$${year}/$${month}/$${day}/$${hour}/"
    "classification"            = "parquet"
  }
}

data "aws_region" "current" {}
