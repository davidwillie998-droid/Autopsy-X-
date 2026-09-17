// Alpha Vantage macro/breadth data fetcher, with in-memory caching.
//
// Keeps the Alpha Vantage API key server-side, same pattern as
// ANTHROPIC_API_KEY in server.js. Alpha Vantage's free tier is 25
// requests/day and 5/minute, so this caches every series aggressively —
// even an EA polling /macro/snapshot every few minutes never comes close
// to that ceiling, because it's the cache that gets hit, not the API.
//
// Output is intentionally a FLAT object (see getMacroSnapshot below) so
// the MQL5 consumer (AutopsyAlphaVantageBridge.mqh) can extract fields
// with plain string search instead of needing a real JSON parser.

const AV_BASE = 'https://www.alphavantage.co/query';

const CACHE_TTL_MS = {
  treasuryYield: 6 * 60 * 60 * 1000,   // yields don't move meaningfully within a session
  fedFundsRate: 6 * 60 * 60 * 1000,
  cpi: 24 * 60 * 60 * 1000,            // monthly series
  topGainersLosers: 15 * 60 * 1000,
  newsSentiment: 30 * 60 * 1000,
};

const cache = new Map(); // key -> { data, fetchedAt }

async function cachedFetch(key, ttlMs, fetcher) {
  const hit = cache.get(key);
  if (hit && Date.now() - hit.fetchedAt < ttlMs) return hit.data;
  const data = await fetcher();
  cache.set(key, { data, fetchedAt: Date.now() });
  return data;
}

async function avQuery(apiKey, params) {
  const url = new URL(AV_BASE);
  url.searchParams.set('apikey', apiKey);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url.toString());
  if (!res.ok) throw new Error(`Alpha Vantage HTTP ${res.status}`);
  const json = await res.json();
  // Alpha Vantage returns 200 OK even for errors/rate-limit — the real
  // signal is one of these keys instead of the expected payload.
  if (json['Error Message']) throw new Error('Alpha Vantage error: ' + json['Error Message']);
  if (json['Note']) throw new Error('Alpha Vantage rate limit: ' + json['Note']);
  if (json['Information']) throw new Error('Alpha Vantage: ' + json['Information']);
  return json;
}

function latestSeriesValue(series, lookbackIndex = 0) {
  // Sort defensively by date rather than trust the series' own ordering.
  const sorted = [...series].sort((a, b) => new Date(b.date) - new Date(a.date));
  const point = sorted[lookbackIndex];
  if (!point) return null;
  const value = parseFloat(point.value);
  return isFinite(value) ? { date: point.date, value } : null;
}

function momentumBps(series, lookbackPoints) {
  const latest = latestSeriesValue(series, 0);
  const past = latestSeriesValue(series, lookbackPoints);
  if (!latest || !past) return null;
  return (latest.value - past.value) * 100; // percentage-point change -> basis points
}

async function fetchTreasuryYield(apiKey, maturity) {
  const json = await cachedFetch(`treasury_${maturity}`, CACHE_TTL_MS.treasuryYield, () =>
    avQuery(apiKey, { function: 'TREASURY_YIELD', interval: 'daily', maturity })
  );
  const series = json.data || [];
  const latest = latestSeriesValue(series, 0);
  return {
    level: latest ? latest.value : null,
    momentum_bps_10d: momentumBps(series, 10),
  };
}

async function fetchFedFundsRate(apiKey) {
  const json = await cachedFetch('fed_funds', CACHE_TTL_MS.fedFundsRate, () =>
    avQuery(apiKey, { function: 'FEDERAL_FUNDS_RATE', interval: 'daily' })
  );
  const series = json.data || [];
  return { momentum_bps_30d: momentumBps(series, 30) };
}

async function fetchCpiYoy(apiKey) {
  const json = await cachedFetch('cpi', CACHE_TTL_MS.cpi, () =>
    avQuery(apiKey, { function: 'CPI', interval: 'monthly' })
  );
  const series = json.data || [];
  const latest = latestSeriesValue(series, 0);
  const yearAgo = latestSeriesValue(series, 12);
  if (!latest || !yearAgo || yearAgo.value === 0) return { yoy_pct: null };
  return { yoy_pct: 100 * (latest.value - yearAgo.value) / yearAgo.value };
}

