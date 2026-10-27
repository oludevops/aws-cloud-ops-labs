# -----------------------------------------------------------------------------
# Bootstrap: creates the S3 bucket that stores the lab's Terraform state.
#
# This is the "chicken and egg" step: Terraform needs a bucket to store state,
# but something has to create that bucket first. So this small configuration
# uses LOCAL state, runs once, and rarely changes. Many teams create the state
# bucket this way, or with a one-off CloudFormation stack.
#
# Locking: Terraform 1.10+ can lock state with a lock file in the same S3 bucket
# (use_lockfile = true), so no DynamoDB table is needed any more.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10.0" # needed for S3-native state locking

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Project   = "drift-lab-bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are global across all AWS accounts, so the account ID keeps it unique
  state_bucket = "drift-lab-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # LAB ONLY: lets `terraform destroy` empty and delete the bucket at cleanup.
  # For a real state bucket, remove this and add:
  #   lifecycle { prevent_destroy = true }
  force_destroy = true
}

# Versioning keeps every previous version of the state file.
# If state is ever corrupted or wrongly edited, you can restore an older version.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# State files contain resource IDs, ARNs and sometimes secrets in plain text,
# so encrypt them at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # SSE-S3; use "aws:kms" with a customer key for stricter control
    }
  }
}

# Never allow the state bucket to become public.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disable ACLs entirely: access is controlled only by IAM and bucket policy.
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Refuse any request that is not over HTTPS.
data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  # The public access block must exist first, or AWS may reject the policy call
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Keep old state versions for 90 days, then delete them, so the bucket doesn't grow forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

# Writes the partial backend settings the main lab needs.
# Usage from the lab folder:
#   terraform -chdir=bootstrap output -raw backend_config > backend.hcl
output "backend_config" {
  value = <<-EOT
    bucket = "${aws_s3_bucket.state.id}"
    region = "${var.region}"
  EOT
}
