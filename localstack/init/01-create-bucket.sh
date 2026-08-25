#!/usr/bin/env bash
# Runs automatically inside the LocalStack container on startup
# (mounted at /etc/localstack/init/ready.d/ — LocalStack's init hook system).
# Creates the ticket-receipts bucket used by Task 1.
# Actual Lambda event-notification wiring on this bucket is done by
# localstack/deploy-lambda.sh, since the Lambda function must exist first.
set -euo pipefail

BUCKET_NAME="${S3_BUCKET:-cloudcrafter-ticket-receipts}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "[init] Creating S3 bucket: $BUCKET_NAME"
awslocal s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  2>/dev/null || echo "[init] Bucket $BUCKET_NAME already exists, skipping."

echo "[init] Bucket ready: $BUCKET_NAME"
