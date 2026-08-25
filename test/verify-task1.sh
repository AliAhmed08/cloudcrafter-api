#!/usr/bin/env bash
# CloudCrafter Task 1 — end-to-end verification.
#
# Proves, without any manual Lambda invocation or manual POST /notify:
#   1. Pods are Running
#   2. Services exist
#   3. Ingress routes correctly
#   4. /health works for all four services
#   5. Users login works
#   6. A ticket can be created
#   7. The receipt lands in LocalStack S3
#   8. The S3 event triggers the Lambda
#   9. The Lambda calls Notifications
#  10. The notification shows up in GET /notifications
#
# Usage:
#   ./test/verify-task1.sh
#
# Assumes: Minikube is running, Task 1 manifests are applied, Ingress is
# enabled, /etc/hosts has "cloudcrafter.local" mapped to `minikube ip`,
# and LocalStack + the Lambda are deployed (see README.md).

set -euo pipefail

BASE_URL="${BASE_URL:-http://cloudcrafter.local}"
S3_BUCKET="${S3_BUCKET:-cloudcrafter-ticket-receipts}"
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

echo "== 1. Kubernetes pods Running =="
kubectl get pods -o wide
NOT_RUNNING=$(kubectl get pods --no-headers | grep -v -c "Running" || true)
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
echo "== 5. Users login =="
LOGIN_RESPONSE=$(curl -s -X POST "$BASE_URL/api/users/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"demo","password":"demo123"}')
TOKEN=$(echo "$LOGIN_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).token' 2>/dev/null || echo "")
check "Login returned a token" "$([ -n "$TOKEN" ] && [ "$TOKEN" != "undefined" ] && echo 0 || echo 1)"

echo
echo "== 6. Create a ticket (triggers S3 upload) =="
TICKET_RESPONSE=$(curl -s -X POST "$BASE_URL/api/tickets/tickets" \
  -H "Content-Type: application/json" \
  -d '{"eventId":1,"userId":1}')
echo "  Response: $TICKET_RESPONSE"
RECEIPT_ID=$(echo "$TICKET_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).receiptId' 2>/dev/null || echo "")
UPLOADED=$(echo "$TICKET_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).s3.uploaded' 2>/dev/null || echo "false")
check "Ticket created with a receiptId" "$([ -n "$RECEIPT_ID" ] && [ "$RECEIPT_ID" != "undefined" ] && echo 0 || echo 1)"
check "Ticket response confirms S3 upload succeeded" "$([ "$UPLOADED" = "true" ] && echo 0 || echo 1)"

echo
echo "== 7. Receipt exists in LocalStack S3 =="
S3_LIST=$(awslocal s3api list-objects-v2 --bucket "$S3_BUCKET" --query "Contents[?contains(Key, '$RECEIPT_ID')]" --output text 2>/dev/null || echo "")
check "Receipt object found in s3://$S3_BUCKET" "$([ -n "$S3_LIST" ] && echo 0 || echo 1)"

echo
echo "== 8-10. Waiting for event-driven Lambda -> Notifications flow =="
echo "  (no manual Lambda invocation, no manual POST /notify)"
FOUND="false"
for i in $(seq 1 10); do
  NOTIFS=$(curl -s "$BASE_URL/api/notifications/notifications")
  if echo "$NOTIFS" | grep -q "$RECEIPT_ID"; then
    FOUND="true"
    break
  fi
  sleep 2
done
check "Notification containing receiptId '$RECEIPT_ID' appeared in GET /notifications" "$([ "$FOUND" = "true" ] && echo 0 || echo 1)"

echo
echo "======================================"
echo " Task 1 verification: $PASS passed, $FAIL failed"
echo "======================================"

[ "$FAIL" = "0" ]
