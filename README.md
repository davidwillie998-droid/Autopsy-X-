# AUTOPSY X — Institutional Trade Intelligence

A single-file (`index.html`) trading desk: an AI-driven multi-asset "Run Autopsy"
analysis engine, a correlation-aware watchlist, a scanner, MT5 connectivity
(direct via MetaApi, or through the self-hosted `server/` bridge), a position
sizing calculator, manual order execution, and a mechanical **VWAP Flip Bot**.

## VWAP Flip Bot

A live implementation of the VWAP Trend Trading rule set from Carlo Zarattini
and Andrew Aziz, *"Volume Weighted Average Price (VWAP): The Holy Grail for
Day Trading Systems"* (SSRN 4631351, November 2023):

- Always in the market during the session: **long** while price trades above
  the running session VWAP, **short** while it trades below.
- **Flip** the position the instant a 1-minute candle *closes* on the other
  side of VWAP — no fixed stop; VWAP itself is the moving stop/flip line.
- **Flat** at 4:00pm ET. No overnight exposure.
- Position sizing in the paper uses 100% of available equity with no
  leverage (the R:R of any given trade is unknowable up front since the stop
  is time-varying, so fixed-percentage risk sizing doesn't apply).

The paper backtests this on 1-minute QQQ and TQQQ (3x leveraged) equity bars,
January 2018–September 2023, with a real traded-volume VWAP and $0.0005/share
commission: $25,000 → $192,656 on QQQ (671%, Sharpe 2.1, 9.4% max drawdown)
and $25,000 → $2,085,417 on TQQQ (8,242%), against a ~126% QQQ buy-and-hold
over the same window with a 37% max drawdown. Hit rate is low (~17%) but
winners average roughly 5.5x the size of losers — this is a trend-following,
asymmetric-payoff system, not a high-accuracy one.

This dashboard's bot feeds off **live MT5 tick data** (via the Live Bridge
server or a direct MetaApi RPC poll), building its own 1-minute bars and
using tick count as a volume proxy, since forex/CFD venues generally don't
report real traded volume the way equities exchanges do. Treat it as the
same rule set live-fired on whatever symbol you point it at — not a
reproduction of the paper's own QQQ/TQQQ backtest, which used real equities
volume and a different commission/spread structure entirely.

**It starts in PAPER mode and stays there until you explicitly arm it.**
Arming requires: MT5 connected, its execution-mode toggle set to LIVE, and
typing `ARM` into a dedicated confirmation field. Once armed, every flip is
fully mechanical — it closes the existing position on that symbol and fires
a market order for a fixed lot size, with no per-trade review. Test on a
demo account before ever pointing it at a live one, and understand that the
paper's own sizing (100% of equity, no fixed stop) is a research finding
about return/risk asymmetry, not a recommendation for how much of an account
to risk on any single instrument.

## AUTOPSY X FLIPDEMON EXTREME (native MT5 EA)

`MQL5/` is a separate, complementary system from the browser-based VWAP
Flip Bot above: a full native MetaTrader 5 Expert Advisor — `SCAN -> SCORE
-> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS` — built from 24 focused
engine modules (momentum, microstructure, liquidity, regime classification,
order flow/volume profile/footprint/heatmap, sniper entry timing, a flip
engine requiring multi-signal confirmation before reversing, an adaptive
capital-protection layer on top of a hard-limit risk engine, execution,
exits, and per-trade CSV trade-autopsy logging), rather than the
dashboard's single VWAP-flip rule set. It runs entirely inside the MT5
terminal — no bridge server, no browser tab open.

Same discipline as the web bot, enforced in MQL5 instead of JS: no
martingale, no averaging down, a risk engine that hard-clamps position size
regardless of input, and a kill switch. **It has not been machine-compiled**
(this repo was built without a MetaEditor available) — compile it yourself
in MetaEditor before attaching it to any chart, and see `MQL5/README.md`
for installation, the module table, risk modes, and the five-phase
backtest → in-sample → out-of-sample → unseen-data → demo-forward
validation workflow it expects before anyone risks real capital on it.

## AutopsyXFlipdemonX15.mq5 (native MT5 autonomous EA)

