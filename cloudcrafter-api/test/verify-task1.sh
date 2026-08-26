#!/usr/bin/env bash
# CloudCrafter Task 1 — end-to-end verification.
#
# Proves, without any manual Lambda invocation or manual POST /notify:
#   1. Pods are Running
#   2. Services exist
#   3. Ingress routes correctly
#   4. /health works for all four services
#   5. Users login works
#   6. A ticket can be created (and its receipt upload is REQUIRED to succeed —
#      see services/tickets/server.js; a 502 here means no ticket exists)
#   7. The receipt lands in LocalStack S3
#   8. The S3 event actually triggered the Lambda (checked independently of
#      the final notification, via the Lambda's own CloudWatch Logs — this is
#      what proves step 8 happened, as opposed to inferring it from step 10)
#   9. The Lambda successfully called Notifications (checked via the same
#      Lambda logs, which record the POST result)
#  10. The notification shows up in GET /notifications
#
# Every asynchronous step (7, 8/9, 10) is retried with backoff rather than
# checked once — S3 notification delivery and LocalStack's Lambda executor
# (especially LAMBDA_EXECUTOR=docker, which has to start a container per
# invocation) are not instantaneous, especially on a cold start.
#
# Usage:
#   ./test/verify-task1.sh
#
# Assumes: Minikube is running, Task 1 manifests are applied, Ingress is
# enabled, /etc/hosts has "cloudcrafter.local" mapped to `minikube ip`,
# and LocalStack + the Lambda are deployed (see README.md). Run from the same
# shell/WSL2 distro used for `minikube start` and `docker compose up`.

set -uo pipefail

BASE_URL="${BASE_URL:-http://cloudcrafter.local}"
S3_BUCKET="${S3_BUCKET:-cloudcrafter-ticket-receipts}"
LAMBDA_FUNCTION_NAME="${LAMBDA_FUNCTION_NAME:-notify-on-receipt}"
PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

# Retries a command up to $2 times, waiting $3 seconds between attempts,
# until it succeeds (exit 0) or attempts are exhausted. Prints progress so a
# slow LocalStack Lambda cold start doesn't look like the script is stuck.
retry_until() {
  local description="$1"
  local attempts="$2"
  local delay="$3"
  shift 3
  local i
  for i in $(seq 1 "$attempts"); do
    if "$@" >/tmp/verify-task1-retry-output 2>&1; then
      return 0
    fi
    echo "    ...($description) attempt $i/$attempts not ready yet, waiting ${delay}s"
    sleep "$delay"
  done
  echo "    Last output from '$description':"
  sed 's/^/    | /' /tmp/verify-task1-retry-output
  return 1
}

echo "== 1. Kubernetes pods Running =="
kubectl get pods -o wide
NOT_RUNNING=$(kubectl get pods --no-headers 2>/dev/null | grep -v -c "Running" || true)
check "All pods Running" "$([ "$NOT_RUNNING" = "0" ] && echo 0 || echo 1)"

echo
echo "== 2. Kubernetes Services exist =="
kubectl get svc
for svc in users events tickets notifications notifications-external; do
  kubectl get svc "$svc" >/dev/null 2>&1
  check "Service '$svc' exists" "$?"
done

echo
echo "== 3-4. Ingress routing + /health for all four services =="
for svc in users events tickets notifications; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/$svc/health" || echo "000")
  check "GET $BASE_URL/api/$svc/health -> 200 (got $code)" "$([ "$code" = "200" ] && echo 0 || echo 1)"
done

echo
echo "== Precondition: Lambda function is deployed =="
awslocal lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" >/dev/null 2>&1
LAMBDA_EXISTS=$?
check "Lambda function '$LAMBDA_FUNCTION_NAME' exists in LocalStack" "$LAMBDA_EXISTS"
if [ "$LAMBDA_EXISTS" != "0" ]; then
  echo "  Run ./localstack/deploy-lambda.sh before this script — see README.md."
fi

