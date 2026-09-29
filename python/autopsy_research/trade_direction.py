"""
Trade-direction inference: the tick test (T) and quote test (Q).

Source: Lee, C. and Ready, M. "Inferring Trade Direction from Intraday Data",
Journal of Finance, 46 (1991), 733-746 - reference [11] in the source paper,
and explicitly named there ("Tick test T and quote test Q are used to infer
trade direction, i.e., buy or sell, from TAQ trade").

Definitions, taken directly from the source paper's own bullet points:
  T (tick test): a trade is buyer-initiated if its price is ABOVE the
    previous trade's price, seller-initiated if BELOW. A trade at the same
    price as the previous one inherits the previous trade's classification
    (the standard "zero-tick" convention in the Lee & Ready literature -
    the source paper does not spell out the zero-tick rule explicitly, so
    that specific inheritance behavior is an engineering choice, flagged
    below).
  Q (quote test): a trade is buyer-initiated if its price is ABOVE the
    prevailing quote midpoint, seller-initiated if BELOW.

The source paper also states: "each trade is preceded by prevailing quote
in effect before the trade" and, for matching trades to quotes, a
convention of comparing trade time against quotes recorded up to 5 seconds
BEFORE the trade (Lee & Ready's own well-known convention, restated in the
source paper as "trades are typically entered with a delay of 5 seconds
consistent with practice").
"""
from __future__ import annotations

import numpy as np
import pandas as pd

# Paper-sourced default (Lee & Ready 1991 convention, restated in the source
# paper's own findings list, item xix).
DEFAULT_QUOTE_LAG_SECONDS = 5.0


def match_trades_to_quotes(
    trades: pd.DataFrame,
    quotes: pd.DataFrame,
    quote_lag_seconds: float = DEFAULT_QUOTE_LAG_SECONDS,
) -> pd.DataFrame:
    """
    For each trade, find the prevailing quote in effect BEFORE the trade,
    using the standard Lee & Ready convention of looking at quotes as of
    (trade_time - quote_lag_seconds) rather than the literal most recent
    quote, since retail/HF feeds can report trades and quotes with enough
    jitter that a naive "most recent quote" match would sometimes pick a
    quote that postdates the trade's true decision point.

    Parameters
    ----------
    trades : DataFrame with columns ['time', 'price', 'volume']
        'time' must be a tz-aware or tz-naive pandas Timestamp column,
        sorted ascending.
    quotes : DataFrame with columns ['time', 'bid', 'ask']
        Sorted ascending by 'time'.
    quote_lag_seconds : float
        Paper-sourced default is 5.0 seconds (see module docstring).

    Returns
    -------
    DataFrame: trades with additional columns ['bid', 'ask', 'mid']
        for the matched prevailing quote. Rows with no quote available
        yet (trade occurs before the first quote) get NaN - never a
        fabricated placeholder quote.
    """
    trades = trades.sort_values("time").reset_index(drop=True)
    quotes = quotes.sort_values("time").reset_index(drop=True)

    lookup_time = trades["time"] - pd.Timedelta(seconds=quote_lag_seconds)
    idx = np.searchsorted(quotes["time"].values, lookup_time.values, side="right") - 1

    out = trades.copy()
    valid = idx >= 0
    out["bid"] = np.nan
    out["ask"] = np.nan
    out.loc[valid, "bid"] = quotes["bid"].values[idx[valid]]
    out.loc[valid, "ask"] = quotes["ask"].values[idx[valid]]
    out["mid"] = (out["bid"] + out["ask"]) / 2.0
    return out


def combine_same_time_price_trades(trades: pd.DataFrame) -> pd.DataFrame:
    """
    "All trades having same price and time in seconds are combined assuming
    they are part of same order" (source paper, findings item xxiii).

    Aggregates volume, keeps the first row's other fields, and rounds the
    trade timestamp to whole seconds before grouping, exactly matching the
    paper's own stated granularity ("same price and time in seconds").
    """
    df = trades.copy()
    df["_time_sec"] = df["time"].dt.floor("s")
    grouped = (
        df.groupby(["_time_sec", "price"], as_index=False)
        .agg({**{c: "first" for c in df.columns if c not in ("volume",)}, "volume": "sum"})
        .drop(columns=["_time_sec"])
        .sort_values("time")
        .reset_index(drop=True)
    )
    return grouped


def tick_test(trades: pd.DataFrame) -> pd.Series:
    """
    Tick test (T): +1 (buyer-initiated) if price > previous trade price,
    -1 (seller-initiated) if price < previous trade price. A trade at the
    same price as the previous one inherits the previous classification
    (zero-tick rule) - this specific inheritance behavior is an ENGINEERING
    CHOICE (the paper names the tick test but does not spell out the
    zero-tick convention), following the standard treatment in the wider
    Lee & Ready literature the paper cites.

    Parameters
    ----------
    trades : DataFrame with a 'price' column, sorted ascending by time.

    Returns
    -------
    Series of {+1, -1, 0}: 0 only for the very first trade, which has no
    prior trade to compare against and is therefore genuinely unclassifiable
    by this method - never guessed as +1 or -1.
    """
    price = trades["price"].to_numpy()
    direction = np.zeros(len(price), dtype=int)
    last_nonzero = 0
    for i in range(1, len(price)):
        if price[i] > price[i - 1]:
            direction[i] = 1
            last_nonzero = 1
        elif price[i] < price[i - 1]:
            direction[i] = -1
            last_nonzero = -1
        else:
            direction[i] = last_nonzero
    return pd.Series(direction, index=trades.index, name="tick_direction")


def quote_test(trades_with_quotes: pd.DataFrame) -> pd.Series:
    """
    Quote test (Q): +1 (buyer-initiated) if trade price > quote midpoint,
    -1 (seller-initiated) if trade price < quote midpoint, 0 (at-the-midpoint,
    unclassifiable by this method alone) if trade price == midpoint.

    Requires 'price' and 'mid' columns (see match_trades_to_quotes()).
    """
    price = trades_with_quotes["price"].to_numpy()
    mid = trades_with_quotes["mid"].to_numpy()
    direction = np.where(price > mid, 1, np.where(price < mid, -1, 0))
    return pd.Series(direction, index=trades_with_quotes.index, name="quote_direction")


def classify_trade_direction(
    trades: pd.DataFrame,
    quotes: pd.DataFrame,
    quote_lag_seconds: float = DEFAULT_QUOTE_LAG_SECONDS,
) -> pd.DataFrame:
    """
    Runs both T and Q, and produces a combined 'direction' column using the
    quote test as primary (the paper's own methodology treats Q as the more
    information-rich test since it uses the actual bid/ask, not just price
    history) with a fallback to the tick test wherever the quote test is 0
    or unavailable (no matched quote). This T-as-fallback-to-Q combination
    is an ENGINEERING CHOICE - the paper lists both tests without specifying
    how to combine them when they disagree or when one is unavailable.
    """
    combined = combine_same_time_price_trades(trades)
    with_quotes = match_trades_to_quotes(combined, quotes, quote_lag_seconds)
    with_quotes["tick_direction"] = tick_test(with_quotes)
    with_quotes["quote_direction"] = quote_test(with_quotes)

    q = with_quotes["quote_direction"].to_numpy()
    t = with_quotes["tick_direction"].to_numpy()
    final = np.where(q != 0, q, t)
    with_quotes["direction"] = final
    return with_quotes
