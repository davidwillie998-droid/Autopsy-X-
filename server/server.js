import 'dotenv/config';
import express from 'express';
import cors from 'cors';

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || '';
const ALPHAVANTAGE_API_KEY = process.env.ALPHAVANTAGE_API_KEY || '';
const BRIDGE_KEY = process.env.BRIDGE_KEY || '';
const PORT = process.env.PORT || 8787;
const MODEL = process.env.ANTHROPIC_MODEL || 'claude-sonnet-5';
// Bind to all interfaces by default so this reaches the outside world on a
// host like Render/Railway (they route to the container's PORT, not just
// localhost). Set HOST=127.0.0.1 to restrict to local-machine-only use.
const HOST = process.env.HOST || '0.0.0.0';

if (!ANTHROPIC_API_KEY) {
  console.warn('WARNING: ANTHROPIC_API_KEY is not set. /analyze will return an error until it is.');
}
if (!BRIDGE_KEY) {
  console.warn('WARNING: BRIDGE_KEY is not set — /analyze and /ingest/* are UNAUTHENTICATED. Set BRIDGE_KEY before exposing this beyond localhost.');
}
if (!ALPHAVANTAGE_API_KEY) {
  console.warn('WARNING: ALPHAVANTAGE_API_KEY is not set. /macro will return an error until it is.');
}

const app = express();
app.use(cors());
app.use(express.json({ limit: '256kb' }));

// In-memory only — restarts clear it. This is a bridge, not a database.
const state = {
  symbols: {}, // upper symbol -> {symbol, bid, ask, dom, receivedAt}
  account: null, // {balance, equity, margin, freeMargin, currency, leverage, type, receivedAt}
};

function requireBridgeKey(req, res, next) {
  if (!BRIDGE_KEY) return next(); // dev-mode fallback when no key is configured
  if (req.get('x-bridge-key') !== BRIDGE_KEY) {
    return res.status(401).json({ error: 'Invalid or missing x-bridge-key header.' });
  }
  next();
}

app.get('/health', (req, res) => {
  res.json({ ok: true, hasAnthropicKey: Boolean(ANTHROPIC_API_KEY) });
});

// Matches the frontend's pollBridgeOnce()/renderBridgeTicker() shape.
// NOTE: unauthenticated, same as the frontend's current fetch(url + '/state') call —
// anyone who can reach this bridge can read live prices and account balance/equity.
// Keep this bound to 127.0.0.1 unless you add auth here and to the frontend's poll call.
app.get('/state', (req, res) => {
  const ages = Object.values(state.symbols).map((s) => Date.now() - (s.receivedAt || 0));
  const staleness_ms = ages.length ? Math.min(...ages) : null;
  res.json({ symbols: state.symbols, account: state.account, staleness_ms });
});

// Push a price tick in from an EA/script: { symbol, bid, ask, dom? }
app.post('/ingest/tick', requireBridgeKey, (req, res) => {
  const { symbol, bid, ask, dom } = req.body || {};
  if (!symbol || typeof bid !== 'number' || typeof ask !== 'number') {
    return res.status(400).json({ error: 'symbol (string), bid (number), and ask (number) are required.' });
  }
  const upper = String(symbol).toUpperCase();
  state.symbols[upper] = { symbol: upper, bid, ask, dom: dom || null, receivedAt: Date.now() };
  res.json({ ok: true });
});

// Push account info in from an EA/script: { balance, equity, margin, freeMargin, currency, leverage, type }
app.post('/ingest/account', requireBridgeKey, (req, res) => {
  const { balance, equity, margin, freeMargin, currency, leverage, type } = req.body || {};
  if (typeof balance !== 'number' || typeof equity !== 'number') {
    return res.status(400).json({ error: 'balance (number) and equity (number) are required.' });
  }
  state.account = { balance, equity, margin, freeMargin, currency, leverage, type, receivedAt: Date.now() };
  res.json({ ok: true });
});

// ---------------------------------------------------------------------------
// AUTOPSY X macro feeder — closes the yields/real-yield data gap documented
// in mt5/README.md. MT5 has no native source for Treasury yields, so
// AutopsyMacroFeeder.mq5 (in mt5/Experts/) polls /macro on a timer and writes
// what it gets straight into the GlobalVariables the macro engine reads.
//
// Deliberately NOT included: Fed-expectations and breadth. Alpha Vantage has
// no market-implied Fed-funds-futures series and no breadth/advance-decline
// series, and fabricating a stand-in for either would be worse than leaving
// them unset — the macro/regime engines already degrade gracefully when a
// GlobalVariable is simply missing.
// ---------------------------------------------------------------------------