async function fetchBreadthProxy(apiKey) {
  // NOT true market-wide advance/decline breadth — Alpha Vantage has no
  // such endpoint. This counts gainers vs. decliners among its top-20
  // most-actively-traded list, a narrow participation proxy, labeled as
  // such all the way through to the MQL5 side.
  const json = await cachedFetch('top_gainers_losers', CACHE_TTL_MS.topGainersLosers, () =>
    avQuery(apiKey, { function: 'TOP_GAINERS_LOSERS' })
  );
  const active = json.most_actively_traded || [];
  const advancers = active.filter((r) => parseFloat(r.change_percentage) > 0).length;
  const decliners = active.filter((r) => parseFloat(r.change_percentage) < 0).length;
  return { advancers, decliners, sample_size: active.length };
}

async function fetchNewsSentiment(apiKey, tickers) {
  if (!tickers) return { score: null, article_count: 0 };
  const json = await cachedFetch('news_' + tickers, CACHE_TTL_MS.newsSentiment, () =>
    avQuery(apiKey, { function: 'NEWS_SENTIMENT', tickers, limit: '50' })
  );
  const feed = json.feed || [];
  const wanted = tickers.split(',').map((t) => t.trim());
  let sum = 0;
  let n = 0;
  for (const item of feed) {
    const match = (item.ticker_sentiment || []).find((t) => wanted.includes(t.ticker));
    const score = parseFloat(match ? match.ticker_sentiment_score : item.overall_sentiment_score);
    if (isFinite(score)) { sum += score; n++; }
  }
  return { score: n ? sum / n : null, article_count: n };
}

// Fetches every leg in parallel and never lets one failing leg take down
// the rest — a rate-limited CPI call still leaves yields/breadth usable.
export async function getMacroSnapshot(apiKey, newsTickers) {
  const [us10y, us2y, fedFunds, cpi, breadth, news] = await Promise.allSettled([
    fetchTreasuryYield(apiKey, '10year'),
    fetchTreasuryYield(apiKey, '2year'),
    fetchFedFundsRate(apiKey),
    fetchCpiYoy(apiKey),
    fetchBreadthProxy(apiKey),
    fetchNewsSentiment(apiKey, newsTickers),
  ]);

  const ok = (settled) => (settled.status === 'fulfilled' ? settled.value : null);
  const errOf = (settled) => (settled.status === 'rejected' ? String((settled.reason && settled.reason.message) || settled.reason) : null);

  const us10yV = ok(us10y);
  const us2yV = ok(us2y);
  const fedFundsV = ok(fedFunds);
  const cpiV = ok(cpi);
  const breadthV = ok(breadth);
  const newsV = ok(news);

  const errors = { us10y: errOf(us10y), us2y: errOf(us2y), fed_funds: errOf(fedFunds), cpi: errOf(cpi), breadth_proxy: errOf(breadth), news_sentiment: errOf(news) };
  for (const [leg, message] of Object.entries(errors)) {
    if (message) console.warn(`Alpha Vantage leg '${leg}' failed: ${message}`);
  }

  // Flat on purpose — see the module-level comment.
  return {
    us10y_level: us10yV ? us10yV.level : null,
    us10y_momentum_bps_10d: us10yV ? us10yV.momentum_bps_10d : null,
    us2y_momentum_bps_10d: us2yV ? us2yV.momentum_bps_10d : null,
    fed_funds_momentum_bps_30d: fedFundsV ? fedFundsV.momentum_bps_30d : null,
    cpi_yoy_pct: cpiV ? cpiV.yoy_pct : null,
    breadth_advancers: breadthV ? breadthV.advancers : null,
    breadth_decliners: breadthV ? breadthV.decliners : null,
    breadth_sample_size: breadthV ? breadthV.sample_size : null,
    news_sentiment_score: newsV ? newsV.score : null,
    news_article_count: newsV ? newsV.article_count : null,
    generated_at: new Date().toISOString(),
  };
}
