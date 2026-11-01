# Tailscale subnet router EC2 launch template
resource "aws_launch_template" "router" {
  name_prefix   = "${local.name}-router-"
  image_id      = var.router_ami_id
  instance_type = var.instance_type
  tags = merge(local.common_tags, {
    Name = "${local.name}-router"
    Role = "subnet-router"
  })

  iam_instance_profile {
    name = aws_iam_instance_profile.router.name
  }

  vpc_security_group_ids = [aws_security_group.router.id]
  user_data = base64encode(<<-USER_DATA
    #!/bin/bash
    set -euo pipefail

    until systemctl is-active --quiet tailscaled.service; do sleep 1; done
    IMDS_TOKEN=$(curl -fsS -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
    INSTANCE_ID=$(curl -fsS -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)
    hostnamectl set-hostname "$${INSTANCE_ID}"
    tailscale up \
      --client-id='${var.tailscale_router_client_id}?ephemeral=true&preauthorized=true' \
      --audience='${var.tailscale_router_audience}' \
      --advertise-tags=tag:tailscale-demo-router \
      --advertise-routes='${var.vpc_cidr}' \
      --hostname="tailscale-demo-router-$${INSTANCE_ID}" \
      --ssh
    USER_DATA
  )

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      encrypted   = true
      volume_size = 8
      volume_type = "gp3"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name    = "${local.name}-router"
      Role    = "subnet-router"
      Version = var.router_version
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name    = "${local.name}-router"
      Role    = "subnet-router"
      Version = var.router_version
    })
  }
}
# Tailscale subnet router ASG
resource "aws_autoscaling_group" "router" {
  name                      = "${local.name}-router"
  min_size                  = var.router_instance_count
  max_size                  = var.router_instance_count
  desired_capacity          = var.router_instance_count
  vpc_zone_identifier       = values(aws_subnet.router)[*].id
  health_check_type         = "EC2"
  health_check_grace_period = 180
  wait_for_capacity_timeout = "15m"

  depends_on = [aws_route_table_association.router]

  launch_template {
    id      = aws_launch_template.router.id
    version = aws_launch_template.router.latest_version
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 180
      skip_matching          = true
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${local.name}-router", Role = "subnet-router" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}
# Tailscale subnet router EC2 IAM instance profile
resource "aws_iam_instance_profile" "router" {
  name = "tailscale-demo-router"
  role = aws_iam_role.router.name
  tags = merge(local.common_tags, {
    Name = "${local.name}-router"
    Role = "subnet-router"
  })
}
# Tailscale subnet router IAM role
resource "aws_iam_role" "router" {
  name               = "tailscale-demo-router"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

# Tailscale subnet router IAM role policy
resource "aws_iam_role_policy" "router_workload_identity" {
  name   = "tailscale-workload-identity"
  role   = aws_iam_role.router.id
  policy = data.aws_iam_policy_document.router_workload_identity.json
}

# Tailscale subnet router IAM policy document
data "aws_iam_policy_document" "router_workload_identity" {
  statement {
    sid       = "MintTailscaleIdentityToken"
    actions   = ["sts:GetWebIdentityToken"]
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "sts:IdentityTokenAudience"
      values   = [var.tailscale_router_audience]
    }

    condition {
      test     = "NumericLessThanEquals"
      variable = "sts:DurationSeconds"
      values   = ["300"]
    }
  }
}
