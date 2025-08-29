output "instance_id" {
  value = aws_instance.app.id
}

output "public_ip" {
  value = aws_eip.app.public_ip
}

output "public_dns" {
  value = aws_instance.app.public_dns
}

output "fqdn" {
  value = "${var.subdomain}.loguzzo.it"
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.id
}

output "backup_bucket_arn" {
  value = aws_s3_bucket.backups.arn
}

output "eip_address" {
  value = aws_eip.app.public_ip
}