import unittest
from python.autopsy_research.shock_outcome_report import cluster_bootstrap_ci, summarize


class ShockOutcomeReportTests(unittest.TestCase):
    def test_cluster_bootstrap_requires_multiple_event_days(self):
        rows = [{"event_timestamp": 1700000000, "directional_return_pct": 1.0}]
        lo, hi = cluster_bootstrap_ci(rows, iterations=100)
        self.assertTrue(lo != lo and hi != hi)  # NaN without independent clusters

    def test_summary_reports_sample_size_and_grouped_metrics(self):
        rows = [
            {"event_id": "a", "event_timestamp": 1700000000, "symbol": "XAUUSD",
             "timeframe": "M15", "horizon_bars": 1, "direction": 1,
             "onset_magnitude_atr": 2.2, "onset_regime": "TREND_BULL",
             "directional_return_pct": 1.0, "max_favourable_excursion_pct": 2.0,
             "max_adverse_excursion_pct": 0.5},
            {"event_id": "b", "event_timestamp": 1700086400, "symbol": "XAUUSD",
             "timeframe": "M15", "horizon_bars": 1, "direction": 1,
             "onset_magnitude_atr": 2.4, "onset_regime": "TREND_BULL",
             "directional_return_pct": -0.5, "max_favourable_excursion_pct": 0.5,
             "max_adverse_excursion_pct": 1.0},
        ]
        result = summarize(rows, iterations=100)[0]
        self.assertEqual(result["observations"], 2)
        self.assertEqual(result["unique_events"], 2)
        self.assertEqual(result["event_days"], 2)
        self.assertAlmostEqual(result["mean_directional_return_pct"], 0.25)


if __name__ == "__main__":
    unittest.main()
