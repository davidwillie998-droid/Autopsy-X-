"""Reference tests for AUTOPSY X decisive-trade win-rate semantics.

These tests validate intended arithmetic only. They do not compile or execute MQL5.
"""
import unittest


def summarize(outcomes):
    """Each outcome is (net_profit, is_partial); costs are already included."""
    full = [profit for profit, partial in outcomes if not partial]
    wins = sum(1 for profit in full if profit > 0)
    losses = sum(1 for profit in full if profit < 0)
    break_even = sum(1 for profit in full if profit == 0)
    decisive = wins + losses
    win_rate = 100.0 * wins / decisive if decisive else 0.0
    return {
        "total": len(full),
        "wins": wins,
        "losses": losses,
        "break_even": break_even,
        "decisive": decisive,
        "win_rate": win_rate,
    }


class WinRateSemanticsTests(unittest.TestCase):
    def test_break_even_is_excluded_from_decisive_win_rate(self):
        result = summarize([(10, False), (-5, False), (0, False)])
        self.assertEqual(result["total"], 3)
        self.assertEqual(result["break_even"], 1)
        self.assertEqual(result["decisive"], 2)
        self.assertEqual(result["win_rate"], 50.0)

    def test_partial_profit_does_not_inflate_win_rate(self):
        result = summarize([(2, True), (10, False), (-5, False)])
        self.assertEqual(result["total"], 2)
        self.assertEqual(result["wins"], 1)
        self.assertEqual(result["win_rate"], 50.0)

    def test_net_after_costs_controls_classification(self):
        result = summarize([(0.01, False), (-0.01, False), (0.0, False)])
        self.assertEqual(result["wins"], 1)
        self.assertEqual(result["losses"], 1)
        self.assertEqual(result["break_even"], 1)
        self.assertEqual(result["win_rate"], 50.0)

    def test_all_break_even_has_no_decisive_win_rate(self):
        result = summarize([(0.0, False), (0.0, False)])
        self.assertEqual(result["decisive"], 0)
        self.assertEqual(result["win_rate"], 0.0)

    def test_combined_instrument_records_produce_one_overall_rate(self):
        result = summarize([(1, False), (1, False), (-1, False), (-1, False), (0, False)])
        self.assertEqual(result["total"], 5)
        self.assertEqual(result["win_rate"], 50.0)


if __name__ == "__main__":
    unittest.main()
