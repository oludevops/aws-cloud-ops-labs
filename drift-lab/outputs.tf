output "account_id" {
  value = local.account_id
}

output "security_group_id" {
  value = aws_security_group.web.id
}

output "manual_bucket_name" {
  description = "Name to use for the bucket you create by hand in Exercise D"
  value       = "drift-lab-manual-${local.account_id}"
}

output "readonly_role_arn" {
  value = aws_iam_role.readonly.arn
}

output "operator_role_arn" {
  value = aws_iam_role.operator.arn
}

output "deployer_role_arn" {
  value = aws_iam_role.deployer.arn
}

output "console_switch_role_readonly" {
  description = "Open this link in the browser to try the console as the read-only role"
  value       = "https://signin.aws.amazon.com/switchrole?roleName=${aws_iam_role.readonly.name}&account=${local.account_id}&displayName=drift-readonly"
}

output "console_switch_role_operator" {
  description = "Open this link in the browser to try the console as the guarded operator role"
  value       = "https://signin.aws.amazon.com/switchrole?roleName=${aws_iam_role.operator.name}&account=${local.account_id}&displayName=drift-operator"
}
