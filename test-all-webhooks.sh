#!/bin/bash
# Exhaustive webhook end-to-end test.
#
# Discovers every seeded event type from the webhook-service, registers one
# listener endpoint per scope prefix (merchant_of_record, treasury), subscribes
# each to its relevant types, then fires every selected event type via
# POST /internal/webhooks/trigger and asserts the webhooks-listener receives
# exactly one delivery per event type with a valid signature.
#
# Requires: webhook-service on :8000 and webhooks-listener on :9000 (as started
# by ../start-local.sh). Requires `jq` and `curl` on PATH.
#
# Usage:
#   ./test-all-webhooks.sh                        # all projects (default)
#   ./test-all-webhooks.sh --project turnstay_api # only merchant_of_record.* types
#   ./test-all-webhooks.sh --project treasury     # only treasury.* types
#   ./test-all-webhooks.sh --project all          # both (same as default)
#   ./test-all-webhooks.sh -h|--help              # show this help
#
# Project -> event-type prefix map:
#   turnstay_api -> merchant_of_record.*
#   treasury     -> treasury.*

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

WEBHOOK_URL="${WEBHOOK_URL:-http://localhost:8000}"
LISTENER_URL="${LISTENER_URL:-http://localhost:9000}"
AUTH="${AUTH:-Bearer dev-token}"
RUN_ID="e2e_$(date +%s)_$$"
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-60}"
TRIGGER_DELAY_MS="${TRIGGER_DELAY_MS:-50}"

PROJECT="all"

usage() {
  sed -n '2,23p' "$0" | sed 's/^#\s\{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    --project=*)
      PROJECT="${1#--project=}"
      shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$PROJECT" in
  turnstay_api|treasury|all) ;;
  *)
    echo "error: --project must be one of: turnstay_api, treasury, all (got: '$PROJECT')" >&2
    exit 2
    ;;
esac

INCLUDE_MOR=0; INCLUDE_TRE=0
case "$PROJECT" in
  turnstay_api) INCLUDE_MOR=1 ;;
  treasury)     INCLUDE_TRE=1 ;;
  all)          INCLUDE_MOR=1; INCLUDE_TRE=1 ;;
esac

command -v jq >/dev/null || { echo "error: jq not found on PATH"; exit 2; }
command -v curl >/dev/null || { echo "error: curl not found on PATH"; exit 2; }

# Pretty print helpers
hr() { printf '%s\n' "============================================================"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

hr
echo "  Webhook E2E — exhaustive coverage"
hr
echo "  webhook-service: $WEBHOOK_URL"
echo "  listener:        $LISTENER_URL"
echo "  project:         $PROJECT"
echo "  run_id:          $RUN_ID"
echo ""

# --- Step A: reset listener state ---
log "resetting listener state"
curl -fsS -X DELETE "$LISTENER_URL/events" > /dev/null

# --- Step B: discover seeded event types ---
log "fetching seeded event types from webhook-service"
ALL_TYPES_JSON=$(curl -fsS -H "Authorization: $AUTH" "$WEBHOOK_URL/webhooks/event-types")
ALL_TYPES=$(echo "$ALL_TYPES_JSON" | jq -r '.[].name' | sort -u)

# Bucket by top-level scope prefix (first dotted segment)
declare -a MOR_TYPES=()
declare -a TREASURY_TYPES=()
declare -a UNKNOWN_TYPES=()
while IFS= read -r t; do
  [ -z "$t" ] && continue
  case "$t" in
    merchant_of_record.*) MOR_TYPES+=("$t") ;;
    treasury.*)           TREASURY_TYPES+=("$t") ;;
    *)                    UNKNOWN_TYPES+=("$t") ;;
  esac
done <<< "$ALL_TYPES"

