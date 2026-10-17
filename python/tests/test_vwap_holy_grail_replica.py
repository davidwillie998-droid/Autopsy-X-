"""Regression tests for the research-only VWAP paper replication."""
import unittest
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from research.vwap_holy_grail.replica import Bar, Config, backtest, validate_bars, parse_timestamp

ET = ZoneInfo("America/New_York")


def bar(minute, open_, high, low, close, volume=100.0, day=2):
    ts = datetime(2024, 1, day, 9, 30, tzinfo=ET) + timedelta(minutes=minute)
    return Bar(ts, open_, high, low, close, volume)


class VwapHolyGrailReplicaTests(unittest.TestCase):
    def test_paper_close_model_enters_on_close_side_and_flattens_intraday(self):
        bars = [
            bar(0, 100, 102, 100, 102),
            bar(1, 102, 102, 100, 100.5),
            bar(2, 100.5, 102, 100, 101),
        ]
        report = backtest(bars, Config(fill_model="paper_close"))
        self.assertEqual(report["session_count"], 1)
        self.assertEqual(report["closed_trades"], 2)
        self.assertIn("T09:31:00", report["trades"][0]["entry_time"])
        self.assertIn("T09:32:00", report["trades"][0]["exit_time"])
        self.assertIn("T09:33:00", report["trades"][-1]["exit_time"])
        self.assertEqual(report["trades"][-1]["exit_reason"], "SESSION_CLOSE")
        self.assertEqual(report["equity_curve"][-1]["direction"], 0)
        self.assertGreater(report["commission_paid"], 0)
        self.assertEqual(report["incomplete_sessions"], ["2024-01-02"])

    def test_next_open_model_delays_fill_until_after_signal_bar(self):
        bars = [
            bar(0, 100, 102, 100, 102),
            bar(1, 102, 103, 101, 102.5),
            bar(2, 102.5, 103, 101, 102),
        ]
        report = backtest(bars, Config(fill_model="next_open"))
        self.assertEqual(report["closed_trades"], 1)
        self.assertEqual(report["trades"][0]["entry_price"], 102)
        self.assertEqual(report["trades"][0]["exit_reason"], "SESSION_CLOSE")

    def test_flat_price_equal_to_vwap_does_not_create_trades(self):
        bars = [bar(i, 100, 100, 100, 100) for i in range(3)]
        report = backtest(bars)
        self.assertEqual(report["closed_trades"], 0)
        self.assertEqual(report["final_equity"], 25_000)

    def test_long_only_never_opens_short(self):
        bars = [
            bar(0, 100, 102, 100, 102),
            bar(1, 102, 102, 99, 99),
            bar(2, 99, 100, 98, 98),
        ]
        report = backtest(bars, Config(allow_short=False))
        self.assertTrue(all(t["direction"] == "LONG" for t in report["trades"]))

    def test_missing_one_minute_bar_marks_session_incomplete(self):
        bars = [
            bar(0, 100, 102, 100, 102),
            bar(2, 102, 103, 101, 102.5),
            bar(3, 102.5, 103, 101, 102),
        ]
        report = backtest(bars)
        self.assertEqual(report["incomplete_sessions"], ["2024-01-02"])

    def test_rejects_naive_timestamp(self):
        with self.assertRaises(ValueError):
            parse_timestamp("2024-01-02T09:30:00")

    def test_rejects_duplicate_or_out_of_order_bars(self):
        one = bar(0, 100, 101, 99, 100)
        with self.assertRaises(ValueError):
            validate_bars([one, one])

    def test_rejects_invalid_ohlc_envelope(self):
        with self.assertRaises(ValueError):
            validate_bars([bar(0, 100, 99, 98, 100)])

    def test_config_disallows_leveraged_position_fraction(self):
        with self.assertRaises(ValueError):
            backtest([bar(0, 100, 101, 99, 100)], Config(position_fraction=1.01))


if __name__ == "__main__":
    unittest.main()
