terraform {
  required_version = ">= 1.8"

  backend "s3" {
    bucket = "tofu-state-559450879245-us-east-2"
    key    = "cloud-agent-microvm/terraform.tfstate"
    region = "us-east-2"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

locals {
  account = "559450879245"
  region  = "us-east-2"
}

# Artifact bucket (zip with Dockerfile at root)

resource "aws_s3_bucket" "artifacts" {
  bucket        = "cloud-agent-microvm-artifacts-${local.account}-${local.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Logs

resource "aws_cloudwatch_log_group" "microvms" {
  name              = "/aws/lambda-microvms/cloud-agent"
  retention_in_days = 14
}

# Secret (value set out-of-band via CLI)

resource "aws_secretsmanager_secret" "github_token" {
  name                    = "cloud-agent/github-token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "github_token" {
  secret_id     = aws_secretsmanager_secret.github_token.id
  secret_string = "REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Shared trust policy: Lambda MicroVMs assumes both roles.

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

data "aws_iam_policy_document" "logs" {
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account}:log-group:/aws/lambda-microvms/*"]
  }
}

# Build role

data "aws_iam_policy_document" "build" {
  source_policy_documents = [data.aws_iam_policy_document.logs.json]

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role" "build" {
  name               = "cloud-agent-microvm-build"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy" "build" {
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

# Execution role

data "aws_iam_policy_document" "exec" {
  source_policy_documents = [data.aws_iam_policy_document.logs.json]

  statement {
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.*",
      "arn:aws:bedrock:${local.region}:${local.account}:inference-profile/us.anthropic.*",
    ]
  }

  statement {
    actions   = ["bedrock:ListInferenceProfiles", "bedrock:GetInferenceProfile"]
    resources = ["*"]
  }

  # First invoke of a model auto-creates the AWS Marketplace agreement.
  statement {
    actions   = ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"]
    resources = ["*"]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.github_token.arn]
  }
}

resource "aws_iam_role" "exec" {
  name               = "cloud-agent-microvm-exec"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy" "exec" {
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}
