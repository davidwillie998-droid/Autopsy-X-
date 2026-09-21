# Modernizing Patnaik & Thomas (2004) for current market microstructure

**Source paper:** Tirthankar Patnaik & Susan Thomas, "Profitability of Trading
Strategies on High-Frequency data, with Trading Costs" (SSRN 568363, April
2004).

**Purpose of this note:** this paper is old enough (2004, tested on 1996–2002
NSE data) that citing it as *the current standard* would be wrong. Cited as
*the historical baseline that current practice moved past, and specifically
how*, it's genuinely useful — its methodology is clean, its formulas are
explicit, and its central finding (transaction costs are non-proportional
and trade-size-dependent, so profits aren't scale-invariant) is exactly the
distinction this codebase's EV engine work is built around. This note exists
to be that citation: something FLIPDEMON's EV/Execution engine comments and
the dashboard's Pattern Finder mode prompt can point to instead of a vague
"markets have changed" hand-wave.

**Honesty check on this note itself:** everything cited below is real,
established literature I'm confident about — not fabricated papers or
invented 2020s-2026 citations to sound current. Where I'm not fully certain
of an exact date or journal, I've said so rather than presenting a guess as
fact. Where the modernization depends on a number that changes over time
(current algo-trading share of volume, current SEBI colocation rules,
today's realized spreads), I've flagged it as something to verify against a
live source rather than asserting a figure from training data as current.

---

## 1. What the 2004 paper actually did

- **Setting:** Indian equity markets (NSE), 1996–2002, using intraday
  limit-order-book snapshots taken 3-4 times a day (up to 1400 hrs).
- **Strategy framework:** the F/S/H (Formation/Skip/Holding) structure —
  rank stocks on mean return over a formation window (25 to 250 *calendar*
  days), skip a day, hold winner/loser portfolios for a holding window of
  the same length, then reverse.
- **Cost model:** price impact calculated directly from order-book depth for
  a fixed order size (INR 10,000), rather than assumed at the quoted
  bid-ask — the paper's real contribution. Formula: `IC = Q · sgn(trade) ·
  (P − P*)`, benchmarked against the mid of the best available buy/sell
  prices in the book.
- **Finding:** momentum strategies were profitable net of this price impact
  at short formation periods, with profits decaying as the formation period
  lengthened — attributed mostly to firm-specific serial covariance and
  cross-sectional variation, not common-factor exposure (via the Jegadeesh &
  Titman (1995) and Lo & MacKinlay (1990) decompositions).

That's a sound, well-executed study *for its era*. Four things have changed
enough since 2004 that a straight re-read of it as "current methodology"
would mislead:

---

## 2. What's changed in market structure since 2004

- **Continuous algorithmic/HFT markets replaced sparse snapshots.** The
  paper worked with 3-4 order-book snapshots a day because that's what was
  available. Markets today are fully electronic with millisecond-to-
  microsecond order flow, direct market access, and colocation — NSE
  introduced DMA and colocation in the years following this paper (SEBI
  approved DMA around 2008 and colocation around 2010; verify exact dates
  against a current SEBI/NSE source if this matters for a compliance
  document, I'm reasonably but not certainly confident on those years).
  Reconstructing the *full* limit order book at native resolution is now
  the standard input, not a 4x-daily snapshot.
- **Market fragmentation.** US equities fragmented sharply after Reg NMS
  (2005) — order flow now splits across a dozen-plus lit exchanges, dark
  pools, and internalizers. A single-exchange order-book view (which is
  what the 2004 paper had for the NSE, then India's dominant venue) is no
  longer sufficient for cost estimation in fragmented markets; a modern
  impact model needs to account for where liquidity actually sits.
- **24/7, no-central-limit-order-book markets now matter.** Crypto assets
  (BTCUSD, relevant to this repo's FLIPDEMON) trade continuously across
  spot exchanges, perpetual futures with funding-rate mechanics, and
  automated market makers (constant-product/concentrated-liquidity AMMs)
  with fundamentally different impact dynamics than a traditional
  limit-order book. None of this existed in 2004; a 2004 LOB-snapshot
  methodology doesn't transfer to an AMM pool at all — impact there is a
  deterministic function of the pool's liquidity curve, not an empirically
  estimated coefficient.
- **Momentum itself has been heavily arbitraged since publication.** The
  paper's core empirical claim — momentum strategies are profitable net of
  costs — was published into a literature that subsequently documented
  factor crowding and decay. McLean & Pontiff (2016, *Journal of Finance*,
  "Does Academic Research Destroy Stock Return Predictability?") find
  post-publication return decay across a wide set of documented anomalies,
  momentum included, consistent with capital chasing published factors.
  Daniel & Moskowitz (2016, *Journal of Financial Economics*, "Momentum
  Crashes") separately document that momentum carries severe left-tail
  crash risk concentrated around market rebounds — a risk this 2004 paper's
  return tables don't surface, because momentum crashes are a small-sample,
  regime-dependent phenomenon that a 1996-2002 window may simply not have
  contained in force.

---

## 3. Modernizing each piece of the methodology

### 3.1 Price impact model

**2004 paper:** direct empirical measurement against order-book depth for a
*fixed* order size — genuinely ahead of its time (most contemporaries used
econometric proxies), but static: one impact number per stock per snapshot,
no model of how impact decays or accumulates over an execution.

**What superseded it:** the **square-root law / propagator model** —
empirically, price impact of an order scales roughly as `impact ≈ Y · σ ·
√(Q / V)` where Y is an O(1) constant, σ is volatility, Q is order size, and
V is average daily volume — rather than linearly in size. This is the
`ImpactCoefficientK · σ · sqrt(orderSize / averageDailyVolume)` form already
implemented (gated off by default) in this repo's regime engine work.
Foundational references: Bouchaud, Gefen, Potters & Wyart (2004,
*Quantitative Finance*, "Fluctuations and response in financial markets");
Bouchaud, Farmer & Lillo (2009, chapter in *Handbook of Financial Markets:
Dynamics and Evolution*, "How markets slowly digest changes in supply and
demand"); and the standard modern textbook treatment, Bouchaud, Bonart,
Donier & Gould, *Trades, Quotes and Prices: Financial Markets Under the
Microscope* (Cambridge University Press, 2018).

The intermediate step between "static empirical impact" and "square-root
law" was **Almgren & Chriss's linear/temporary-plus-permanent impact
model** (2000/2001, *Journal of Risk*, "Optimal Execution of Portfolio
Transactions") — this is the model institutional execution desks built
optimal-execution schedules around for roughly a decade, and it's the one a
2026 system should explicitly *not* default to, because it assumes impact
scales linearly with size, which the square-root law's empirical support
has since superseded for most liquid markets. A later refinement worth
knowing about: Obizhaeva & Wang (2013, *Journal of Financial Markets*,
"Optimal trading strategy and supply/demand dynamics") models impact as
*transient* — it decays over time rather than being permanent or purely
temporary — which matters for holding-period-dependent strategies like the
F/S/H framework this paper uses.

### 3.2 Spread/impact estimators from sparse data

**2004 paper:** cites Roll's serial-covariance estimator (1984),
Glosten-Harris (1988), and Glosten-Milgrom (1985) as the econometric
alternatives to direct order-book measurement, used when the book itself
isn't observable.

**What superseded it:** with full limit-order-book data now the norm
(rather than the exception this paper worked around), these estimators are
mostly relevant today only for markets where the book genuinely isn't
observable — OTC instruments, some fixed income, or historical data. Where
the book is observable, direct measurement (effective spread, realized
spread, implementation shortfall against a chosen benchmark) is standard,
exactly as this paper argued in 2004 — that argument won, it's just that
"the book is observable" went from the exception to the rule.

### 3.3 Formation/Skip/Holding structure

**2004 paper:** fixed *calendar-day* formation and holding windows (25,
50, 75, 150, 250 days), the same window length applied uniformly regardless
of how volatile or trending the underlying was during that stretch.

**What superseded it:** a fixed calendar-day window mixes fundamentally
different amounts of "information" depending on realized volatility — 25
trading days during a calm regime and 25 trading days during a volatility
shock are not comparable formation periods. Current practice, and what this
repo's `AutopsyRegimeEngine.mqh` already implements, is a
**volatility/ATR-normalized adaptive lookback** — the window's length (or
equivalently, its effective sample size) adjusts to realized volatility
rather than staying fixed in calendar time. This isn't just a stylistic
preference: it's a direct response to the factor-decay and crowding
literature above (McLean & Pontiff 2016; Daniel & Moskowitz 2016) — a
static window is easier for a systematic strategy's crowding pattern to be
identified and arbitraged against than an adaptive one, and it treats a
calm 25 days and a volatile 25 days as equivalent when they demonstrably
aren't.

### 3.4 Trade-side classification

**2004 paper:** relies on and explicitly avoids needing the Lee & Ready
(1991) algorithm for inferring buy/sell direction from trade price relative
to the quote, because it has the order book and doesn't need to infer.

**What superseded it:** where actual order-side flags are available (as
they increasingly are in modern audit-trail data — e.g. the US
Consolidated Audit Trail for regulators, though not public data), direct
flags replace algorithmic inference entirely. Lee-Ready-style inference is
now mainly a tool for historical or opaque datasets that predate
order-side reporting requirements, exactly the situation the 2004 paper
was working in.

### 3.5 Retail vs. institutional cost structure

**2004 paper:** notes in passing that retail investors pay higher average
transaction costs than institutional investors, "as the latter don't pay
mark-to-margins," and that cost schedules vary further within institutional
categories (mutual funds vs. FIIs).

**What superseded it:** this observation has hardened into the central
design principle of modern execution-cost modeling, and it's the exact
distinction this repo's EV engine work is built on: retail/small-order flow
is overwhelmingly a **price-taker** whose realistic cost structure is
spread + commission + swap/financing + slippage, with price impact
negligible at typical size; institutional flow is **impact-dominated**,
managed through algorithmic execution strategies (VWAP, TWAP,
percentage-of-volume, implementation-shortfall algos) explicitly built
around square-root/transient impact models. Applying an institutional
impact model to retail-sized orders — or the reverse — misrepresents the
actual cost structure in either direction, which is precisely why the EV
engine's price-impact term should stay gated off by default and only
activate above an explicit, clearly-labeled institutional-scale threshold.

### 3.6 Zero-cost strategy construction

**2004 paper:** builds zero-cost momentum/contrarian portfolios by
simultaneously buying winners and selling losers with matched notional,
noting this is "zero-cost" only when buy and sell costs are identical.

**What superseded it:** the underlying idea is unchanged and still
standard (dollar-neutral factor construction), but modern implementations
more often achieve it through futures, swaps, or ETF long/short pairs
rather than manual simultaneous cash equity buy/sell — which also changes
the relevant cost model again (financing/roll costs replace some of the
equity-market-impact costs the 2004 paper was measuring).

---

## 4. Net summary: what "advanced to match current markets" means concretely

1. Replace the static, snapshot-based price-impact measurement with a
   square-root/transient impact model (Bouchaud et al.), explicitly *not*
   the linear Almgren-Chriss model, gated to institutional order sizes only.
2. Treat Roll/Glosten-Harris/Glosten-Milgrom-style spread estimators as a
   fallback for opaque/illiquid instruments, not the primary cost model,
   now that direct order-book measurement is the norm rather than the
   exception the 2004 paper had to work around.
3. Replace fixed calendar-day formation/holding windows with
   volatility/ATR-adaptive lookback windows, motivated directly by the
   documented momentum-crowding and factor-decay literature since ~2010s
   (McLean & Pontiff 2016; Daniel & Moskowitz 2016) rather than by
   stylistic preference.
4. Keep retail and institutional cost structures as explicitly separate
   models rather than one model reused across both, since that distinction
   — present but understated in the 2004 paper — is now the central design
   principle of realistic execution-cost modeling.
5. For any crypto legs (this repo trades BTCUSD), don't extend the
   equity-LOB methodology at all — perpetual-futures funding-rate cost and
   AMM liquidity-curve impact are structurally different problems that need
   their own treatment, not a retrofit of equity microstructure models.

## 5. Where to use this

- **FLIPDEMON's EV/Execution engine** — cite section 3.1 and 3.5 directly
  in the comment explaining why the square-root impact term is gated off by
  default and why it cites Bouchaud rather than Almgren-Chriss. (Still
  blocked on receiving the actual `AutopsyXFlipdemonX15.mq5` file — this
  note is ready for whenever that arrives.)
- **`AutopsyRegimeEngine.mqh`'s existing ATR-adaptive-lookback comment** —
  section 3.3 above is the fuller citation trail behind the shorter note
  already in that file.
- **The dashboard's Pattern Finder mode** (`index.html`, `MODE_PROMPTS.
  pattern_finder`) — its system prompt currently accepts a vague "this
  month tends to be bullish" as a valid seasonal/momentum finding. Section
  3.3's point (a claimed pattern needs a stated formation/skip/holding
  structure and adaptive-vs-fixed-window awareness, or it's not a
  pattern — it's an anecdote) is the concrete standard to tighten that
  prompt against, if you want that edit made now — it's unblocked, unlike
  the FLIPDEMON work.
