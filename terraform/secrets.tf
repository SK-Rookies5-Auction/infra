resource "aws_secretsmanager_secret" "app" {
  name        = "${var.project_name}/${var.environment}/app"
  description = "Application secrets for ${var.project_name} ${var.environment}"

  tags = {
    Name = "${var.project_name}-${var.environment}-app-secrets"
  }
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id

  secret_string = jsonencode({
    DB_HOST        = aws_db_instance.main.address
    DB_NAME        = var.db_name
    DB_USERNAME    = var.db_username
    DB_PASSWORD    = var.db_password
    S3_BUCKET_NAME = aws_s3_bucket.app.bucket
  })
}
