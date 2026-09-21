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

## Everything else

See `server/README.md` for the self-hosted bridge server (keeps your
Anthropic API key off the browser, and lets an MT5 Expert Advisor push
tick/account data in over HTTP). `render.yaml` deploys both the static
dashboard and the bridge as a Render Blueprint.

None of this is investment advice. The AI analysis panels, the scanner, and
the flip bot are all research/execution tools you are responsible for
verifying against your own broker terminal before acting on.
