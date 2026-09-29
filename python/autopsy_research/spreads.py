"""
Spread and net-order-flow measures feeding the VAR model.

Source paper findings referenced:
  - item xxiv: "Spread estimation logic computes net order flow and
    effective, absolute, and relative spread measures."
  - item i-v (bid-ask spread has three cost components: order processing,
    inventory, asymmetric information) - the paper NAMES these three
    components but gives no formula to isolate one from another using
    quote/trade data alone; that decomposition is not implemented here
    and is flagged as out of scope rather than faked.
"""
from __future__ import annotations

import numpy as np
import pandas as pd


def quoted_spread(bid: pd.Series, ask: pd.Series) -> pd.Series:
    """Quoted spread = Ask - Bid."""
    return ask - bid


def relative_spread(bid: pd.Series, ask: pd.Series) -> pd.Series:
    """RelativeSpread = (Ask - Bid) / MidPrice."""
    mid = (ask + bid) / 2.0
    return (ask - bid) / mid


def effective_spread(trade_price: pd.Series, mid: pd.Series, direction: pd.Series) -> pd.Series:
    """
    Effective spread = 2 * direction * (trade_price - mid).

    Standard microstructure definition (e.g. Hasbrouck 2007, ch. 3, cited
    in the source paper's reference list as item 7): measures the actual
    cost paid relative to the quote midpoint at the time of the trade,
    signed so a buy executing above mid and a sell executing below mid
    both register as a positive cost.
    """
    return 2.0 * direction * (trade_price - mid)


def net_order_flow(direction: pd.Series, volume: pd.Series) -> pd.Series:
    """
    Signed volume: +volume for buyer-initiated trades, -volume for
    seller-initiated. This is the "net order flow" series the paper's VAR
    model uses as one of its two endogenous variables (findings item xxvii).
    """
    return direction * volume


def resample_var_inputs(
    classified_trades: pd.DataFrame,
    freq: str = "1s",
) -> pd.DataFrame:
    """
    Aggregates classified trades (see trade_direction.classify_trade_direction)
    into fixed time bins suitable for VAR estimation: net order flow summed
    per bin, and the LAST quote midpoint in each bin (its change across bins
    is the "quote change" series).

    The bin frequency is NOT specified by the source paper - it only states
    that "for VAR analysis of price impact of trade on quotes, focus on
    quotes updates within 15 seconds of trade" (findings item xviii), which
    bounds the *estimation window*, not the bar size used to build the two
    time series. The 1-second default here is an ENGINEERING CHOICE made
    for resolution; pass a coarser freq (e.g. "5s") for sparser data.
    """
    df = classified_trades.copy()
    df["net_flow"] = net_order_flow(df["direction"], df["volume"])
    df = df.set_index("time")

    flow = df["net_flow"].resample(freq).sum()
    mid = df["mid"].resample(freq).last().ffill()
    quote_change = mid.diff()

    out = pd.DataFrame({"quote_change": quote_change, "net_order_flow": flow})
    out = out.dropna(subset=["quote_change"])
    return out
