from __future__ import annotations

import random
import unittest

from python.research.flipdemon_monte_carlo import (
    Config,
    binomial_upper_95_zero_or_general,
    equity_path,
    iid_sample,
    run_simulations,
    stationary_sample,
)


class MonteCarloValidationTests(unittest.TestCase):
    def setUp(self):
        self.returns = [1.0, -1.0, 0.5, -0.8, 1.2, -0.4, 0.7, -1.1] * 4

    def test_iid_sample_is_reproducible_and_correct_length(self):
        a = iid_sample(self.returns, 50, random.Random(7))
        b = iid_sample(self.returns, 50, random.Random(7))
        self.assertEqual(a, b)
        self.assertEqual(len(a), 50)

    def test_stationary_bootstrap_preserves_requested_length(self):
        sample = stationary_sample(self.returns, 80, 5.0, random.Random(4))
        self.assertEqual(len(sample), 80)
        self.assertTrue(set(sample).issubset(set(self.returns)))

    def test_equity_path_reports_drawdown_and_losing_streak(self):
        result = equity_path([1.0, -1.0, -1.0, -1.0, 1.0], 1.0)
        self.assertGreater(result["max_drawdown_pct"], 0)
        self.assertEqual(result["longest_losing_streak"], 3)

    def test_equity_path_uses_configured_ruin_threshold(self):
        result = equity_path([-1.0] * 100, 2.0, ruin_equity_pct=90.0)
        self.assertTrue(result["ruin_threshold_breach"])

    def test_equity_path_rejects_invalid_ruin_threshold(self):
        with self.assertRaises(ValueError):
            equity_path([1.0, -1.0], 1.0, ruin_equity_pct=100.0)

    def test_zero_breach_upper_bound_is_nonzero_and_below_one(self):
        upper = binomial_upper_95_zero_or_general(0, 20_000)
        self.assertGreater(upper, 0)
        self.assertLess(upper, 0.001)

    def test_reports_both_method_and_reproducible_results(self):
        config = Config(paths=200, risk_pct=0.25, seed=11)
        iid_a = run_simulations(self.returns, config, "iid")
        iid_b = run_simulations(self.returns, config, "iid")
        stationary = run_simulations(self.returns, config, "stationary")
        self.assertEqual(iid_a, iid_b)
        self.assertEqual(iid_a["method"], "iid")
        self.assertEqual(stationary["method"], "stationary")
        self.assertIn("expected_shortfall_worst_5pct", stationary["max_drawdown_pct"])
        self.assertIn("not replay", stationary["warning"])

    def test_rejects_invalid_risk_and_sample_size(self):
        with self.assertRaises(ValueError):
            equity_path([1, -1], 2.5)
        with self.assertRaises(ValueError):
            run_simulations([1.0, -1.0], Config(paths=100), "iid")


if __name__ == "__main__":
    unittest.main()