A third, separate system, also under `MQL5/Experts/AutopsyX/`: a
fail-closed autonomous EA whose layers run strictly in order.

    DATA -> STRUCTURE / LIQUIDITY / REGIME / SESSION / NEWS GATE
         -> VWAP + VP-MACD -> COMPOSITE DECISION -> EXECUTION ELIGIBILITY
         -> RISK -> ORDER -> POSITION MANAGEMENT -> JOURNAL -> ADAPTATION

**It starts in `ANALYSIS_ONLY`.** It analyses, validates and reports every
bar, and sends nothing. `PAPER_EXECUTION` runs virtual fills through the
same management and journal. `LIVE_EXECUTION` sends real orders via
`CTrade`.

**It has not been compiled or run in the Strategy Tester by its author.**
No MetaEditor was reachable from the environment it was written in, so it
was verified with static checks and Python ports of its core logic
instead. Compile it, backtest it, and run it on PAPER and demo before ever
selecting LIVE.

What it does:

- **Setups.** Two models: sweep reversal (liquidity sweep, displacement,
  MSS, retrace into an FVG/OB, confirmation) and HTF continuation. Both
  run on closed bars only and may fire only on the most recent one.
- **Decisions.** Every decision is a named list of PASS / FAIL /
  UNAVAILABLE evidence, and every NO TRADE shows its blocking gate on the
  chart.
- **Duplicate protection.** A deterministic setup ID is written to disk
  *before* sending. An ambiguous send result (timeout, lost connection)
  blocks the setup and is never resent. On restart, executed setups are
  recovered from the broker's own order history.
- **Hard limits no bonus can pass.** Position counts, total open risk,
  daily and weekly loss (from deal history, so a restart can't reset
  them), a consecutive-loss pause, spread, margin, tick age and broker
  permissions.
- **Risk.** Volume is sized from equity and validated with the broker's
  `OrderCalcProfit`. A size below the broker minimum is refused, never
  rounded up.
- **Management.** Break-even, partial close, structure/ATR/fixed-R/VWAP
  trailing, and invalidation and time exits.
- **Journal.** One row per closed position, deduplicated by position ID.
  Learning uses only this EA's own completed trades.
- **Reports only.** Monte Carlo and the Kelly ruin bound are shown on the
  dashboard and never touch position size.

It still keeps every external signal on probation: VWAP and VP-MACD only
ever earn a sizing bonus through the journal's own logged, out-of-sample
track record, never through the credibility of the paper they're based
on. The three signal engines:

- **VWAP trend** (Zarattini & Aziz, SSRN 4631351 — the same paper behind
  the browser VWAP Flip Bot above), gated on its own ≥20-trade aligned
  subset with positive expectancy before its sizing bonus applies.
- **VP-MACD** (Lin, Lin, Zhang, Zheng & Wang, arXiv:2604.26063) — a
  volume/volatility/candle-structure adjusted price feeding an
  asymmetric-sensitivity MACD crossover, gated the same independent way.
  Untested on gold/FX in the source paper, independent-researcher
  authorship, mixed results even in its own equity backtests — all stated
  plainly in the file.
- **News Defense** (Martins & Lopes, QREF 2025 / arXiv:2411.16244) —
  suppresses *new* entries (never touches existing positions) within 30
  minutes of one of nine Bayesian-validated USD/AUD macro events, via the
  real MQL5 Economic Calendar API, with a clearly-marked lower-confidence
  fallback for every other currency. The one engine here that defaults ON
  rather than off, since it can only ever suppress risk, never add it.

Sizing bonuses default to inert (no bonus without a real track record),
News Defense defaults on for the reason above, and the whole EA defaults to
`ANALYSIS_ONLY`. Full detail, citations and caveats live in the file's own
header and section comments rather than being duplicated here.

## Everything else

See `server/README.md` for the self-hosted bridge server (keeps your
Anthropic API key off the browser, and lets an MT5 Expert Advisor push
tick/account data in over HTTP). `render.yaml` deploys both the static
dashboard and the bridge as a Render Blueprint.

None of this is investment advice. The AI analysis panels, the scanner, and
the flip bot are all research/execution tools you are responsible for
verifying against your own broker terminal before acting on.
