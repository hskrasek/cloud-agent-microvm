output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "build_role_arn" {
  value = aws_iam_role.build.arn
}

output "exec_role_arn" {
  value = aws_iam_role.exec.arn
}

output "secret_arn" {
  value = aws_secretsmanager_secret.github_token.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.github_token.name
}
