# -----------------------------------------------------------------------------
# Lab 3: Windows Server + IIS break/fix
# State goes in the same S3 bucket as the drift lab, under a different key.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Bucket and region come from backend.hcl (copied from the drift lab):
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "iis-lab/terraform.tfstate" # separate state file from the drift lab
    encrypt      = true
    use_lockfile = true
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "instance_type" {
  description = "t3.medium (2 vCPU, 4 GB) is the smallest size that runs Windows + IIS comfortably"
  type        = string
  default     = "t3.medium"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Project   = "iis-lab"
    }
  }
}
