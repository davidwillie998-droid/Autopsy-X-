"""Reference tests for completed-position win-rate aggregation.

Net results are already after commission, swap and other recorded costs.
These tests validate arithmetic semantics, not MQL5 compilation or runtime.
"""
import unittest
from collections import defaultdict


def summarize(records):
    # Each row: (position_id, net_profit, gross_profit, is_partial, exit_day)
    groups = defaultdict(lambda: {"net": 0.0, "gross": 0.0, "final": False, "exit_day": None})
    daily = 0.0
    lifetime = 0.0
    for pid, net, gross, partial, exit_day in records:
        item = groups[pid]
        item["net"] += net
        item["gross"] += gross
        if not partial:
            item["final"] = True
            item["exit_day"] = exit_day
        lifetime += net
        if exit_day == "TODAY":
            daily += net
    closed = [v for v in groups.values() if v["final"]]
    wins = sum(v["net"] > 0 for v in closed)
    losses = sum(v["net"] < 0 for v in closed)
    breakeven = sum(v["net"] == 0 for v in closed)
    decisive = wins + losses
    return {
        "trades": len(closed), "wins": wins, "losses": losses,
        "breakeven": breakeven,
        "win_rate": 100.0 * wins / decisive if decisive else 0.0,
        "lifetime": lifetime, "daily": daily,
    }


class CampaignWinRateTests(unittest.TestCase):
    def test_profitable_scale_out_offsets_losing_final_slice(self):
        r = summarize([(1001, 8.0, 8.0, True, "YESTERDAY"),
                       (1001, -3.0, -3.0, False, "TODAY")])
        self.assertEqual(r["trades"], 1)
        self.assertEqual(r["wins"], 1)
        self.assertEqual(r["win_rate"], 100.0)
        self.assertEqual(r["lifetime"], 5.0)

    def test_losing_scale_out_and_final_slice_count_once(self):
        r = summarize([(1002, -2.0, -2.0, True, "TODAY"),
                       (1002, -3.0, -3.0, False, "TODAY")])
        self.assertEqual(r["trades"], 1)
        self.assertEqual(r["losses"], 1)
        self.assertEqual(r["win_rate"], 0.0)

    def test_multiple_positions_are_separate_campaigns(self):
        r = summarize([(1, 4.0, 4.0, True, "TODAY"),
                       (1, 1.0, 1.0, False, "TODAY"),
                       (2, -2.0, -2.0, False, "TODAY")])
        self.assertEqual(r["trades"], 2)
        self.assertEqual(r["wins"], 1)
        self.assertEqual(r["losses"], 1)
        self.assertEqual(r["win_rate"], 50.0)

    def test_breakeven_campaign_excluded_from_decisive_denominator(self):
        r = summarize([(3, 2.0, 2.0, True, "TODAY"),
                       (3, -2.0, -2.0, False, "TODAY"),
                       (4, 5.0, 5.0, False, "TODAY")])
        self.assertEqual(r["trades"], 2)
        self.assertEqual(r["breakeven"], 1)
        self.assertEqual(r["win_rate"], 100.0)

    def test_daily_pnl_is_not_lifetime_pnl(self):
        r = summarize([(5, 10.0, 10.0, False, "YESTERDAY"),
                       (6, -3.0, -3.0, False, "TODAY")])
        self.assertEqual(r["lifetime"], 7.0)
        self.assertEqual(r["daily"], -3.0)


if __name__ == "__main__":
    unittest.main()