N_MOR_ALL=${#MOR_TYPES[@]}
N_TRE_ALL=${#TREASURY_TYPES[@]}
N_UNK=${#UNKNOWN_TYPES[@]}

# Drop types for projects not selected
if [ "$INCLUDE_MOR" -eq 0 ]; then MOR_TYPES=(); fi
if [ "$INCLUDE_TRE" -eq 0 ]; then TREASURY_TYPES=(); fi

N_MOR=${#MOR_TYPES[@]}
N_TRE=${#TREASURY_TYPES[@]}
N_TOTAL=$(( N_MOR + N_TRE ))

echo "  Discovered event types (seeded: $((N_MOR_ALL + N_TRE_ALL + N_UNK))):"
printf "    merchant_of_record.*  %-4d%s\n" "$N_MOR_ALL" "$([ "$INCLUDE_MOR" -eq 0 ] && echo "  (skipped, project=$PROJECT)")"
printf "    treasury.*            %-4d%s\n" "$N_TRE_ALL" "$([ "$INCLUDE_TRE" -eq 0 ] && echo "  (skipped, project=$PROJECT)")"
[ "$N_UNK" -gt 0 ] && echo "    (other)               $N_UNK  ${UNKNOWN_TYPES[*]}"
echo ""
echo "  Selected for this run: $N_TOTAL"
echo ""

if [ "$N_TOTAL" -eq 0 ]; then
  echo "error: no event types selected for project='$PROJECT' — nothing to test"
  exit 1
fi

# --- Step C: register endpoints (one per scope) ---
register_endpoint() {
  # $1 = scope_id, $2 = listener path (e.g. /webhooks/e2e_mor)
  local scope_id="$1" listener_path="$2"
  local resp
  resp=$(curl -fsS -X POST "$WEBHOOK_URL/webhooks/endpoints" \
    -H "Content-Type: application/json" \
    -H "Authorization: $AUTH" \
    -d "{\"url\": \"${LISTENER_URL}${listener_path}\", \"scope_id\": \"${scope_id}\"}")
  echo "$resp"
}

subscribe() {
  # $1 = endpoint_id, $2 = JSON array of event type names
  local id="$1" names_json="$2"
  curl -fsS -X POST "$WEBHOOK_URL/webhooks/endpoints/${id}/subscriptions" \
    -H "Content-Type: application/json" \
    -H "Authorization: $AUTH" \
    -d "{\"event_type_names\": ${names_json}}" > /dev/null
}

MOR_PATH="/webhooks/${RUN_ID}_mor"
TRE_PATH="/webhooks/${RUN_ID}_tre"
MOR_SCOPE="merchant_of_record:${RUN_ID}"
TRE_SCOPE="treasury:${RUN_ID}"

MOR_ID=""; MOR_SECRET=""
TRE_ID=""; TRE_SECRET=""

if [ "$N_MOR" -gt 0 ]; then
  log "registering MOR endpoint (scope=$MOR_SCOPE path=$MOR_PATH)"
  RESP=$(register_endpoint "$MOR_SCOPE" "$MOR_PATH")
  MOR_ID=$(echo "$RESP" | jq -r '.id')
  MOR_SECRET=$(echo "$RESP" | jq -r '.secret')
  if [ -z "$MOR_ID" ] || [ "$MOR_ID" = "null" ]; then
    echo "error: failed to register MOR endpoint: $RESP"; exit 1
  fi
  log "  endpoint_id=$MOR_ID  secret=${MOR_SECRET:0:16}..."

  NAMES_JSON=$(printf '%s\n' "${MOR_TYPES[@]}" | jq -R . | jq -s .)
  log "subscribing MOR endpoint to $N_MOR event types"
  subscribe "$MOR_ID" "$NAMES_JSON"
fi

if [ "$N_TRE" -gt 0 ]; then
  log "registering treasury endpoint (scope=$TRE_SCOPE path=$TRE_PATH)"
  RESP=$(register_endpoint "$TRE_SCOPE" "$TRE_PATH")
  TRE_ID=$(echo "$RESP" | jq -r '.id')
  TRE_SECRET=$(echo "$RESP" | jq -r '.secret')
  if [ -z "$TRE_ID" ] || [ "$TRE_ID" = "null" ]; then
    echo "error: failed to register treasury endpoint: $RESP"; exit 1
  fi
  log "  endpoint_id=$TRE_ID  secret=${TRE_SECRET:0:16}..."

  NAMES_JSON=$(printf '%s\n' "${TREASURY_TYPES[@]}" | jq -R . | jq -s .)
  log "subscribing treasury endpoint to $N_TRE event types"
  subscribe "$TRE_ID" "$NAMES_JSON"
fi

# --- Step D: install per-path secrets in the listener via config.json + restart ---
log "installing per-path signing secrets into listener config.json"
# Build config.json via jq so we avoid string-escaping bugs.
CFG_ARGS=()
[ -n "$MOR_SECRET" ] && CFG_ARGS+=(--arg mor_path "$MOR_PATH" --arg mor_secret "$MOR_SECRET")
[ -n "$TRE_SECRET" ] && CFG_ARGS+=(--arg tre_path "$TRE_PATH" --arg tre_secret "$TRE_SECRET")
jq -n "${CFG_ARGS[@]}" '
  {
    endpoints: (
      (if $ARGS.named.mor_path then {($ARGS.named.mor_path): $ARGS.named.mor_secret} else {} end) +
      (if $ARGS.named.tre_path then {($ARGS.named.tre_path): $ARGS.named.tre_secret} else {} end)
    )
  }
' > "$SCRIPT_DIR/config.json"

log "restarting listener so config.json is re-read"
LISTENER_PIDS=$(lsof -ti :9000 2>/dev/null || true)
if [ -n "$LISTENER_PIDS" ]; then
  echo "$LISTENER_PIDS" | xargs kill -9 2>/dev/null || true
  sleep 1
fi
(
  cd "$SCRIPT_DIR"
  nohup .venv/bin/python -m uvicorn listener:app --port 9000 \
    > "$SCRIPT_DIR/.listener.out" 2>&1 &
  disown
)
# wait for listener to come back
for i in $(seq 1 20); do
  if curl -fsS "$LISTENER_URL/" > /dev/null 2>&1; then
    log "  listener ready"
    break
  fi
  sleep 0.25
done

# --- Step E: fire every event type with the matching scope ---
trigger_event() {
  # $1 = event_type, $2 = scope_id
  local et="$1" scope="$2"
  local nonce="e2e_$(echo "$et" | tr '.' '_')_$$"
  curl -fsS -X POST "$WEBHOOK_URL/internal/webhooks/trigger" \
    -H "Content-Type: application/json" \
    -H "Authorization: $AUTH" \
    -d "{
      \"event_type\": \"${et}\",
      \"name\": \"E2E ${et}\",
      \"scope_id\": \"${scope}\",
      \"account_id\": \"1\",
      \"data\": {
        \"object\": {
          \"id\": \"${nonce}\",
          \"status\": \"processed\",
          \"billing_amount\": 1000,
          \"billing_currency\": \"ZAR\"
        }
      }
    }" > /dev/null
}

log "firing $N_TOTAL events (inter-trigger delay ${TRIGGER_DELAY_MS}ms)"
# sleep fraction of a second between triggers — rate-limit our firing so the
# webhook-service's async dispatcher has a chance to keep up without dropping.
DELAY_S=$(awk -v ms="$TRIGGER_DELAY_MS" 'BEGIN{ printf "%.3f", ms/1000 }')
FIRED=0
for t in "${MOR_TYPES[@]}"; do
  trigger_event "$t" "$MOR_SCOPE"
  FIRED=$((FIRED + 1))
  sleep "$DELAY_S"
done
for t in "${TREASURY_TYPES[@]}"; do
  trigger_event "$t" "$TRE_SCOPE"
  FIRED=$((FIRED + 1))
  sleep "$DELAY_S"
done
log "  fired $FIRED events"

# --- Step F: poll listener for deliveries ---
log "polling listener for deliveries (timeout ${POLL_TIMEOUT_S}s)"
START=$(date +%s)
RECEIVED=0
while :; do
  RECEIVED=$(curl -fsS "$LISTENER_URL/events?format=json&limit=0" | jq 'length')
  if [ "$RECEIVED" -ge "$N_TOTAL" ]; then
    break
  fi
  NOW=$(date +%s)
  if [ $((NOW - START)) -ge "$POLL_TIMEOUT_S" ]; then
    break
  fi
  sleep 1
done
DURATION=$(( $(date +%s) - START ))
log "  received $RECEIVED / $N_TOTAL after ${DURATION}s"

# --- Step G: assertions + detailed report ---
echo ""
hr
EVENTS_JSON=$(curl -fsS "$LISTENER_URL/events?format=json&limit=0")

# event_type -> count received
RECEIVED_BY_TYPE=$(echo "$EVENTS_JSON" | jq -r '.[] | .type' | sort | uniq -c | awk '{printf "%s\t%s\n", $2, $1}')

# Count valid / invalid / unverified signatures
VALID_SIGS=$(echo "$EVENTS_JSON" | jq '[.[] | select(.signature == "valid")] | length')
INVALID_SIGS=$(echo "$EVENTS_JSON" | jq '[.[] | select(.signature == "INVALID")] | length')
UNVERIFIED_SIGS=$(echo "$EVENTS_JSON" | jq '[.[] | select(.signature == "unverified")] | length')

echo "  Summary: $FIRED fired, $RECEIVED received, $VALID_SIGS signatures valid, $INVALID_SIGS invalid, $UNVERIFIED_SIGS unverified"
hr
echo ""

# Per-event-type pass/fail
PASS=0
FAIL=0
printf "  %-60s %s\n" "EVENT TYPE" "STATUS"
for t in "${MOR_TYPES[@]}" "${TREASURY_TYPES[@]}"; do
  COUNT=$(echo "$RECEIVED_BY_TYPE" | awk -v et="$t" -F'\t' '$1==et {print $2}')
  COUNT="${COUNT:-0}"
  if [ "$COUNT" -eq 1 ]; then
    printf "  %-60s %s\n" "$t" "PASS"
    PASS=$((PASS + 1))
  else
    printf "  %-60s %s (received %s)\n" "$t" "FAIL" "$COUNT"
    FAIL=$((FAIL + 1))
  fi
done
echo ""
hr
echo "  Result: $PASS pass / $FAIL fail  (expected: $N_TOTAL)"
echo "  Signatures: valid=$VALID_SIGS invalid=$INVALID_SIGS unverified=$UNVERIFIED_SIGS"
hr

if [ "$FAIL" -ne 0 ] || [ "$RECEIVED" -ne "$N_TOTAL" ]; then
  echo ""
  echo "FAIL"
  exit 1
fi

if [ "$VALID_SIGS" -ne "$RECEIVED" ]; then
  echo ""
  echo "WARN: not all signatures valid ($VALID_SIGS / $RECEIVED). Count passed but signature verification partial."
  exit 3
fi

echo ""
echo "PASS"
exit 0
