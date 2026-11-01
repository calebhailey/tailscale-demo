# demo app EC2 launch template
resource "aws_launch_template" "app" {
  name_prefix   = "${local.name}-app-"
  image_id      = var.app_ami_id
  instance_type = var.instance_type
  key_name      = var.ssh_public_key_path == null ? null : aws_key_pair.app[0].key_name
  tags          = merge(local.common_tags, { Name = "${local.name}-app", Role = "app" })

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  vpc_security_group_ids = [aws_security_group.app.id]
  user_data = base64encode(<<-USER_DATA
    #!/bin/bash
    set -euo pipefail

    # Make the host identity visible to the application and shell users.
    IMDS_TOKEN=$(curl -fsS -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
    INSTANCE_ID=$(curl -fsS -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/instance-id)
    hostnamectl set-hostname "$${INSTANCE_ID}"

    install -d -o root -g root -m 0755 /usr/local/share/tailscale-demo-app

    # write/update the app data file
    cat >/usr/local/share/tailscale-demo-app/data.json <<'DATA'
    ${file("${path.module}/../app/data.json")}
    DATA
    chown root:root /usr/local/share/tailscale-demo-app/data.json
    chmod 0644 /usr/local/share/tailscale-demo-app/data.json

    # fetch elasticache valkey secret from aws ssm
    install -d -o root -g tailscale-demo-app -m 0750 /etc/tailscale-demo-app
    umask 077
    aws ssm get-parameter \
      --region '${var.aws_region}' \
      --name '${aws_ssm_parameter.valkey_password.name}' \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text >/etc/tailscale-demo-app/valkey-password
    chown tailscale-demo-app:tailscale-demo-app /etc/tailscale-demo-app/valkey-password
    chmod 0400 /etc/tailscale-demo-app/valkey-password
    apt-get purge --yes awscli
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # add valkey configuration to /etc/tailscale-demo-app/valkey.env
    cat >/etc/tailscale-demo-app/valkey.env <<'ENVIRONMENT'
    VALKEY_ADDR=${aws_elasticache_replication_group.valkey.primary_endpoint_address}:${aws_elasticache_replication_group.valkey.port}
    VALKEY_TLS=true
    VALKEY_USERNAME=valkey
    VALKEY_PASSWORD_FILE=/etc/tailscale-demo-app/valkey-password
    ENVIRONMENT
    chown root:tailscale-demo-app /etc/tailscale-demo-app/valkey.env
    chmod 0640 /etc/tailscale-demo-app/valkey.env

    # start/restart the app
    systemctl restart tailscale-demo-app.service

    # register ephemeral tailscale client
    if command -v tailscale >/dev/null 2>&1; then
      until systemctl is-active --quiet tailscaled.service; do sleep 1; done
      tailscale up \
        --client-id='${var.tailscale_app_client_id}?ephemeral=true&preauthorized=true' \
        --audience='${var.tailscale_app_audience}' \
        --advertise-tags=tag:tailscale-demo-app \
        --hostname="tailscale-demo-app-$${INSTANCE_ID}"
    fi
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
    tags          = merge(local.common_tags, { Name = "${local.name}-app", Role = "app" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${local.name}-app", Role = "app" })
  }
}

# demo app SSH key pair
resource "aws_key_pair" "app" {
  count = var.ssh_public_key_path == null ? 0 : 1

  key_name   = "${local.name}-app"
  public_key = file(pathexpand(var.ssh_public_key_path))
  tags       = local.common_tags
}

# demo app ASG
resource "aws_autoscaling_group" "app" {
  name                      = "${local.name}-app"
  min_size                  = var.app_instance_count
  max_size                  = var.app_instance_count
  desired_capacity          = var.app_instance_count
  vpc_zone_identifier       = values(aws_subnet.app)[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180
  wait_for_elb_capacity     = var.app_instance_count
  wait_for_capacity_timeout = "15m"

  depends_on = [aws_route_table_association.app]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 67
      instance_warmup        = 30
      skip_matching          = true
    }
  }

  dynamic "tag" {
    for_each = merge(local.common_tags, { Name = "${local.name}-app", Role = "app" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# demo app EC2 IAM instance profile
resource "aws_iam_instance_profile" "app" {
  name = "tailscale-demo-app"
  role = aws_iam_role.app.name
  tags = merge(local.common_tags, { Name = "${local.name}-app", Role = "app" })
}

# demo app IAM role
resource "aws_iam_role" "app" {
  name               = "tailscale-demo-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.common_tags
}

# demo app IAM role policy
resource "aws_iam_role_policy" "app_workload_identity" {
  name   = "tailscale-workload-identity"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_workload_identity.json
}

resource "aws_iam_role_policy" "app_valkey_password" {
  name   = "tailscale-demo-valkey-password"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_valkey_password.json
}

# demo app IAM role policy document
data "aws_iam_policy_document" "app_workload_identity" {
  statement {
    sid       = "MintTailscaleIdentityToken"
    actions   = ["sts:GetWebIdentityToken"]
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "sts:IdentityTokenAudience"
      values   = [var.tailscale_app_audience]
    }

    condition {
      test     = "NumericLessThanEquals"
      variable = "sts:DurationSeconds"
      values   = ["300"]
    }
  }
}

data "aws_iam_policy_document" "app_valkey_password" {
  statement {
    sid       = "ReadValkeyPassword"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.valkey_password.arn]
  }
}
