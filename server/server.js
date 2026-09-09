import 'dotenv/config';
import express from 'express';
import cors from 'cors';

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || '';
const BRIDGE_KEY = process.env.BRIDGE_KEY || '';
const PORT = process.env.PORT || 8787;
const MODEL = process.env.ANTHROPIC_MODEL || 'claude-sonnet-5';

if (!ANTHROPIC_API_KEY) {
  console.warn('WARNING: ANTHROPIC_API_KEY is not set. /analyze will return an error until it is.');
}
if (!BRIDGE_KEY) {
  console.warn('WARNING: BRIDGE_KEY is not set — /analyze and /ingest/* are UNAUTHENTICATED. Set BRIDGE_KEY before exposing this beyond localhost.');
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

app.listen(PORT, '127.0.0.1', () => {
  console.log(`AUTOPSY X bridge listening on http://127.0.0.1:${PORT}`);
  console.log(`Anthropic key configured: ${Boolean(ANTHROPIC_API_KEY)}`);
  console.log(`Bridge key configured: ${Boolean(BRIDGE_KEY)}`);
});
