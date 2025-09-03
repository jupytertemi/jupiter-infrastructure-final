terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
  default_tags {
    tags = {
      Environment = "prod"
      Project     = "Jupiter"
      ManagedBy   = "Terraform"
    }
  }
}

# Data sources
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "prod-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "prod-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = {
    Name = "prod-public-${count.index + 1}"
    Type = "Public"
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = {
    Name = "prod-private-${count.index + 1}"
    Type = "Private"
  }
}

# Data source for AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Route table for public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  
  tags = {
    Name = "prod-public-rt"
  }
}

# Associate public subnets with public route table
resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Group for NAT instances
resource "aws_security_group" "nat" {
  name_prefix = "prod-nat-"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "prod-nat-sg"
  }
}

# NAT Instances (in PUBLIC subnets - CRITICAL!)
resource "aws_instance" "nat" {
  count                       = 2
  ami                        = data.aws_ami.ubuntu.id
  instance_type              = "t3.nano"
  subnet_id                  = aws_subnet.public[count.index].id
  associate_public_ip_address = true
  source_dest_check          = false # CRITICAL for NAT
  vpc_security_group_ids     = [aws_security_group.nat.id]
  
  user_data = <<-EOF
    #!/bin/bash
    echo 1 > /proc/sys/net/ipv4/ip_forward
    iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
    apt-get update && apt-get install -y iptables-persistent
  EOF
  
  tags = {
    Name = "nat-${count.index == 0 ? "primary" : "secondary"}"
    Role = "NAT"
  }
}

# Elastic IPs for NAT instances
resource "aws_eip" "nat" {
  count    = 2
  instance = aws_instance.nat[count.index].id
  domain   = "vpc"
  
  tags = {
    Name = "nat-eip-${count.index + 1}"
  }
}

# Route tables for private subnets
resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "prod-private-rt-${count.index + 1}"
  }
}

# Routes for private subnets through NAT
resource "aws_route" "private_nat" {
  count                  = 3
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[count.index < 2 ? count.index : 1].primary_network_interface_id
}

# Associate private subnets with private route tables
resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Security group for services
resource "aws_security_group" "services" {
  name_prefix = "prod-services-"
  vpc_id      = aws_vpc.main.id
  
  # Allow from VPC
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  
  # Specific service ports from internet (via LB)
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 3478
    to_port     = 3479
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 3478
    to_port     = 3479
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 7000
    to_port     = 7000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "prod-services-sg"
  }
}

# Service Instances
resource "aws_instance" "services" {
  for_each = {
    signaling    = "3000"
    coturn       = "3478"
    frp          = "7000"
    thingsboard  = "8080"
  }
  
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.services.id]
  
  user_data = templatefile("${path.module}/user-data/${each.key}.sh", {
    service_name = each.key
    service_port = each.value
  })
  
  tags = {
    Name        = "${each.key}-primary"
    Service     = each.key
    Environment = "prod"
  }
}

# FRP needs an Elastic IP
resource "aws_eip" "frp" {
  instance = aws_instance.services["frp"].id
  domain   = "vpc"
  
  tags = {
    Name = "frp-eip"
  }
}

# Application Load Balancer
resource "aws_lb" "alb" {
  name               = "prod-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.services.id]
  subnets           = aws_subnet.public[*].id
  
  tags = {
    Name = "prod-alb"
  }
}

# Network Load Balancer
resource "aws_lb" "nlb" {
  name               = "prod-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets           = aws_subnet.public[*].id
  
  tags = {
    Name = "prod-nlb"
  }
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "nat_ips" {
  value = aws_eip.nat[*].public_ip
}

output "frp_ip" {
  value = aws_eip.frp.public_ip
}

output "alb_dns" {
  value = aws_lb.alb.dns_name
}

output "nlb_dns" {
  value = aws_lb.nlb.dns_name
}

# BACKUP INSTANCES - PILOT LIGHT (STOPPED)
resource "aws_instance" "backup_services" {
  for_each = {
    signaling    = "3000"
    coturn       = "3478"
    frp          = "7000"
    thingsboard  = "8080"
  }
  
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private[1].id  # Different AZ for DR
  vpc_security_group_ids = [aws_security_group.services.id]
  
  user_data = templatefile("${path.module}/user-data/${each.key}.sh", {
    service_name = each.key
    service_port = each.value
  })
  
  tags = {
    Name        = "${each.key}-backup"
    Service     = each.key
    Environment = "prod"
    Role        = "backup"
  }
  
  # CRITICAL: Stop after creation for pilot light
  lifecycle {
    ignore_changes = [instance_state]
  }
}

# Stop backup instances after creation (pilot light)
resource "null_resource" "stop_backup_instances" {
  for_each = aws_instance.backup_services
  
  provisioner "local-exec" {
    command = "aws ec2 stop-instances --instance-ids ${each.value.id} --region ap-southeast-2"
  }
  
  depends_on = [aws_instance.backup_services]
}

# Backup NAT instance
resource "aws_instance" "nat_backup" {
  ami                        = data.aws_ami.ubuntu.id
  instance_type              = "t3.nano"
  subnet_id                  = aws_subnet.public[2].id  # Third AZ
  associate_public_ip_address = true
  source_dest_check          = false
  vpc_security_group_ids     = [aws_security_group.nat.id]
  
  user_data = <<-EOF
    #!/bin/bash
    echo 1 > /proc/sys/net/ipv4/ip_forward
    iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE
    apt-get update && apt-get install -y iptables-persistent
  EOF
  
  tags = {
    Name = "nat-backup"
    Role = "NAT-Backup"
  }
  
  lifecycle {
    ignore_changes = [instance_state]
  }
}

# Stop NAT backup (pilot light)
resource "null_resource" "stop_nat_backup" {
  provisioner "local-exec" {
    command = "aws ec2 stop-instances --instance-ids ${aws_instance.nat_backup.id} --region ap-southeast-2"
  }
  
  depends_on = [aws_instance.nat_backup]
}

# Lambda for automatic failover
resource "aws_lambda_function" "failover" {
  filename      = "failover.zip"
  function_name = "jupiter-failover"
  role          = aws_iam_role.lambda_failover.arn
  handler       = "index.handler"
  runtime       = "python3.9"
  timeout       = 60
  
  environment {
    variables = {
      BACKUP_SIGNALING   = aws_instance.backup_services["signaling"].id
      BACKUP_COTURN      = aws_instance.backup_services["coturn"].id
      BACKUP_FRP         = aws_instance.backup_services["frp"].id
      BACKUP_THINGSBOARD = aws_instance.backup_services["thingsboard"].id
      BACKUP_NAT         = aws_instance.nat_backup.id
    }
  }
}

# IAM role for Lambda failover
resource "aws_iam_role" "lambda_failover" {
  name = "jupiter-lambda-failover-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for Lambda to start instances
resource "aws_iam_role_policy" "lambda_failover" {
  name = "jupiter-lambda-failover-policy"
  role = aws_iam_role.lambda_failover.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# CloudWatch Alarms for primary instances
resource "aws_cloudwatch_metric_alarm" "instance_health" {
  for_each = aws_instance.services
  
  alarm_name          = "${each.key}-primary-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name        = "StatusCheckFailed"
  namespace          = "AWS/EC2"
  period             = "60"
  statistic          = "Average"
  threshold          = "1"
  alarm_description  = "Trigger failover when primary ${each.key} fails"
  
  dimensions = {
    InstanceId = each.value.id
  }
  
  alarm_actions = [aws_lambda_function.failover.arn]
}
