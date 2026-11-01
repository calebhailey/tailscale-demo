output "app_url" {
  description = "Public ALB URL for the demo application."
  value       = "http://${aws_lb.app.dns_name}"
}

output "app_asg_name" {
  description = "Application Auto Scaling Group name."
  value       = aws_autoscaling_group.app.name
}

output "router_asg_name" {
  description = "Subnet-router Auto Scaling Group name."
  value       = aws_autoscaling_group.router.name
}

output "target_group_arn" {
  description = "Application target group ARN."
  value       = aws_lb_target_group.app.arn
}

output "vpc_id" {
  description = "Demonstration VPC ID."
  value       = aws_vpc.demo.id
}

output "valkey_primary_endpoint" {
  description = "Private DNS name of the primary Valkey endpoint."
  value       = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "valkey_port" {
  description = "TLS port for the Valkey primary endpoint."
  value       = aws_elasticache_replication_group.valkey.port
}
