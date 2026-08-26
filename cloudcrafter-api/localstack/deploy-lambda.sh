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

# Minikube's driver changes what "reachable from a sibling Docker container"
# even means. host.minikube.internal / minikube-ip reachability from
# LocalStack (a plain docker-compose container, NOT inside the cluster) is
# only reliable with the docker driver on top of Docker Desktop (the default
# and recommended setup for Windows + WSL2 + Docker Desktop). Warn loudly on
# other drivers instead of silently producing an unreachable URL.
DRIVER="$(minikube profile list -o json 2>/dev/null | node -pe '
  try {
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const p = (data.valid || [])[0];
    p ? p.Config.Driver : "unknown";
  } catch (e) { "unknown"; }
' 2>/dev/null || echo "unknown")"
if [ "$DRIVER" != "docker" ] && [ "$DRIVER" != "unknown" ]; then
  echo "WARNING: Minikube driver is '$DRIVER', not 'docker'."
  echo "         The minikube-ip + NodePort networking this script uses is only"
  echo "         verified against the docker driver (the default for Windows +"
  echo "         WSL2 + Docker Desktop). See README.md 'Networking' section for"
  echo "         the fallback (kubectl port-forward + host.docker.internal) if"
  echo "         the preflight check below fails."
fi

echo "==> Preflight: checking Notifications is reachable at $NOTIFICATIONS_URL"
if curl -sf --max-time 5 "$NOTIFICATIONS_URL/health" >/dev/null; then
  echo "    OK — Notifications /health responded."
else
  echo "ERROR: Could not reach $NOTIFICATIONS_URL/health from this machine."
  echo "  This means the Lambda (which runs in the same Docker networking"
  echo "  context as this script) will not be able to reach Notifications either."
  echo "  Checklist:"
  echo "    1. Is the notifications-external Service applied?"
  echo "       kubectl get svc notifications-external"
  echo "    2. Is the notifications pod Running and Ready?"
  echo "       kubectl get pods -l app=notifications"
  echo "    3. Does 'curl $NOTIFICATIONS_URL/health' work from a plain terminal"
  echo "       on this machine right now?"
  echo "    4. If using WSL2: run this script FROM THE SAME WSL2 distro that"
  echo "       runs 'minikube start', not from Windows PowerShell/cmd directly."
  echo "    5. See README.md 'Networking: LocalStack <-> Kubernetes' for the"
  echo "       kubectl port-forward fallback if NodePort reachability is blocked"
  echo "       (e.g. by a VPN or corporate firewall)."
  exit 1
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