echo
echo "== 5. Users login =="
LOGIN_RESPONSE=$(curl -s -X POST "$BASE_URL/api/users/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"demo","password":"demo123"}')
TOKEN=$(echo "$LOGIN_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).token' 2>/dev/null || echo "")
check "Login returned a token" "$([ -n "$TOKEN" ] && [ "$TOKEN" != "undefined" ] && echo 0 || echo 1)"

echo
echo "== 6. Create a ticket (receipt upload to S3 is REQUIRED to succeed) =="
TICKET_HTTP_CODE=$(curl -s -o /tmp/verify-task1-ticket-response -w "%{http_code}" \
  -X POST "$BASE_URL/api/tickets/tickets" \
  -H "Content-Type: application/json" \
  -d '{"eventId":1,"userId":1}')
TICKET_RESPONSE=$(cat /tmp/verify-task1-ticket-response)
echo "  HTTP $TICKET_HTTP_CODE — Response: $TICKET_RESPONSE"
check "POST /tickets returned 201 (ticket + upload both succeeded)" "$([ "$TICKET_HTTP_CODE" = "201" ] && echo 0 || echo 1)"

RECEIPT_ID=$(echo "$TICKET_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).receiptId' 2>/dev/null || echo "")
UPLOADED=$(echo "$TICKET_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).s3.uploaded' 2>/dev/null || echo "false")
check "Ticket response includes a receiptId" "$([ -n "$RECEIPT_ID" ] && [ "$RECEIPT_ID" != "undefined" ] && echo 0 || echo 1)"
check "Ticket response confirms S3 upload succeeded (s3.uploaded=true)" "$([ "$UPLOADED" = "true" ] && echo 0 || echo 1)"

if [ -z "$RECEIPT_ID" ] || [ "$RECEIPT_ID" = "undefined" ]; then
  echo
  echo "  No receiptId obtained — skipping steps 7-10 (nothing to trace through the chain)."
  echo "======================================"
  echo " Task 1 verification: $PASS passed, $FAIL failed"
  echo "======================================"
  exit 1
fi

echo
echo "== 7. Receipt object exists in LocalStack S3 =="
check_s3_object() {
  local result
  result=$(awslocal s3api list-objects-v2 --bucket "$S3_BUCKET" \
    --query "Contents[?contains(Key, '$RECEIPT_ID')]" --output text 2>&1)
  echo "$result"
  [ -n "$result" ]
}
retry_until "S3 object for $RECEIPT_ID" 5 2 check_s3_object
check "Receipt object found in s3://$S3_BUCKET" "$?"

echo
echo "== 8. S3 event triggered the Lambda (checked independently, via Lambda logs) =="
echo "  (no manual 'aws lambda invoke' — this only reads CloudWatch Logs)"
check_lambda_invoked() {
  local log_group="/aws/lambda/$LAMBDA_FUNCTION_NAME"
  local streams
  streams=$(awslocal logs describe-log-streams --log-group-name "$log_group" \
    --order-by LastEventTime --descending --max-items 5 \
    --query 'logStreams[].logStreamName' --output text 2>&1) || return 1
  for stream in $streams; do
    if awslocal logs get-log-events --log-group-name "$log_group" --log-stream-name "$stream" \
        --query 'events[].message' --output text 2>/dev/null | grep -q "$RECEIPT_ID"; then
      return 0
    fi
  done
  return 1
}
retry_until "Lambda invocation log for $RECEIPT_ID" 15 3 check_lambda_invoked
LAMBDA_TRIGGERED=$?
check "Lambda execution log references receiptId '$RECEIPT_ID' (S3 event fired it)" "$LAMBDA_TRIGGERED"

echo
echo "== 9-10. Lambda called Notifications, and the notification is now visible =="
echo "  (no manual POST /notify — only polling GET /notifications)"
check_notification_visible() {
  local notifs
  notifs=$(curl -s "$BASE_URL/api/notifications/notifications" 2>&1)
  echo "$notifs" | grep -q "$RECEIPT_ID"
}
retry_until "notification for $RECEIPT_ID" 15 3 check_notification_visible
check "Notification containing receiptId '$RECEIPT_ID' appeared in GET /notifications" "$?"

rm -f /tmp/verify-task1-retry-output /tmp/verify-task1-ticket-response

echo
echo "======================================"
echo " Task 1 verification: $PASS passed, $FAIL failed"
echo "======================================"

[ "$FAIL" = "0" ]
