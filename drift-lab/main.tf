# -----------------------------------------------------------------------------
# The infrastructure we will drift. Everything here is free-tier / no hourly cost:
# a VPC, a security group, an empty log group and one SSM parameter.
# -----------------------------------------------------------------------------

resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "drift-lab-vpc"
  }
}

# Exercise A (REVERT): someone opens SSH to the internet on this group.
#
# The rules are written INLINE on purpose. With inline rules, Terraform owns the
# complete rule set, so any rule added by hand shows up as drift. If you manage
# rules as separate aws_vpc_security_group_ingress_rule resources instead, Terraform
# only tracks the rules it created and a hand-added rule would go unnoticed.
# Rule of thumb: pick ONE style per security group, never both.
resource "aws_security_group" "web" {
  name        = "drift-lab-web"
  description = "Web tier - HTTPS only"
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "drift-lab-web"
  }
}

# Exercise B (CODIFY): during an "incident" someone raises retention to 30 days
# because 7 days was not enough to investigate. That was a good decision, so we
# will change this number to match reality instead of reverting it.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/drift-lab/app"
  retention_in_days = 30 
}

# Exercise C (IGNORE): the application flips this flag at runtime by itself.
# Terraform should create the parameter but NOT fight the app over its value.
# Leave the lifecycle block commented out until the exercise tells you to enable it.
resource "aws_ssm_parameter" "feature_flag" {
  name  = "/drift-lab/feature-flag"
  type  = "String"
  value = "off"

lifecycle {
 ignore_changes = [value]
  }
}
