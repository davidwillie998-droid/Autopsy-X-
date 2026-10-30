"""Unit tests for the research-only RSI rotation baseline."""
import importlib.util
from pathlib import Path
import unittest

import pandas as pd

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/research/rsi_rotation_baseline.py"
SPEC = importlib.util.spec_from_file_location("rsi_rotation_baseline", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sample_bars(periods=90):
    rows = []
    timestamps = pd.date_range("2025-01-01", periods=periods, freq="15min", tz="UTC")
    paths = {
        "BENCH": [100.0 + i * 0.03 for i in range(periods)],
        "ALPHA": [100.0 + i * 0.08 for i in range(periods)],
        "BETA": [100.0 + i * 0.01 for i in range(periods)],
    }
    for symbol, closes in paths.items():
        for ts, close in zip(timestamps, closes):
            rows.append({
                "timestamp": ts, "symbol": symbol, "market_family": "FX",
                "open": close - 0.01, "high": close + 0.02,
                "low": close - 0.02, "close": close,
                "h1_alignment": 1 if symbol == "ALPHA" else 0,
                "h4_alignment": 1 if symbol == "ALPHA" else 0,
            })
    return pd.DataFrame(rows)


class TestRSIRotationBaseline(unittest.TestCase):
    def test_produces_rank_only_with_three_instruments_and_htf(self):
        result = MODULE.build_rankings(sample_bars(), {"FX": "BENCH"})
        latest = result[result.timestamp == result.timestamp.max()]
        self.assertEqual(len(latest), 3)
        self.assertEqual(set(latest.score_status), {"SCORED"})
        self.assertEqual(latest.composite_rank.min(), 1.0)

    def test_no_htf_means_no_composite_execution_signal(self):
        bars = sample_bars().drop(columns=["h1_alignment", "h4_alignment"])
        result = MODULE.build_rankings(bars, {"FX": "BENCH"})
        self.assertTrue((result.score_status == "BASELINE_ONLY_HTF_MISSING").all())
        self.assertTrue(result.composite_score.isna().all())

    def test_single_instrument_family_is_not_given_false_perfect_rank(self):
        bars = sample_bars()
        bars = bars[bars.symbol == "ALPHA"]
        result = MODULE.build_rankings(bars, {"FX": "ALPHA"})
        self.assertTrue((result.score_status == "NO_RANK").all())
        self.assertTrue(result.composite_rank.isna().all())

    def test_duplicate_symbol_timestamp_is_rejected(self):
        bars = sample_bars()
        bars = pd.concat([bars, bars.iloc[[0]]], ignore_index=True)
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            MODULE.build_rankings(bars, {"FX": "BENCH"})

    def test_partial_htf_input_is_rejected(self):
        bars = sample_bars().drop(columns=["h4_alignment"])
        with self.assertRaisesRegex(ValueError, "both h1_alignment and h4_alignment"):
            MODULE.build_rankings(bars, {"FX": "BENCH"})

    def test_future_data_does_not_change_past_score(self):
        original = sample_bars()
        cutoff = original.timestamp.sort_values().unique()[-10]
        baseline = MODULE.build_rankings(original, {"FX": "BENCH"})
        mutated = original.copy()
        future = mutated.timestamp > cutoff
        mutated.loc[future, ["open", "high", "low", "close"]] *= 4.0
        changed = MODULE.build_rankings(mutated, {"FX": "BENCH"})
        left = baseline[baseline.timestamp == cutoff].sort_values("symbol")
        right = changed[changed.timestamp == cutoff].sort_values("symbol")
        pd.testing.assert_series_equal(
            left.composite_score.reset_index(drop=True),
            right.composite_score.reset_index(drop=True),
            check_names=False,
        )

    def test_forward_labels_are_separate_from_current_score(self):
        result = MODULE.build_rankings(sample_bars(), {"FX": "BENCH"})
        self.assertIn("forward_return_4", result.columns)
        self.assertIn("composite_score", result.columns)
        self.assertFalse(any("forward_return" in key for key in MODULE.WEIGHTS))


if __name__ == "__main__":
    unittest.main()
