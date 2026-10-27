output "instance_id" {
  value = aws_instance.iis.id
}

output "session_manager_url" {
  description = "Opens a PowerShell session in the browser, no ports or keys needed"
  value       = "https://${var.region}.console.aws.amazon.com/systems-manager/session-manager/${aws_instance.iis.id}?region=${var.region}"
}

output "fleet_manager_url" {
  description = "Fleet Manager node page: use Node actions > Connect > Remote Desktop for a GUI session"
  value       = "https://${var.region}.console.aws.amazon.com/systems-manager/fleet-manager/managed-nodes/${aws_instance.iis.id}/general?region=${var.region}"
}

output "rdp_key_file" {
  description = "Paste this file's contents into Fleet Manager's Key pair option"
  value       = local_sensitive_file.rdp_key.filename
}
