# AUTOPSY X bridge

Local server that keeps your Anthropic API key off the browser. `index.html`'s
"Live Bridge" panel talks to this.

## Setup

```bash
cd server
npm install
cp .env.example .env   # fill in ANTHROPIC_API_KEY and BRIDGE_KEY
npm start
```

Runs on `http://localhost:8787` by default. It binds to `0.0.0.0` so it also
works when deployed (see below) — set `HOST=127.0.0.1` in `.env` if you only
ever want it reachable from your own machine.

In the page's "Live Bridge" panel, set the URL to wherever this is running
and the key to your `BRIDGE_KEY`, then check "Route analysis through this
bridge's /analyze" so the Run Autopsy / Scanner / Research Mode calls go
through here instead of failing against `api.anthropic.com` directly from
the browser.

## Deploy (Render)

`render.yaml` at the repo root is a Render Blueprint for this service.

1. On [Render](https://dashboard.render.com), New → Blueprint → connect this
   GitHub repo. Render reads `render.yaml` and proposes the `autopsy-x-bridge`
   web service.
2. It'll prompt you for `ANTHROPIC_API_KEY` during setup (marked
   `sync: false` in the blueprint so it's never stored in the repo) —
   `BRIDGE_KEY` is auto-generated for you. Both stay in Render's dashboard,
   never in git or in this conversation.
3. Deploy. Render gives you a public URL like
   `https://autopsy-x-bridge.onrender.com`.
4. In the page's Live Bridge panel: that URL, and the `BRIDGE_KEY` value
   from Render's dashboard (Environment tab).

Free-tier Render services spin down after inactivity and take ~30-60s to
wake on the next request — the first analysis call after idle time will be
slow, not broken.

## Endpoints

- `GET /health` — `{ ok, hasAnthropicKey }`
- `GET /state` — `{ symbols, account, staleness_ms }`, whatever the last
  `/ingest/*` calls pushed in. **Unauthenticated**, matching the page's
  current unauthenticated poll — don't expose this past localhost without
  adding auth here and to the frontend's `pollBridgeOnce()` fetch.
- `POST /analyze` (requires `x-bridge-key`) — `{ system, prompt, useSearch }`
  → proxies to `https://api.anthropic.com/v1/messages` and returns the raw
  response.
- `POST /ingest/tick` (requires `x-bridge-key`) — `{ symbol, bid, ask, dom? }`
- `POST /ingest/account` (requires `x-bridge-key`) — `{ balance, equity,
  margin?, freeMargin?, currency?, leverage?, type? }`

## What's not here yet

`/ingest/tick` and `/ingest/account` exist so an MT5 Expert Advisor can push
live prices and account state into `/state`, but no such EA
(`AutopsyXBridge.mq5`, referenced in the page's copy) exists in this repo
yet — that's a separate build if you want live MT5 ticks flowing through the
chart/sizing panels instead of only the direct MetaApi connection.

If `BRIDGE_KEY` is left unset, `/analyze` and `/ingest/*` run unauthenticated
(a startup warning says so) — fine for local dev, never for anything reachable
off your own machine.


## FLIPDEMON distributed risk coordinator

The bridge's original `/state` cache is in-memory and is **not** an execution-risk authority. FLIPDEMON's coordinator uses a separate SQLite ledger with atomic `BEGIN IMMEDIATE` transactions. It is disabled unless both `RISK_COORDINATOR_KEY` and an absolute `RISK_LEDGER_PATH` are configured. The coordinator has its own `x-risk-coordinator-key` header. It never falls back to `BRIDGE_KEY`.

### Required deployment configuration

- Run Node.js **22.13 or later**.
- Attach a persistent disk to the single bridge service instance and set `RISK_LEDGER_PATH` to a file on that disk (for example, `/var/data/flipdemon-risk.sqlite`).
- Set a long, random `RISK_COORDINATOR_KEY` in the host's secret environment settings. Do not put it in Git, dashboard JavaScript, or committed EA inputs.
- Keep the service to one instance. SQLite WAL is appropriate for one service process and a persistent local disk, not multiple independent replicas or network filesystems.
- Set readiness only when `GET /health` returns `riskCoordinatorReady: true`. If storage or the key is missing, the risk endpoints return HTTP 503.

The existing Render Blueprint intentionally does not create a paid persistent disk or change the service plan. Configure persistent storage and its cost in Render before enabling this coordinator. Without that setup, the EA must reject new entries.

### Risk API contract

All routes require `x-risk-coordinator-key`. Account identity is the MT5 login plus broker server. The server derives the hard budget as exactly 2% of reported equity; clients cannot raise it.

- `POST /risk/reconcile`: `{login, server, equity, existingRiskMoney, snapshotAtMs, snapshotId}`. Publishes a fresh broker-confirmed snapshot. Snapshots older than the configured freshness window or out of order are rejected.
- `POST /risk/reserve`: `{login, server, instanceId, idempotencyKey, riskMoney}`. Atomically checks broker exposure plus all unexpired reservations, then reserves the proposed stop-risk.
- `POST /risk/release`: `{login, server, reservationId, instanceId, equity, existingRiskMoney, snapshotAtMs, snapshotId}`. Releases only the originating instance's active reservation after a fresh broker snapshot newer than reservation creation has been accepted. Settled or expired reservations cannot be released.
- `POST /risk/settle`: `{login, server, reservationId, equity, existingRiskMoney, snapshotAtMs, snapshotId}`. Replaces the broker snapshot and consumes the matching reservation in one transaction. It reports an over-cap fill rather than hiding it.

Reservations expire after 60 seconds by default. Expiry is not proof that an order failed. An expired reservation blocks further reservations until `/risk/reconcile` accepts a newer full broker snapshot, including every open position and active pending order. Reconciliation then consumes the expired reservation because its risk is represented by the broker snapshot. Release also requires a newer snapshot and the originating `instanceId`; never release merely because an order-send call timed out. The MT5 WebRequest adapter, periodic snapshot publisher, secret provisioning and broker-runtime validation remain a separate integration milestone. This service code alone does not authorize EA execution.
