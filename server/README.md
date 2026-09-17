# AUTOPSY X bridge

Local server that keeps your Anthropic API key off the browser. `index.html`'s
"Live Bridge" panel talks to this.

## Setup

```bash
cd server
npm install
cp .env.example .env   # fill in ANTHROPIC_API_KEY and BRIDGE_KEY (+ ALPHA_VANTAGE_API_KEY if you want /macro/snapshot)
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

- `GET /health` — `{ ok, hasAnthropicKey, hasAlphaVantageKey }`
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
- `GET /macro/snapshot` (requires `x-bridge-key`) — flat JSON built from
  Alpha Vantage: `us10y_level`, `us10y_momentum_bps_10d`,
  `us2y_momentum_bps_10d`, `fed_funds_momentum_bps_30d`, `cpi_yoy_pct`,
  `breadth_advancers`/`breadth_decliners`/`breadth_sample_size` (a rough
  proxy from Alpha Vantage's top-20 most-actively-traded list — **not**
  true market-wide advance/decline breadth), `news_sentiment_score`,
  `news_article_count`, `generated_at`. Any field can come back `null` if
  that Alpha Vantage leg failed or is rate-limited — the response still
  returns 200 with whatever legs succeeded (see server logs for which
  ones didn't). Consumed by `mt5/MQL5/Include/AutopsyX/
  AutopsyAlphaVantageBridge.mqh` via MT5's `WebRequest()`; see
  `mt5/README.md` for the MT5-side setup (you need to whitelist this
  server's URL in Tools → Options → Expert Advisors). Cached server-side
  per `server/alphaVantage.js`'s TTLs, so polling this endpoint often
  costs cache hits, not Alpha Vantage quota.

## What's not here yet

`/ingest/tick` and `/ingest/account` exist so an MT5 Expert Advisor can push
live prices and account state into `/state`, but no such EA
(`AutopsyXBridge.mq5`, referenced in the page's copy) exists in this repo
yet — that's a separate build if you want live MT5 ticks flowing through the
chart/sizing panels instead of only the direct MetaApi connection.

If `BRIDGE_KEY` is left unset, `/analyze` and `/ingest/*` run unauthenticated
(a startup warning says so) — fine for local dev, never for anything reachable
off your own machine.
