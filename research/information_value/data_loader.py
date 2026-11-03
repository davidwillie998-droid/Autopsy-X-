"""Phase 5 real-data loader: XAUUSD (close-only) + EUR/USD (OHLC).

Loads the raw Alpha Vantage exports committed under
`research/information_value/data/` (retrieved once, never re-derived - see
`docs/PHASE5_DATA_PROVENANCE.md` for the full provenance record) into a
single, clean, chronologically-sorted, weekday-only joint DataFrame.

WHY WEEKDAY-ONLY (see the provenance doc's own finding): the XAUUSD series
contains 1,410 weekend-dated rows (26% of the series) that behave like an
interpolated/smoothed construction rather than raw executed trades (a small
genuine Friday->Saturday drift, then an EXACT Saturday->Sunday plateau in
every case checked) - left in, they would inject an artificial autocorrelation
component into exactly the return-based statistics this phase needs to test
honestly (VolatilitySerialityEngine's own autocorrelation/persistence/
reversal metrics). They are dropped here, not silently averaged in.

WHAT THIS MODULE DOES NOT DO: it does not fabricate OHLC for XAUUSD, does
not interpolate missing joint dates, and does not compute any engine-level
feature - that belongs in unit_of_analysis.py. This module's only job is:
raw files in, one clean joint price/return DataFrame out.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

DATA_DIR = Path(__file__).resolve().parent / "data"
XAU_RAW_PATH = DATA_DIR / "xauusd_daily_raw_alphavantage.json"
EUR_RAW_PATH = DATA_DIR / "eurusd_daily_raw_alphavantage.json"


@dataclass(frozen=True)
class DataQualityReport:
    xau_rows_raw: int
    xau_rows_weekend_dropped: int
    xau_rows_duplicate_dropped: int
    eur_rows_raw: int
    eur_rows_ohlc_inconsistent_dropped: int
    joint_rows: int
    date_min: str
    date_max: str


def _load_xau_weekday_closes(path: Path = XAU_RAW_PATH) -> tuple[pd.DataFrame, int, int]:
    raw = json.loads(path.read_text())
    rows = raw["data"]
    df = pd.DataFrame(rows)
    df["date"] = pd.to_datetime(df["date"])
    df["price"] = df["price"].astype(float)
    n_raw = len(df)

    n_dupe = int(df["date"].duplicated().sum())
    df = df.drop_duplicates(subset="date", keep="first")

    is_weekend = df["date"].dt.weekday >= 5
    n_weekend = int(is_weekend.sum())
    df = df.loc[~is_weekend].copy()

    df = df.sort_values("date").reset_index(drop=True)
    df = df.rename(columns={"price": "xau_close"})
    return df[["date", "xau_close"]], n_weekend, n_dupe


def _load_eur_ohlc(path: Path = EUR_RAW_PATH) -> tuple[pd.DataFrame, int]:
    raw = json.loads(path.read_text())
    series = raw["Time Series FX (Daily)"]
    records = []
    for date_str, row in series.items():
        records.append({
            "date": date_str,
            "eur_open": float(row["1. open"]),
            "eur_high": float(row["2. high"]),
            "eur_low": float(row["3. low"]),
            "eur_close": float(row["4. close"]),
        })
    df = pd.DataFrame(records)
    df["date"] = pd.to_datetime(df["date"])
    n_raw = len(df)

    ok = (
        (df["eur_low"] <= df["eur_open"]) & (df["eur_open"] <= df["eur_high"])
        & (df["eur_low"] <= df["eur_close"]) & (df["eur_close"] <= df["eur_high"])
        & (df["eur_open"] > 0) & (df["eur_high"] > 0) & (df["eur_low"] > 0) & (df["eur_close"] > 0)
    )
    n_bad = int((~ok).sum())
    df = df.loc[ok].sort_values("date").reset_index(drop=True)
    return df, n_bad


def load_joint_dataset() -> tuple[pd.DataFrame, DataQualityReport]:
    """Returns (df, report). df is indexed by ascending `date`, columns:
    xau_close, eur_open/high/low/close, xau_log_return, eur_log_return.
    Only dates present in BOTH series survive the inner join - see
    docs/PHASE5_DATA_PROVENANCE.md for the resulting joint sample size."""
    xau, n_weekend, n_dupe = _load_xau_weekday_closes()
    eur, n_bad_ohlc = _load_eur_ohlc()

    joint = pd.merge(xau, eur, on="date", how="inner").sort_values("date").reset_index(drop=True)

    joint["xau_log_return"] = np.log(joint["xau_close"] / joint["xau_close"].shift(1))
    joint["eur_log_return"] = np.log(joint["eur_close"] / joint["eur_close"].shift(1))

    report = DataQualityReport(
        xau_rows_raw=len(xau) + n_weekend + n_dupe,
        xau_rows_weekend_dropped=n_weekend,
        xau_rows_duplicate_dropped=n_dupe,
        eur_rows_raw=len(eur) + n_bad_ohlc,
        eur_rows_ohlc_inconsistent_dropped=n_bad_ohlc,
        joint_rows=len(joint),
        date_min=str(joint["date"].min().date()) if len(joint) else "",
        date_max=str(joint["date"].max().date()) if len(joint) else "",
    )
    return joint, report


if __name__ == "__main__":
    df, report = load_joint_dataset()
    print(report)
    print(df.head())
    print(df.tail())
