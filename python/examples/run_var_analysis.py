#!/usr/bin/env python3
"""
Example: run the price-impact VAR/impulse-response pipeline on a CSV
export of trades and quotes.

Expected input format:
  trades.csv: columns time,price,volume
  quotes.csv: columns time,bid,ask
  'time' must parse as a pandas Timestamp (e.g. ISO 8601).

Usage:
  python3 examples/run_var_analysis.py trades.csv quotes.csv [output.json]

This script is the offline RESEARCH path (spec section 31) - it has no
dependency on, and is never called from, anything in MQL5/.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from autopsy_research import report


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    trades_path, quotes_path = sys.argv[1], sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else None

    trades = pd.read_csv(trades_path, parse_dates=["time"])
    quotes = pd.read_csv(quotes_path, parse_dates=["time"])

    result = report.run_price_impact_analysis(trades, quotes)

    print(f"Trades in:            {result.n_trades_raw}")
    print(f"Trades after combine: {result.n_trades_after_combine}")
    print(f"VAR observations:     {result.n_var_observations}")
    print(f"Selected lag:         {result.selected_lag}  (trend='{result.trend}')")
    print(f"VAR stable:           {result.is_stable}")
    if result.notes:
        print("\nNotes:")
        for note in result.notes:
            print(f"  - {note}")

    print("\nOrthogonalized impulse response of quote_change to a net_order_flow shock:")
    for row in result.irf_quote_response_to_order_flow_shock[:6]:
        print(f"  lag {row['lag']:>2}: {row['response']:+.6f}")
    print("  ...")

    if out_path:
        result.to_json(out_path)
        print(f"\nFull report written to {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
