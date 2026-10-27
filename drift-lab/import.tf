# Tells Terraform: this bucket already exists in AWS, adopt it into state.
import {
  to = aws_s3_bucket.manual
  id = "drift-lab-manual-${local.account_id}"
}

resource "aws_s3_bucket" "manual" {
  bucket        = "drift-lab-manual-${local.account_id}"
  force_destroy = true # lab only: lets terraform destroy remove it even if it has objects
}