const MACRO_CACHE_TTL_MS = 6 * 60 * 60 * 1000; // 6h — a free AV key is 25 requests/day total
const MACRO_LOOKBACK_MS = 14 * 24 * 60 * 60 * 1000; // ~10 trading days, for "change" fields
let macroCache = { data: null, fetchedAt: 0, error: null };

async function fetchAlphaVantage(params) {
  const url = 'https://www.alphavantage.co/query?' + new URLSearchParams({
    ...params,
    apikey: ALPHAVANTAGE_API_KEY,
    datatype: 'json',
  });
  const res = await fetch(url);
  const data = await res.json();
  if (data['Error Message']) throw new Error('Alpha Vantage: ' + data['Error Message']);
  if (data['Note']) throw new Error('Alpha Vantage rate limit: ' + data['Note']);
  if (data['Information']) throw new Error('Alpha Vantage: ' + data['Information']);
  return data;
}

// Alpha Vantage's economic-indicator endpoints (TREASURY_YIELD, CPI, ...) all
// share this shape: { data: [{ date: "YYYY-MM-DD", value: "1.23" }, ...] }.
function parseAvSeries(raw) {
  return (raw.data || [])
    .map((e) => ({ date: new Date(e.date + 'T00:00:00Z'), value: parseFloat(e.value) }))
    .filter((e) => !isNaN(e.value) && !isNaN(e.date.getTime()))
    .sort((a, b) => b.date - a.date); // newest first — re-sorted defensively rather than trusted
}

// Returns null (not just "the closest thing we had") when the nearest row is
// further than `maxToleranceMs` from the target — otherwise a thin series
// (e.g. right after a rate-limited fetch only returned a few rows) would
// silently pair "now" with some unrelated old print and report a fake ~0bps
// change instead of failing loudly.
function nearestRowTo(rows, targetMs, maxToleranceMs = Infinity) {
  if (!rows.length) return null;
  let best = rows[0];
  let bestDiff = Math.abs(rows[0].date.getTime() - targetMs);
  for (const r of rows) {
    const diff = Math.abs(r.date.getTime() - targetMs);
    if (diff < bestDiff) { best = r; bestDiff = diff; }
  }
  return bestDiff <= maxToleranceMs ? best : null;
}

const DAY_MS = 24 * 60 * 60 * 1000;

// Trailing 12-month CPI % change as of `atMs` — a real, if approximate, proxy
// for inflation expectations. Not TIPS breakeven; documented as such below.
function cpiYoyAt(cpiRows, atMs) {
  const now = nearestRowTo(cpiRows, atMs, 45 * DAY_MS);       // CPI prints monthly
  const yearAgo = nearestRowTo(cpiRows, atMs - 365 * DAY_MS, 45 * DAY_MS);
  if (!now || !yearAgo || yearAgo.value === 0) return null;
  return ((now.value - yearAgo.value) / yearAgo.value) * 100;
}

async function computeMacroSnapshot() {
  const [y2, y10, cpi] = await Promise.all([
    fetchAlphaVantage({ function: 'TREASURY_YIELD', maturity: '2year', interval: 'daily' }),
    fetchAlphaVantage({ function: 'TREASURY_YIELD', maturity: '10year', interval: 'daily' }),
    fetchAlphaVantage({ function: 'CPI', interval: 'monthly' }),
  ]);

  const y2Rows = parseAvSeries(y2), y10Rows = parseAvSeries(y10), cpiRows = parseAvSeries(cpi);
  if (!y2Rows.length || !y10Rows.length || !cpiRows.length) {
    throw new Error('Alpha Vantage returned no usable data points for one of the series.');
  }

  // Anchor "now" to the yield series' own latest print, not wall-clock time —
  // Treasury data lags weekends/holidays by design, that's not staleness.
  const nowMs = y10Rows[0].date.getTime();

  const us02yNow  = nearestRowTo(y2Rows, nowMs, 5 * DAY_MS);
  const us02yPast = nearestRowTo(y2Rows, nowMs - MACRO_LOOKBACK_MS, 5 * DAY_MS);
  const us10yNow  = nearestRowTo(y10Rows, nowMs, 5 * DAY_MS);
  const us10yPast = nearestRowTo(y10Rows, nowMs - MACRO_LOOKBACK_MS, 5 * DAY_MS);
  const cpiYoyNow = cpiYoyAt(cpiRows, nowMs), cpiYoyPast = cpiYoyAt(cpiRows, nowMs - MACRO_LOOKBACK_MS);

  if (!us02yNow || !us02yPast || !us10yNow || !us10yPast || cpiYoyNow === null || cpiYoyPast === null) {
    throw new Error('Not enough history in one of the Alpha Vantage series to compute a change yet.');
  }

  const realYieldNow = us10yNow.value - cpiYoyNow;
  const realYieldPast = us10yPast.value - cpiYoyPast;

  return {
    us02yLevel: us02yNow.value,
    us02yChangeBps: Math.round((us02yNow.value - us02yPast.value) * 10000) / 100,
    us10yLevel: us10yNow.value,
    us10yChangeBps: Math.round((us10yNow.value - us10yPast.value) * 10000) / 100,
    realYield10yLevel: Math.round(realYieldNow * 100) / 100,
    realYield10yChangeBps: Math.round((realYieldNow - realYieldPast) * 10000) / 100,
    cpiYoyPct: Math.round(cpiYoyNow * 100) / 100,
    asOfDate: y10Rows[0].date.toISOString().slice(0, 10),
  };
}

