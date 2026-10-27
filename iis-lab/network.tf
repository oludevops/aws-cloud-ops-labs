# -----------------------------------------------------------------------------
# A small VPC with one public subnet.
#
# The instance gets a public IP only so it can reach the Systems Manager
# endpoints over the Internet Gateway. Its security group allows NO inbound
# traffic at all: no RDP (3389), no HTTP. Every connection in this lab goes
# through Systems Manager, which the SSM Agent opens from the inside, outbound.
#
# (In production you'd put it in a private subnet and reach SSM through VPC
# endpoints or a NAT Gateway. Both cost money per hour, so the lab skips them.)
# -----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.43.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "iis-lab-vpc" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "iis-lab-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.43.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "iis-lab-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "iis-lab-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "iis" {
  name        = "iis-lab-no-inbound"
  description = "No inbound rules: all access is through Systems Manager"
  vpc_id      = aws_vpc.lab.id

  # Deliberately no ingress blocks.

  egress {
    description = "Outbound HTTPS to Systems Manager, Windows Update and AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iis-lab-no-inbound" }
}
