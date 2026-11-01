terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region
}
locals {
  name = "tailscale-demo"

  common_tags = {
    Project   = local.name
    ManagedBy = "terraform"
  }

  availability_zones = var.availability_zones

  # Keep address ranges recognizable by role while placing every service in
  # two AZs. /28 provides 11 usable IPv4 addresses per private subnet, which
  # is sufficient for this fixed-size demo fleet.
  public_subnet_cidrs = {
    (local.availability_zones[0]) = cidrsubnet(var.vpc_cidr, 3, 0) # 10.0.42.0/27
    (local.availability_zones[1]) = cidrsubnet(var.vpc_cidr, 3, 2) # 10.0.42.64/27
  }

  router_subnet_cidrs = {
    (local.availability_zones[0]) = cidrsubnet(var.vpc_cidr, 4, 2) # 10.0.42.32/28
    (local.availability_zones[1]) = cidrsubnet(var.vpc_cidr, 4, 3) # 10.0.42.48/28
  }

  app_subnet_cidrs = {
    (local.availability_zones[0]) = cidrsubnet(var.vpc_cidr, 4, 6) # 10.0.42.96/28
    (local.availability_zones[1]) = cidrsubnet(var.vpc_cidr, 4, 7) # 10.0.42.112/28
  }

  valkey_subnet_cidrs = {
    (local.availability_zones[0]) = cidrsubnet(var.vpc_cidr, 4, 12) # 10.0.42.192/28
    (local.availability_zones[1]) = cidrsubnet(var.vpc_cidr, 4, 13) # 10.0.42.208/28
  }
}
resource "aws_vpc" "demo" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = local.name })
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id
  tags   = merge(local.common_tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnet_cidrs

  vpc_id                  = aws_vpc.demo.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${local.name}-public-${each.key}", Tier = "public" })
}

resource "aws_subnet" "router" {
  for_each = local.router_subnet_cidrs

  vpc_id            = aws_vpc.demo.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(local.common_tags, { Name = "${local.name}-router-${each.key}", Tier = "private", Role = "subnet-router" })
}

resource "aws_subnet" "app" {
  for_each = local.app_subnet_cidrs

  vpc_id            = aws_vpc.demo.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(local.common_tags, { Name = "${local.name}-app-${each.key}", Tier = "private", Role = "app" })
}

resource "aws_subnet" "valkey" {
  for_each = local.valkey_subnet_cidrs

  vpc_id            = aws_vpc.demo.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(local.common_tags, { Name = "${local.name}-valkey-${each.key}", Tier = "private", Role = "valkey" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo.id
  }

  tags = merge(local.common_tags, { Name = "${local.name}-public" })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name}-nat" })
}

resource "aws_nat_gateway" "demo" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id
  depends_on    = [aws_internet_gateway.demo]

  tags = merge(local.common_tags, { Name = "${local.name}-nat" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.demo.id
  }

  tags = merge(local.common_tags, { Name = "${local.name}-private" })
}

resource "aws_route_table_association" "router" {
  for_each = aws_subnet.router

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "valkey" {
  for_each = aws_subnet.valkey

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public HTTP entry point for the Tailscale demo app"
  vpc_id      = aws_vpc.demo.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Demo app traffic within the VPC"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-alb" })
}

resource "aws_security_group" "router" {
  name        = "${local.name}-router"
  description = "Tailscale subnet routers with no conventional inbound access"
  vpc_id      = aws_vpc.demo.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-router" })
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Demo app instances behind the ALB"
  vpc_id      = aws_vpc.demo.id

  ingress {
    description     = "HTTP from the ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Tailscale subnet routers SNAT forwarded traffic, so this permits browser
  # access to a private app IP over the advertised VPC route without exposing
  # the app directly to the Internet.
  ingress {
    description     = "HTTP through a Tailscale subnet router"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.router.id]
  }

  ingress {
    description     = "Conventional SSH through a subnet router"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.router.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-app" })
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_lb" "app" {
  name               = "tailscale-demo-app"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = values(aws_subnet.public)[*].id

  tags = merge(local.common_tags, { Name = "${local.name}-app" })
}

resource "aws_lb_target_group" "app" {
  name                 = "tailscale-demo-app"
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = aws_vpc.demo.id
  deregistration_delay = 10

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 10
    matcher             = "200"
    path                = "/api/readyz"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  stickiness {
    enabled = false
    type    = "lb_cookie"
  }

  tags = merge(local.common_tags, { Name = "${local.name}-app" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