// GET /macro?format=json|kv&refresh=1  (requires x-bridge-key)
// `format=kv` returns flat KEY=VALUE lines — that's what AutopsyMacroFeeder.mq5
// consumes, since hand-rolling a JSON parser in MQL5 is a needless risk when
// the two ends of this pipe are both this project's own code.
app.get('/macro', requireBridgeKey, async (req, res) => {
  if (!ALPHAVANTAGE_API_KEY) {
    return res.status(500).json({ error: 'Server has no ALPHAVANTAGE_API_KEY configured.' });
  }

  const isFresh = macroCache.data && (Date.now() - macroCache.fetchedAt) < MACRO_CACHE_TTL_MS;
  if (!isFresh || req.query.refresh === '1') {
    try {
      macroCache = { data: await computeMacroSnapshot(), fetchedAt: Date.now(), error: null };
    } catch (err) {
      macroCache.error = err.message;
      if (!macroCache.data) {
        return res.status(502).json({ error: 'Alpha Vantage fetch failed and no cached snapshot exists yet: ' + err.message });
      }
      // fall through and serve the last known-good snapshot, flagged stale below
    }
  }

  const snap = macroCache.data;
  const stale = (Date.now() - macroCache.fetchedAt) >= MACRO_CACHE_TTL_MS || Boolean(macroCache.error);
  const lastUpdateUnix = Math.floor(macroCache.fetchedAt / 1000);

  if ((req.query.format || 'json') === 'kv') {
    res.set('Content-Type', 'text/plain');
    return res.send([
      `Ax_US02Y_Level=${snap.us02yLevel}`,
      `Ax_US02Y_ChangeBps=${snap.us02yChangeBps}`,
      `Ax_US10Y_Level=${snap.us10yLevel}`,
      `Ax_US10Y_ChangeBps=${snap.us10yChangeBps}`,
      `Ax_RealYield10Y_Level=${snap.realYield10yLevel}`,
      `Ax_RealYield10Y_ChangeBps=${snap.realYield10yChangeBps}`,
      `Ax_Macro_LastUpdateUnix=${lastUpdateUnix}`,
    ].join('\n') + '\n');
  }

  res.json({ ...snap, stale, cachedAt: macroCache.fetchedAt, error: macroCache.error || undefined });
});

// Proxies to Claude so the API key never reaches the browser.
// Body: { system, prompt, useSearch }
app.post('/analyze', requireBridgeKey, async (req, res) => {
  if (!ANTHROPIC_API_KEY) {
    return res.status(500).json({ error: 'Server has no ANTHROPIC_API_KEY configured.' });
  }
  const { system, prompt, useSearch } = req.body || {};
  if (!system || !prompt) {
    return res.status(400).json({ error: 'system and prompt are required.' });
  }

  try {
    const upstream = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1000,
        system,
        messages: [{ role: 'user', content: prompt }],
        ...(useSearch ? { tools: [{ type: 'web_search_20250305', name: 'web_search' }] } : {}),
      }),
    });

    const data = await upstream.json();
    if (!upstream.ok) {
      return res.status(upstream.status).json({ error: data?.error?.message || 'Upstream Anthropic API error.' });
    }
    res.json(data);
  } catch (err) {
    res.status(502).json({ error: 'Failed to reach Anthropic API: ' + err.message });
  }
});

app.listen(PORT, HOST, () => {
  console.log(`AUTOPSY X bridge listening on http://${HOST}:${PORT}`);
  console.log(`Anthropic key configured: ${Boolean(ANTHROPIC_API_KEY)}`);
  console.log(`Bridge key configured: ${Boolean(BRIDGE_KEY)}`);
});
