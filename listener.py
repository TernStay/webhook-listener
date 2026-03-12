"""
Test webhook listener for local development.

Receives webhook deliveries from the webhook-service, verifies signatures,
and logs events in real-time.

Usage:
    pip install fastapi uvicorn python-dotenv
    uvicorn listener:app --port 9000 --reload

Configure signing secrets via:
  - config.json: per-path secrets for multiple endpoints (see config.example.json)
  - WEBHOOK_SECRET env var / .env: fallback for single-endpoint setups
  - POST /configure: set fallback secret at runtime
"""

import hashlib
import hmac
import json
import os
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI, Request, Response

load_dotenv()

app = FastAPI(title="TurnStay Webhook Test Listener")

WEBHOOK_SECRET: str | None = os.getenv("WEBHOOK_SECRET") or None

# Per-path secrets from config.json (path -> secret)
ENDPOINT_SECRETS: dict[str, str] = {}


def _load_config() -> None:
    """Load endpoint secrets from config.json if it exists."""
    global ENDPOINT_SECRETS
    config_path = Path(__file__).parent / "config.json"
    if config_path.exists():
        try:
            with open(config_path) as f:
                data = json.load(f)
            ENDPOINT_SECRETS = data.get("endpoints") or {}
        except Exception as e:
            print(f"[Webhook Listener] Failed to load config.json: {e}")
            ENDPOINT_SECRETS = {}


def get_secret_for_path(path: str) -> str | None:
    """Return the signing secret for a request path. Config takes precedence over env."""
    secret = ENDPOINT_SECRETS.get(path)
    if secret:
        return secret
    return WEBHOOK_SECRET


_load_config()

if ENDPOINT_SECRETS:
    print(f"\n[Webhook Listener] Signature verification ENABLED for {len(ENDPOINT_SECRETS)} endpoint(s) via config.json")
elif WEBHOOK_SECRET:
    print(f"\n[Webhook Listener] Signature verification ENABLED (secret from env/.env)")
else:
    print("\n[Webhook Listener] No secrets configured - signatures will show as 'unverified'. Use config.json or .env")

received_events: list[dict] = []

# Per-company event counts for isolation testing
company_a_events: list[dict] = []
company_b_events: list[dict] = []


