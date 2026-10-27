# -----------------------------------------------------------------------------
# The Windows Server 2022 instance and what it needs to be managed by SSM.
# -----------------------------------------------------------------------------

# AWS publishes the latest Windows AMI IDs as public SSM parameters, so the
# lab always gets the current, patched image without hard-coding an AMI ID.
data "aws_ssm_parameter" "windows_2022" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

# ---- IAM: lets the SSM Agent on the instance register with Systems Manager ----

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iis" {
  name               = "iis-lab-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# The one managed policy an instance needs for Session Manager, Run Command,
# Fleet Manager and Patch Manager.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.iis.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "iis" {
  name = "iis-lab-instance-profile"
  role = aws_iam_role.iis.name
}

# ---- Key pair: only used to unlock the Administrator password for Fleet Manager RDP ----
# No RDP port is opened. Fleet Manager tunnels the RDP session through SSM.
# LAB ONLY: the private key ends up in Terraform state (encrypted in S3) and in a
# local file. In production you'd sign in with SSO or a domain account instead.

resource "tls_private_key" "rdp" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "rdp" {
  key_name   = "iis-lab-key"
  public_key = tls_private_key.rdp.public_key_openssh
}

resource "local_sensitive_file" "rdp_key" {
  content         = tls_private_key.rdp.private_key_pem
  filename        = "${path.module}/iis-lab-key.pem"
  file_permission = "0600"
}

# ---- The instance ----

resource "aws_instance" "iis" {
  ami                    = data.aws_ssm_parameter.windows_2022.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.iis.id]
  iam_instance_profile   = aws_iam_instance_profile.iis.name
  key_name               = aws_key_pair.rdp.key_name

  # IMDSv2 only: a security baseline item auditors look for
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  tags = {
    Name = "iis-lab-web01"
    Role = "iis-lab" # Run Command targets instances by this tag, the way you'd target a fleet
  }

  # A new Windows AMI is published monthly. Without this, every plan after a new
  # release would want to replace the instance. Real fleets roll new AMIs out
  # deliberately (instance refresh), not as a side effect of an unrelated apply.
  lifecycle {
    ignore_changes = [ami]
  }
}
