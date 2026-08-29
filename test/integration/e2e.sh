#!/usr/bin/env bash
# CloudCrafter — full capstone end-to-end demonstration.
#
# This is the complete flow referenced by EVIDENCE.md:
#   Login -> receive JWT -> authenticated API request
#     -> create event -> create ticket -> receipt uploaded to S3
#     -> S3 event triggers Lambda -> Lambda calls Notifications
#     -> notification appears -> Prometheus has scraped metrics for the run
#
# This extends test/verify-task1.sh's proven S3->Lambda->Notifications
# checks (see that script for the deeper retry/CloudWatch-log-based
# verification of that specific chain) with the additional steps Task
# 1's script didn't cover: the JWT-protected request, event creation, and
# a Prometheus check — so this is the single script to run for the full
# capstone demo, while verify-task1.sh remains the focused Task 1 check.
#
# Usage:
#   ./test/integration/e2e.sh
#
# Assumes: everything from test/verify-task1.sh's assumptions (Minikube
# running, Task 1 manifests + Ingress applied, LocalStack + Lambda deployed)
# PLUS: observability/ manifests applied (`kubectl apply -f observability/`,
# in that order: prometheus/, then grafana/, then loki/).

set -uo pipefail

BASE_URL="${BASE_URL:-http://cloudcrafter.local}"
PROMETHEUS_URL="${PROMETHEUS_URL:-}"  # optional — see step 8
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

retry_until() {
  local description="$1"
  local attempts="$2"
  local delay="$3"
  shift 3
  local i
  for i in $(seq 1 "$attempts"); do
    if "$@" >/tmp/e2e-retry-output 2>&1; then
      return 0
    fi
    echo "    ...($description) attempt $i/$attempts, waiting ${delay}s"
    sleep "$delay"
  done
  sed 's/^/    | /' /tmp/e2e-retry-output
  return 1
}

echo "== Step 1: Login -> receive JWT =="
LOGIN_RESPONSE=$(curl -s -X POST "$BASE_URL/api/users/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"demo","password":"demo123"}')
TOKEN=$(echo "$LOGIN_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).token' 2>/dev/null || echo "")
check "Login returned a JWT" "$([ -n "$TOKEN" ] && [ "$TOKEN" != "undefined" ] && echo 0 || echo 1)"

echo
echo "== Step 2: Authenticated API request (GET /protected with the JWT) =="
PROTECTED_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/api/users/protected" \
  -H "Authorization: Bearer $TOKEN")
check "GET /protected with the JWT returned 200" "$([ "$PROTECTED_CODE" = "200" ] && echo 0 || echo 1)"

echo
echo "== Step 3: Create an event =="
EVENT_RESPONSE=$(curl -s -X POST "$BASE_URL/api/events/events" \
  -H "Content-Type: application/json" \
  -d '{"name":"E2E Demo Event","date":"2027-01-01","venue":"Demo Hall"}')
EVENT_ID=$(echo "$EVENT_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).id' 2>/dev/null || echo "")
check "Event created with an id" "$([ -n "$EVENT_ID" ] && [ "$EVENT_ID" != "undefined" ] && echo 0 || echo 1)"

echo
echo "== Step 4: Create a ticket for that event (uploads receipt to S3 — required to succeed) =="
TICKET_HTTP_CODE=$(curl -s -o /tmp/e2e-ticket-response -w "%{http_code}" \
  -X POST "$BASE_URL/api/tickets/tickets" \
  -H "Content-Type: application/json" \
  -d "{\"eventId\":$EVENT_ID,\"userId\":1}")
TICKET_RESPONSE=$(cat /tmp/e2e-ticket-response)
check "Ticket created (201, S3 upload required to succeed)" "$([ "$TICKET_HTTP_CODE" = "201" ] && echo 0 || echo 1)"
RECEIPT_ID=$(echo "$TICKET_RESPONSE" | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).receiptId' 2>/dev/null || echo "")
check "Ticket response includes a receiptId" "$([ -n "$RECEIPT_ID" ] && [ "$RECEIPT_ID" != "undefined" ] && echo 0 || echo 1)"

if [ -z "$RECEIPT_ID" ] || [ "$RECEIPT_ID" = "undefined" ]; then
  echo "  No receiptId obtained — skipping the S3/Lambda/notification chain (steps 5-7)."
else
  echo
  echo "== Step 5: Receipt exists in LocalStack S3 =="
  check_s3_object() {
    awslocal s3api list-objects-v2 --bucket "$S3_BUCKET" \
      --query "Contents[?contains(Key, '$RECEIPT_ID')]" --output text 2>&1 | grep -q "$RECEIPT_ID"
  }
  retry_until "S3 object for $RECEIPT_ID" 5 2 check_s3_object
  check "Receipt object found in s3://$S3_BUCKET" "$?"

  echo
  echo "== Steps 6-7: S3 event triggers Lambda -> Lambda calls Notifications -> notification appears =="
  echo "  (no manual Lambda invocation, no manual POST /notify)"
  check_notification_visible() {
    curl -s "$BASE_URL/api/notifications/notifications" | grep -q "$RECEIPT_ID"
  }
  retry_until "notification for $RECEIPT_ID" 15 3 check_notification_visible
  check "Notification for receiptId '$RECEIPT_ID' appeared automatically" "$?"
fi

echo
echo "== Step 8: Prometheus has scraped metrics from the services used above =="
if [ -z "$PROMETHEUS_URL" ]; then
  echo "  PROMETHEUS_URL not set — attempting port-forward to the in-cluster Prometheus Service."
  kubectl port-forward svc/prometheus 9090:9090 >/tmp/e2e-portforward.log 2>&1 &
  PF_PID=$!
  sleep 3
  PROMETHEUS_URL="http://localhost:9090"
  trap 'kill $PF_PID 2>/dev/null' EXIT
fi
check_prometheus_has_data() {
  curl -s "$PROMETHEUS_URL/api/v1/query?query=http_requests_total" | grep -q '"value"'
}
retry_until "Prometheus has scraped data" 5 3 check_prometheus_has_data
check "Prometheus has at least one http_requests_total sample" "$?"

rm -f /tmp/e2e-retry-output /tmp/e2e-ticket-response

echo
echo "======================================"
echo " CloudCrafter E2E demo: $PASS passed, $FAIL failed"
echo "======================================"

[ "$FAIL" = "0" ]
