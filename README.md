# TurnStay Webhook Test Listener

A local development server that receives webhook deliveries from the TurnStay webhook-service, verifies signatures, and logs events in real-time. Use it to test webhook flows without deploying a public endpoint.

## Quick Start

```bash
# 1. Create virtual environment and install dependencies
python -m venv .venv
source .venv/bin/activate   # or .venv\Scripts\activate on Windows
pip install -r requirements.txt

# 2. Configure your endpoint secret(s) — see Configuration below
cp config.example.json config.json
# Edit config.json with your endpoint secrets

# 3. Run the listener
uvicorn listener:app --port 9000 --reload
```

The listener will be available at **http://localhost:9000**.

## Configuration

You can configure signing secrets in two ways:

### Option A: Config file (recommended for multiple endpoints)

Use `config.json` to define **per-path secrets**. This lets you run multiple webhook endpoints locally—each with its own secret—so different event streams can be routed to different "endpoints" during testing.

1. Copy the example config:
   ```bash
   cp config.example.json config.json
   ```

2. Edit `config.json` with your endpoint paths and secrets (this file is gitignored to avoid committing secrets):
   ```json
   {
     "endpoints": {
       "/webhooks": "whsec_your_main_endpoint_secret",
       "/webhooks/company_a": "whsec_company_a_secret",
       "/webhooks/company_b": "whsec_company_b_secret"
     }
   }
   ```

3. Get each secret from the **Dashboard → Webhooks → Endpoint detail → Reveal secret** for the corresponding endpoint URL.

**Path mapping:** The key is the URL path the webhook-service calls. For example, if you register an endpoint with URL `http://localhost:9000/webhooks/company_a`, the path is `/webhooks/company_a`.

### Option B: Environment variable (single endpoint)

For a single endpoint, you can use the `WEBHOOK_SECRET` env var or `.env` file:

```bash
# .env
WEBHOOK_SECRET=whsec_your_secret_here
```

Or:

```bash
export WEBHOOK_SECRET=whsec_your_secret_here
uvicorn listener:app --port 9000 --reload
```

**Precedence:** For each request path, the listener looks up the secret in this order:
1. `config.json` — if the path has an entry in `endpoints`
2. `WEBHOOK_SECRET` from `.env` or env var — fallback when `config.json` doesn't exist or doesn't have that path

**Note:** `config.json` does not exist by default—only `config.example.json` (a template) is in the repo. If you haven't created `config.json`, the listener uses `.env` / `WEBHOOK_SECRET` for all paths. That's why you may see "valid" signatures with only a `.env` file.

## Endpoints

| Path | Description |
|------|-------------|
| `POST /webhooks` | Default webhook receiver |
| `POST /webhooks/{path}` | Any sub-path (e.g. `/webhooks/company_a`, `/webhooks/integration_test`) |
| `GET /` | Service info and whether secrets are configured |
| `GET /events` | Last 50 received events (human-readable; add `?format=json` for JSON) |
| `GET /events/company_a` | Events received at `/webhooks/company_a` |
| `GET /events/company_b` | Events received at `/webhooks/company_b` |
| `POST /configure` | Set secret at runtime: `{"secret": "whsec_..."}` |
| `DELETE /events` | Clear all stored events |

## Multi-Endpoint Testing

To test multiple webhook flows in parallel:

1. **Register multiple endpoints** in the Dashboard (or via API), each pointing to a different path:
   - `http://localhost:9000/webhooks` — main flow
   - `http://localhost:9000/webhooks/company_a` — company A events
   - `http://localhost:9000/webhooks/company_b` — company B events

2. **Add each path and secret** to `config.json`:
   ```json
   {
     "endpoints": {
       "/webhooks": "whsec_main...",
       "/webhooks/company_a": "whsec_company_a...",
       "/webhooks/company_b": "whsec_company_b..."
     }
   }
   ```

3. Subscribe each endpoint to its relevant event types in the Dashboard.

4. Trigger events and view them at:
   - http://localhost:9000/events — all events
   - http://localhost:9000/events/company_a — company A only
   - http://localhost:9000/events/company_b — company B only

## Signature Verification

When a secret is configured for the request path, the listener verifies the `Turnstay-Signature` header. You'll see:

- **valid** — signature verified successfully
- **INVALID** — signature mismatch (wrong secret or tampered payload)
- **unverified** — no secret configured for this path

## Test Script

Run an end-to-end test (register endpoint, subscribe, trigger event, verify isolation):

```bash
./test-webhook-flow.sh
```

Requires the webhook-service (port 8000) and this listener (port 9000) to be running. The script prints the endpoint secret—add it to `config.json` or `.env` for signature verification.

## Running with start-local.sh

The parent project's `start-local.sh` starts the listener along with other services. Ensure `config.json` or `.env` is set up before running:

```bash
./start-local.sh
```

The listener runs on port 9000. The webhook-service will deliver to whatever endpoint URLs you've registered (e.g. `http://localhost:9000/webhooks`).

## Troubleshooting

**Signatures show "unverified"**

- Add the secret for that path to `config.json` or set `WEBHOOK_SECRET` in `.env`.
- Restart the listener after changing config.

**Signatures show "INVALID"**

- The secret in the config doesn't match the endpoint's secret in the webhook-service.
- Use **Dashboard → Webhooks → Endpoint detail → Reveal secret** and update `config.json` to match.

**No events received**

- Ensure the webhook-service is running and the endpoint URL is registered.
- Check that the endpoint is subscribed to the event types you're triggering.
- Run `./test-webhook-flow.sh` to run a quick end-to-end test.