def verify_signature(payload: bytes, sig_header: str, secret: str) -> bool:
    try:
        parts = {}
        for item in sig_header.split(","):
            item = item.strip()
            if "=" not in item:
                continue
            k, v = item.split("=", 1)
            parts[k.strip()] = v.strip()

        timestamp = parts.get("t", "")
        expected_sig = parts.get("v1", "")

        to_sign = f"{timestamp}.{payload.decode('utf-8')}"
        computed = hmac.new(
            secret.encode("utf-8"),
            to_sign.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

        return hmac.compare_digest(computed, expected_sig)
    except Exception:
        return False


def _path_to_company_label(path: str) -> str | None:
    """Derive company label from path for known isolation-test endpoints."""
    if path == "/webhooks/company_a":
        return "company_a"
    if path == "/webhooks/company_b":
        return "company_b"
    return None


def _handle_webhook(body: bytes, sig_header: str, path: str) -> dict:
    """Process incoming webhook and return response."""
    try:
        event = json.loads(body)
    except json.JSONDecodeError:
        print("[ERROR] Invalid JSON payload")
        return {"status": 400}

    event_type = event.get("type", "unknown")
    event_id = event.get("id", "?")
    ts = datetime.now().strftime("%H:%M:%S")
    company_label = _path_to_company_label(path)

    secret = get_secret_for_path(path)
    sig_status = "unverified"
    if secret:
        if verify_signature(body, sig_header, secret):
            sig_status = "valid"
        else:
            sig_status = "INVALID"
            print(f"[{ts}] WARNING: Signature verification FAILED for {event_id}")

    data_obj = event.get("data", {}).get("object", event.get("data", {}))
    resource_id = data_obj.get("id", "?") if isinstance(data_obj, dict) else "?"

    company_info = f" [company={company_label}]" if company_label else ""
    print(f"\n{'='*60}")
    print(f"[{ts}] Event received: {event_type}{company_info}")
    print(f"  Event ID:    {event_id}")
    print(f"  Resource ID: {resource_id}")
    print(f"  Signature:   {sig_status}")
    if isinstance(data_obj, dict):
        status = data_obj.get("status")
        if status:
            print(f"  Status:      {status}")
        amount = data_obj.get("billing_amount") or data_obj.get("amount")
        currency = data_obj.get("billing_currency") or data_obj.get("currency")
        if amount:
            print(f"  Amount:      {amount} {currency or ''}")
    print(f"{'='*60}")

    record = {
        "received_at": ts,
        "event_id": event_id,
        "type": event_type,
        "signature": sig_status,
        "data": event,
    }
    if company_label:
        record["company"] = company_label

    received_events.append(record)
    if company_label == "company_a":
        company_a_events.append(record)
    elif company_label == "company_b":
        company_b_events.append(record)

    return {"received": True}


@app.post("/webhooks")
async def receive_webhook_root(request: Request):
    """Default webhook endpoint at /webhooks."""
    body = await request.body()
    sig_header = request.headers.get("Turnstay-Signature", "")
    result = _handle_webhook(body, sig_header, path="/webhooks")
    if result.get("status") == 400:
        return Response(status_code=400)
    return result


@app.post("/webhooks/{path:path}")
async def receive_webhook_path(request: Request, path: str):
    """Webhook endpoint for any sub-path (e.g. /webhooks/company_a, /webhooks/integration_test)."""
    full_path = f"/webhooks/{path}"
    body = await request.body()
    sig_header = request.headers.get("Turnstay-Signature", "")
    result = _handle_webhook(body, sig_header, path=full_path)
    if result.get("status") == 400:
        return Response(status_code=400)
    return result


@app.get("/")
async def index():
    return {
        "service": "TurnStay Webhook Test Listener",
        "received_count": len(received_events),
        "secret_configured": bool(ENDPOINT_SECRETS or WEBHOOK_SECRET),
        "endpoints_configured": list(ENDPOINT_SECRETS.keys()) if ENDPOINT_SECRETS else None,
    }


def _format_event_summary(record: dict, index: int) -> str:
    """Format a single event record as human-readable text."""
    lines = []
    lines.append(f"[{index}] {record.get('received_at', '?')}  {record.get('type', 'unknown')}")
    lines.append(f"    Event ID:    {record.get('event_id', '?')}")
    if record.get("company"):
        lines.append(f"    Company:     {record['company']}")
    lines.append(f"    Signature:   {record.get('signature', '?')}")

    data = record.get("data", {})
    inner = data.get("data", data)
    data_obj = inner.get("object", inner) if isinstance(inner, dict) else {}
    if isinstance(data_obj, dict):
        obj_id = data_obj.get("id")
        if obj_id:
            lines.append(f"    Resource ID: {obj_id}")
        status = data_obj.get("status")
        if status:
            lines.append(f"    Status:      {status}")
        amount = data_obj.get("billing_amount") or data_obj.get("amount")
        currency = data_obj.get("billing_currency") or data_obj.get("currency")
        if amount is not None:
            lines.append(f"    Amount:      {amount} {currency or ''}")

    return "\n".join(lines)


@app.get("/events")
async def list_events(request: Request):
    events = received_events[-50:]
    # Default to human-readable text; use ?format=json for raw JSON
    if request.query_params.get("format") != "json":
        lines = [
            "=" * 60,
            "  TurnStay Webhook Events (last 50)",
            "=" * 60,
            "",
        ]
        if not events:
            lines.append("  No events received yet.")
            lines.append("")
            lines.append("  Trigger events via the webhook service or run ./test-webhook-flow.sh")
        else:
            for i, rec in enumerate(reversed(events), 1):
                lines.append(_format_event_summary(rec, i))
                lines.append("")

        lines.append("=" * 60)
        return Response(
            content="\n".join(lines),
            media_type="text/plain; charset=utf-8",
        )
    return events


@app.get("/events/company_a")
async def list_company_a_events():
    """Events received by company_a endpoint - for isolation test verification."""
    return company_a_events


@app.get("/events/company_b")
async def list_company_b_events():
    """Events received by company_b endpoint - for isolation test verification."""
    return company_b_events


@app.post("/configure")
async def configure(request: Request):
    """Set the fallback webhook secret (used when config.json has no entry for the path)."""
    global WEBHOOK_SECRET
    body = await request.json()
    WEBHOOK_SECRET = body.get("secret")
    if WEBHOOK_SECRET:
        print(f"\n[Webhook Listener] Fallback secret configured: {WEBHOOK_SECRET[:12]}...")
    else:
        print("\n[Webhook Listener] Fallback secret cleared")
    return {"configured": True}


@app.delete("/events")
async def clear_events():
    received_events.clear()
    company_a_events.clear()
    company_b_events.clear()
    return {"cleared": True}
