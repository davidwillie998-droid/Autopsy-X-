"""Phase 5 forward target construction.

HORIZON SELECTION RULE (documented BEFORE any test is run, per the phase's
own "no threshold cherry-picking" instruction - §5/§26 of the authorization):
the only real data obtained (docs/PHASE5_DATA_PROVENANCE.md) is DAILY
XAUUSD/EURUSD, not the live EA's own intraday timeframe. Horizons are
therefore chosen purely from what daily data can support, not from peeking
at which horizon produces the strongest result:

  H1 =  1 trading day   (next close)
  H2 =  5 trading days  (one trading week)
  H3 = 20 trading days  (~one trading month)

These three are fixed for the entire phase. No other horizon is tested
without being added here first, before any target/feature correlation is
computed, and documented as an addition (not a replacement) if it is.

SCALE CAVEAT (must accompany every result derived from these targets): this
research characterizes whether these engines' underlying CONCEPTS (regime
persistence, return serial dependence, cross-asset lead-lag) carry
information at DAILY granularity. It is not a validation of the live EA,
which is not configured to run on a single fixed timeframe across all its
engines (checked directly: InpRegimeTimeframe defaults to PERIOD_M1,
InpHtfTimeframe to PERIOD_H1, InpFootprintTimeframe to PERIOD_M1, and the
Phase 3/4A engines' own Configure() defaults are PERIOD_M5) - none of which
is daily. Any real-market finding here is scoped to "at daily granularity,"
never generalized to intraday behavior without separate intraday data.

TARGET FAMILY (smallest defensible set - §12): forward normalized return
only, at each of H1/H2/H3. Normalized by a trailing realized-volatility
proxy (NOT real ATR - no OHLC exists for XAU, see data_loader.py), so the
same "raw move, scale-aware" principle used throughout Shock DNA/Volatility
Engine is at least conceptually mirrored, honestly labeled as a proxy.

STRICT TIMESTAMP RULE (§13, verified by test_no_lookahead_in_targets in
test_targets.py): at row t, realized_vol(t) uses only rows <= t. The
forward target itself is deliberately NOT causal (by definition it needs
t+H) and must never be used as a feature - it is consumed only as the
right-hand side of an information-value test, never fed back into any
engine's own state.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

HORIZONS = {"H1": 1, "H2": 5, "H3": 20}
REALIZED_VOL_LOOKBACK = 20  # trading days, causal


def add_realized_vol(df: pd.DataFrame, return_col: str, lookback: int = REALIZED_VOL_LOOKBACK,
                      out_col: str = "realized_vol") -> pd.DataFrame:
    """Trailing rolling stdev of `return_col`, using only rows up to and including
    row t (pandas rolling() is causal by construction: window ends at t, never
    includes t+1). Requires `lookback` prior observations - NaN before that."""
    out = df.copy()
    out[out_col] = out[return_col].rolling(window=lookback, min_periods=lookback).std()
    return out


def add_forward_targets(df: pd.DataFrame, price_col: str, vol_col: str = "realized_vol",
                         horizons: dict[str, int] = HORIZONS) -> pd.DataFrame:
    """Adds, for each horizon name->H in `horizons`:
      fwd_ret_{name}        = log(price[t+H] / price[t])           (raw, unnormalized)
      fwd_ret_norm_{name}   = fwd_ret_{name} / realized_vol(t)      (normalized by CAUSAL vol at t)
    Both are NaN for the final H rows of the frame (no future price exists yet) -
    never filled, never fabricated."""
    out = df.copy()
    log_price = np.log(out[price_col])
    for name, h in horizons.items():
        fwd_col = f"fwd_ret_{name}"
        norm_col = f"fwd_ret_norm_{name}"
        out[fwd_col] = log_price.shift(-h) - log_price
        out[norm_col] = out[fwd_col] / out[vol_col]
    return out


def build_research_frame(df: pd.DataFrame, price_col: str = "xau_close",
                          return_col: str = "xau_log_return") -> pd.DataFrame:
    """Convenience: realized_vol + all forward targets in one call, matching the
    exact column names every downstream Phase 5 module expects."""
    out = add_realized_vol(df, return_col=return_col)
    out = add_forward_targets(out, price_col=price_col)
    return out
