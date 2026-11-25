"""Deterministic mathematical reference tests for the MQL5 Hawkes engine.

These tests validate the intended bivariate exponential process and event
threshold semantics. They do not execute or compile MQL5 source.
"""
import math
import unittest


class HawkesReference:
    def __init__(self, mu_buy=0.05, mu_sell=0.05, alpha_bb=0.12,
                 alpha_bs=0.04, alpha_sb=0.04, alpha_ss=0.12,
                 beta=1.0, min_move_points=0.0, min_events=2):
        self.mu_buy = mu_buy
        self.mu_sell = mu_sell
        self.alpha_bb = alpha_bb
        self.alpha_bs = alpha_bs
        self.alpha_sb = alpha_sb
        self.alpha_ss = alpha_ss
        self.beta = beta
        self.threshold = min_move_points
        self.min_events = min_events
        self.reset()
        row_buy = (alpha_bb + alpha_bs) / beta if beta > 0 else math.inf
        row_sell = (alpha_sb + alpha_ss) / beta if beta > 0 else math.inf
        self.valid_config = (
            all(math.isfinite(x) for x in (
                mu_buy, mu_sell, alpha_bb, alpha_bs, alpha_sb, alpha_ss,
                beta, min_move_points
            ))
            and min(mu_buy, mu_sell, alpha_bb, alpha_bs, alpha_sb,
                    alpha_ss, min_move_points) >= 0
            and beta > 0 and max(row_buy, row_sell) < 0.95
        )

    def reset(self):
        self.buy_state = 0.0
        self.sell_state = 0.0
        self.last_msc = None
        self.last_seq = 0
        self.reference_mid = None
        self.events = 0

    def update(self, msc, sequence, mid, point=1.0):
        if not self.valid_config:
            return None
        if msc <= 0 or sequence <= self.last_seq or point <= 0:
            return None
        if self.last_msc is None:
            self.last_msc, self.last_seq = msc, sequence
            self.reference_mid = mid
            return None
        if msc < self.last_msc:
            return None

        decay = math.exp(-self.beta * (msc - self.last_msc) / 1000.0)
        self.buy_state *= decay
        self.sell_state *= decay
        move = mid - self.reference_mid
        direction = 0
        if self.threshold == 0:
            direction = 1 if move > 0 else (-1 if move < 0 else 0)
        elif abs(move / point) >= self.threshold:
            direction = 1 if move > 0 else -1

        if direction > 0:
            self.buy_state += 1.0
            self.events += 1
        elif direction < 0:
            self.sell_state += 1.0
            self.events += 1

        if self.threshold == 0 or direction != 0:
            self.reference_mid = mid

        self.last_msc, self.last_seq = msc, sequence
        buy = self.mu_buy + self.alpha_bb * self.buy_state + self.alpha_bs * self.sell_state
        sell = self.mu_sell + self.alpha_sb * self.buy_state + self.alpha_ss * self.sell_state
        total = buy + sell
        return {
            "buy": buy,
            "sell": sell,
            "imbalance": (buy - sell) / total if total else 0.0,
            "events": self.events,
            "ready": self.events >= self.min_events,
        }


class HawkesReferenceTests(unittest.TestCase):
    def make_engine(self, **kwargs):
        engine = HawkesReference(**kwargs)
        self.assertTrue(engine.valid_config)
        return engine

    def test_upward_events_increase_buy_intensity(self):
        e = self.make_engine()
        e.update(1000, 1, 100.0)
        result = e.update(1100, 2, 101.0)
        self.assertGreater(result["buy"], result["sell"])
        self.assertEqual(result["events"], 1)

    def test_downward_events_increase_sell_intensity(self):
        e = self.make_engine()
        e.update(1000, 1, 100.0)
        result = e.update(1100, 2, 99.0)
        self.assertGreater(result["sell"], result["buy"])

    def test_exponential_decay_without_new_event(self):
        e = self.make_engine()
        e.update(1000, 1, 100.0)
        first = e.update(1100, 2, 101.0)
        later = e.update(2100, 3, 101.0)
        self.assertLess(later["buy"], first["buy"])
        self.assertEqual(later["events"], first["events"])

    def test_small_moves_accumulate_to_threshold(self):
        e = self.make_engine(min_move_points=3.0)
        e.update(1000, 1, 100.0, point=1.0)
        self.assertEqual(e.update(1100, 2, 101.0, point=1.0)["events"], 0)
        self.assertEqual(e.update(1200, 3, 102.0, point=1.0)["events"], 0)
        result = e.update(1300, 4, 103.0, point=1.0)
        self.assertEqual(result["events"], 1)
        self.assertGreater(result["buy"], result["sell"])

    def test_reversal_is_measured_from_last_event_reference(self):
        e = self.make_engine(min_move_points=2.0)
        e.update(1000, 1, 100.0)
        up = e.update(1100, 2, 102.0)
        down = e.update(1200, 3, 100.0)
        self.assertEqual(up["events"], 1)
        self.assertEqual(down["events"], 2)
        self.assertGreater(down["sell"], e.mu_sell)

    def test_duplicate_sequence_is_rejected(self):
        e = self.make_engine()
        e.update(1000, 1, 100.0)
        self.assertIsNone(e.update(1100, 1, 101.0))
        self.assertEqual(e.events, 0)

    def test_stability_boundary_is_enforced(self):
        unstable = HawkesReference(alpha_bb=0.8, alpha_bs=0.2,
                                   alpha_sb=0.1, alpha_ss=0.1, beta=1.0)
        self.assertFalse(unstable.valid_config)

    def test_nan_configuration_is_rejected(self):
        invalid = HawkesReference(mu_buy=float("nan"))
        self.assertFalse(invalid.valid_config)

    def test_warmup_is_not_ready_until_minimum_events(self):
        e = self.make_engine(min_events=2)
        e.update(1000, 1, 100.0)
        first = e.update(1100, 2, 101.0)
        second = e.update(1200, 3, 102.0)
        self.assertFalse(first["ready"])
        self.assertTrue(second["ready"])


if __name__ == "__main__":
    unittest.main()
