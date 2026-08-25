#!/usr/bin/env bash
# CloudCrafter Task 1 — packages and deploys the notify-on-receipt Lambda to
# LocalStack, then wires an S3 -> Lambda event notification on the
# ticket-receipts bucket so it fires automatically (no manual invocation).
#
# Prerequisites: LocalStack already running (see localstack/docker-compose.yml)
#                and `awslocal` (pip install awscli-local) or plain `aws`
#                pointed at --endpoint-url=http://localhost:4566.
#
# Usage:
#   ./localstack/deploy-lambda.sh [NOTIFICATIONS_URL]
#
# NOTIFICATIONS_URL: LocalStack's Lambda container runs on the HOST's Docker
# daemon, outside Minikube, so it must reach Notifications via Minikube's own
# IP + the NodePort Service (k8s/notifications-external-service.yaml) —
# NOT via host.minikube.internal (that name only resolves the other
# direction: from inside Minikube pods back out to the host machine).
# If not passed explicitly, this script auto-detects it with `minikube ip`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="$SCRIPT_DIR/lambda/notify-on-receipt"
BUCKET_NAME="${S3_BUCKET:-cloudcrafter-ticket-receipts}"
FUNCTION_NAME="notify-on-receipt"

if [ -n "${1:-}" ]; then
  NOTIFICATIONS_URL="$1"
elif [ -n "${NOTIFICATIONS_URL:-}" ]; then
  : # use the pre-set env var as-is
else
  MINIKUBE_IP="$(minikube ip)"
  NOTIFICATIONS_URL="http://${MINIKUBE_IP}:30080"
fi

echo "==> Installing Lambda dependencies"
(cd "$LAMBDA_DIR" && npm install --omit=dev)

echo "==> Packaging Lambda zip"
rm -f "$SCRIPT_DIR/notify-on-receipt.zip"
(cd "$LAMBDA_DIR" && zip -q -r "$SCRIPT_DIR/notify-on-receipt.zip" .)

echo "==> Creating/updating Lambda function in LocalStack"
if awslocal lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  awslocal lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$SCRIPT_DIR/notify-on-receipt.zip" >/dev/null
  awslocal lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --environment "Variables={NOTIFICATIONS_URL=$NOTIFICATIONS_URL}" >/dev/null
else
  awslocal lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime nodejs18.x \
    --handler index.handler \
    --zip-file "fileb://$SCRIPT_DIR/notify-on-receipt.zip" \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --environment "Variables={NOTIFICATIONS_URL=$NOTIFICATIONS_URL}" \
    --timeout 30 >/dev/null
fi

echo "==> Granting S3 permission to invoke the Lambda"
awslocal lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id s3invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$BUCKET_NAME" \
  >/dev/null 2>&1 || echo "   (permission already exists, skipping)"

FUNCTION_ARN=$(awslocal lambda get-function --function-name "$FUNCTION_NAME" \
  --query 'Configuration.FunctionArn' --output text)

echo "==> Wiring S3 bucket notification: $BUCKET_NAME -> $FUNCTION_NAME"
awslocal s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\": [
      {
        \"LambdaFunctionArn\": \"$FUNCTION_ARN\",
        \"Events\": [\"s3:ObjectCreated:*\"]
      }
    ]
  }"

echo "==> Done. Lambda '$FUNCTION_NAME' will now fire automatically on every"
echo "    object uploaded to s3://$BUCKET_NAME, and will call: $NOTIFICATIONS_URL/notify"
