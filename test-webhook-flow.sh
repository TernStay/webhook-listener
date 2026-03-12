#!/bin/bash
# Test the webhook flow: register endpoint, subscribe to events, trigger event.
# Requires webhook-service (port 8000) and this listener (port 9000) to be running.
#
# Usage: ./test-webhook-flow.sh
#   (run from the webhooks_listener directory)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

WEBHOOK_URL="${WEBHOOK_URL:-http://localhost:8000}"
LISTENER_URL="${LISTENER_URL:-http://localhost:9000}"
AUTH="${AUTH:-Bearer dev-token}"

echo "========================================="
echo "  Webhook Flow Test"
echo "========================================="
echo "  Webhook Service: $WEBHOOK_URL"
echo "  Listener:        $LISTENER_URL"
echo ""

# 1. Register endpoint
echo "[1/4] Registering webhook endpoint..."
RESP=$(curl -s -X POST "$WEBHOOK_URL/webhooks/endpoints" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -d "{
    \"url\": \"$LISTENER_URL/webhooks\",
    \"scope_id\": \"merchant_of_record:test_company\"
  }")

if echo "$RESP" | grep -q '"id"'; then
  ENDPOINT_ID=$(echo "$RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  SECRET=$(echo "$RESP" | grep -o '"secret":"[^"]*"' | cut -d'"' -f4)
  echo "  Endpoint ID: $ENDPOINT_ID"
  echo "  Secret: ${SECRET:0:20}..."
  echo "  (Add this secret to config.json or .env for signature verification)"
else
  echo "  Failed: $RESP"
  exit 1
fi

# 2. Subscribe to events
echo ""
echo "[2/4] Subscribing to events..."
SUB_RESP=$(curl -s -X POST "$WEBHOOK_URL/webhooks/endpoints/$ENDPOINT_ID/subscriptions" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -d '{
    "event_type_names": [
      "merchant_of_record.payment_intent.succeeded",
      "merchant_of_record.refund.created",
      "merchant_of_record.refund.pending",
      "merchant_of_record.refund.completed",
      "merchant_of_record.refund.failed",
      "merchant_of_record.chargeback.created",
      "merchant_of_record.payout.completed"
    ]
  }')

if echo "$SUB_RESP" | grep -q '"event_type_names"'; then
  echo "  Subscribed."
else
  echo "  Response: $SUB_RESP"
fi

# 3. Trigger test event (scope_id/account_id must match endpoint for delivery)
echo ""
echo "[3/4] Triggering test event..."
TRIGGER_RESP=$(curl -s -X POST "$WEBHOOK_URL/internal/webhooks/trigger" \
  -H "Content-Type: application/json" \
  -d '{
    "event_type": "merchant_of_record.payment_intent.succeeded",
    "name": "Test payment succeeded",
    "scope_id": "merchant_of_record:test_company",
    "account_id": "2",
    "data": {
      "object": {
        "id": "pi_test_123",
        "object": "payment_intent",
        "status": "processed",
        "billing_amount": 50000,
        "billing_currency": "ZAR",
        "company_id": 1,
        "account_id": 2
      }
    }
  }')

if echo "$TRIGGER_RESP" | grep -q '"event_id"'; then
  EVENT_ID=$(echo "$TRIGGER_RESP" | grep -o '"event_id":[0-9]*' | cut -d: -f2)
  echo "  Event triggered! event_id=$EVENT_ID"
else
  echo "  Response: $TRIGGER_RESP"
fi

# 4. Isolation test: company_B must NOT receive company_A's event
# Use unique scope_ids per run so we don't accumulate endpoints from previous runs
echo ""
echo "[4/4] Running company isolation test..."
curl -s -X DELETE "$LISTENER_URL/events" > /dev/null

RUN_ID="run_$$_$(date +%s)"
SCOPE_A="merchant_of_record:company_A_${RUN_ID}"
SCOPE_B="merchant_of_record:company_B_${RUN_ID}"

# Register company_A endpoint
RESP_A=$(curl -s -X POST "$WEBHOOK_URL/webhooks/endpoints" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -d "{
    \"url\": \"$LISTENER_URL/webhooks/company_a\",
    \"scope_id\": \"$SCOPE_A\"
  }")
ENDPOINT_A=$(echo "$RESP_A" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

# Register company_B endpoint
RESP_B=$(curl -s -X POST "$WEBHOOK_URL/webhooks/endpoints" \
  -H "Content-Type: application/json" \
  -H "Authorization: $AUTH" \
  -d "{
    \"url\": \"$LISTENER_URL/webhooks/company_b\",
    \"scope_id\": \"$SCOPE_B\"
  }")
ENDPOINT_B=$(echo "$RESP_B" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

# Subscribe both to merchant_of_record.payment_intent.succeeded
curl -s -X POST "$WEBHOOK_URL/webhooks/endpoints/$ENDPOINT_A/subscriptions" \
  -H "Content-Type: application/json" -H "Authorization: $AUTH" \
  -d '{"event_type_names": ["merchant_of_record.payment_intent.succeeded"]}' > /dev/null
curl -s -X POST "$WEBHOOK_URL/webhooks/endpoints/$ENDPOINT_B/subscriptions" \
  -H "Content-Type: application/json" -H "Authorization: $AUTH" \
  -d '{"event_type_names": ["merchant_of_record.payment_intent.succeeded"]}' > /dev/null

# Trigger event for company_A only (use same scope_id as endpoint A)
curl -s -X POST "$WEBHOOK_URL/internal/webhooks/trigger" \
  -H "Content-Type: application/json" \
  -d "{
    \"event_type\": \"merchant_of_record.payment_intent.succeeded\",
    \"name\": \"Company A payment\",
    \"scope_id\": \"$SCOPE_A\",
    \"account_id\": \"1\",
    \"data\": {\"object\": {\"id\": \"pi_company_a_1\", \"status\": \"processed\"}}
  }" > /dev/null

sleep 2
COUNT_A=$(curl -s "$LISTENER_URL/events/company_a" | grep -o '"event_id"' | wc -l | tr -d ' ')
COUNT_B=$(curl -s "$LISTENER_URL/events/company_b" | grep -o '"event_id"' | wc -l | tr -d ' ')

if [ "$COUNT_A" -eq 1 ] && [ "$COUNT_B" -eq 0 ]; then
  echo "  PASS: company_A received 1 event, company_B received 0 (isolation OK)"
else
  echo "  FAIL: company_A=$COUNT_A, company_B=$COUNT_B (expected A=1, B=0)"
  exit 1
fi

echo ""
echo "========================================="
echo "  Done! Check the webhook listener logs"
echo "  for the delivered event."
echo "========================================="
