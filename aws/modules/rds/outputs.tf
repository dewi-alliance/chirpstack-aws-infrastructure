output "rds_access_security_group_id" {
  description = "The ID of the security group required to access the Chirpstack RDS instance"
  value       = try(aws_security_group.rds_access_security_group.id, null)
}
