# AWS ElastiCache Valkey replication group
resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "${local.name}-valkey"
  description          = "Private Valkey cache for the Tailscale demonstration"
  engine               = "valkey"
  engine_version       = "9.1"
  node_type            = var.valkey_node_type
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name          = aws_elasticache_subnet_group.valkey.name
  security_group_ids         = [aws_security_group.valkey.id]
  user_group_ids             = [aws_elasticache_user_group.valkey.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  apply_immediately          = true

  tags = merge(local.common_tags, { Name = "${local.name}-valkey" })
}

# ElastiCache subnet group for Valkey
resource "aws_elasticache_subnet_group" "valkey" {
  name       = "${local.name}-valkey"
  subnet_ids = values(aws_subnet.valkey)[*].id

  tags = merge(local.common_tags, { Name = "${local.name}-valkey" })
}

# ElastiCache Valkey RBAC user group
resource "aws_elasticache_user_group" "valkey" {
  engine        = "valkey"
  user_group_id = "${local.name}-valkey"
  user_ids      = [aws_elasticache_user.default.user_id]
}

# ElastiCache Valkey RBAC user
resource "aws_elasticache_user" "default" {
  user_id              = "${local.name}-cli"
  user_name            = "valkey"
  engine               = "valkey"
  access_string        = "on ~* +@all"
  passwords_wo         = var.valkey_password
  passwords_wo_version = var.valkey_password_version
}

# AWS SSM password for ElastiCache Valkey
resource "aws_ssm_parameter" "valkey_password" {
  name             = "/${local.name}/valkey/password"
  description      = "Password for the ${local.name} ElastiCache Valkey user"
  type             = "SecureString"
  value_wo         = var.valkey_password
  value_wo_version = var.valkey_password_version

  tags = merge(local.common_tags, { Name = "${local.name}-valkey-password" })
}

# ElastiCache Valkey security group (only allow access from subnet routers and demo app nodes)
resource "aws_security_group" "valkey" {
  name        = "${local.name}-valkey"
  description = "TLS Valkey access from the app and Tailscale subnet routers"
  vpc_id      = aws_vpc.demo.id

  ingress {
    description     = "Valkey TLS from demo app instances"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "Valkey TLS through Tailscale subnet routers"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.router.id]
  }

  tags = merge(local.common_tags, { Name = "${local.name}-valkey" })
}
