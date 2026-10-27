# -----------------------------------------------------------------------------
# Terraform and provider settings
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10.0" # needed for S3-native state locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # Pinned major version: an unplanned provider upgrade is a classic source of "fake drift"
    }
  }

  # Remote state in S3, created by the bootstrap/ configuration.
  #
  # Backend blocks cannot use variables, so the bucket name and region are
  # supplied at init time from backend.hcl ("partial configuration"):
  #   terraform init -backend-config=backend.hcl
  # That keeps account-specific values out of the code, so the same code can
  # point at a different bucket for dev, staging and prod.
  backend "s3" {
    key          = "drift-lab/terraform.tfstate" # path of the state file inside the bucket
    encrypt      = true                          # encrypt the state object at rest
    use_lockfile = true                          # S3-native locking: writes a .tflock file during operations
  }
}

variable "region" {
  description = "AWS region for the lab"
  type        = string
  default     = "us-east-2"
}

provider "aws" {
  region = var.region

  # Every resource Terraform creates gets these tags automatically.
  # The ManagedBy tag is what the guardrail policy (iam.tf) keys on.
  default_tags {
    tags = {
      ManagedBy = "terraform"
      Project   = "drift-lab"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
