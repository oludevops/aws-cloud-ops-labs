# -----------------------------------------------------------------------------
# Prevention: three roles that model "view vs change" access.
#
#   drift-lab-readonly  -> engineers / MSP staff: can look at everything, change nothing
#   drift-lab-operator  -> powerful day-to-day role, BUT a guardrail blocks it from
#                          touching anything tagged ManagedBy=terraform
#   drift-lab-deployer  -> stands in for the CI/CD pipeline role: the only one allowed
#                          to change Terraform-managed resources
#
# In a real setup the deployer role would trust GitHub Actions via OIDC, and the
# guardrail would be a Service Control Policy (see scp-example.json). Here all
# three roles trust your own account, so you can assume them from the CLI and console.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "trust_this_account" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
}

# ---- 1. Read-only role -------------------------------------------------------

resource "aws_iam_role" "readonly" {
  name               = "drift-lab-readonly"
  assume_role_policy = data.aws_iam_policy_document.trust_this_account.json
}

# ViewOnlyAccess lets you see resources and their settings, but not read data
# (for example, it cannot download objects from S3). Safer than ReadOnlyAccess for an MSP.
resource "aws_iam_role_policy_attachment" "readonly_view" {
  role       = aws_iam_role.readonly.name
  policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

# ---- 2. Operator role + guardrail -------------------------------------------

resource "aws_iam_role" "operator" {
  name               = "drift-lab-operator"
  assume_role_policy = data.aws_iam_policy_document.trust_this_account.json
}

# PowerUserAccess = almost everything EXCEPT IAM. That matters: the operator cannot
# detach the guardrail from itself.
resource "aws_iam_role_policy_attachment" "operator_poweruser" {
  role       = aws_iam_role.operator.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# The guardrail. This is the same logic you would put in an SCP: deny changes to
# Terraform-managed resources unless the caller is the pipeline role.
# An explicit Deny always beats an Allow, so PowerUserAccess cannot override it.
data "aws_iam_policy_document" "protect_terraform_resources" {
  statement {
    sid    = "DenyChangesToTerraformManagedResources"
    effect = "Deny"

    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      "ec2:DeleteSecurityGroup",
      "ec2:ModifyVpcAttribute",
      "ec2:DeleteVpc",
      # Also block tag edits. Otherwise someone could simply delete the
      # ManagedBy tag and then make their change.
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["terraform"]
    }

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.deployer.arn]
    }
  }
}

resource "aws_iam_policy" "protect_terraform_resources" {
  name        = "drift-lab-protect-terraform-resources"
  description = "Deny manual changes to resources tagged ManagedBy=terraform"
  policy      = data.aws_iam_policy_document.protect_terraform_resources.json
}

resource "aws_iam_role_policy_attachment" "operator_guardrail" {
  role       = aws_iam_role.operator.name
  policy_arn = aws_iam_policy.protect_terraform_resources.arn
}

# ---- 3. Deployer role (stands in for the CI/CD pipeline) ---------------------

resource "aws_iam_role" "deployer" {
  name               = "drift-lab-deployer"
  assume_role_policy = data.aws_iam_policy_document.trust_this_account.json
}

resource "aws_iam_role_policy_attachment" "deployer_poweruser" {
  role       = aws_iam_role.deployer.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess excludes IAM, so without this the deployer could not even READ
# the IAM roles during `terraform plan`. Read-only IAM is enough for plans; IAM
# changes stay with a separate, more tightly controlled role.
resource "aws_iam_role_policy_attachment" "deployer_iam_read" {
  role       = aws_iam_role.deployer.name
  policy_arn = "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
}
