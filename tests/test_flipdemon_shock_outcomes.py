"""Deterministic tests for forward shock-event outcome measurement."""
from dataclasses import dataclass
from enum import Enum
import unittest

from python.autopsy_research.shock_outcomes import ShockOutcomeTracker


class State(str, Enum):
    ONSET = "ONSET"
    IMPULSE = "IMPULSE"
    ABSORPTION = "ABSORPTION"
    NORMALIZING = "NORMALIZING"


@dataclass
class Snapshot:
    valid: bool = True
    data_quality_ok: bool = True
    shock_detected: bool = False
    shock_state: State = State.IMPULSE
    direction: int = 0
    persistence_bars: int = 1
    normalized_magnitude: float = 1.8
    event_magnitude_atr: float = 1.9
    confidence: float = 75.0
    regime: str = "TREND_BULL"
    regime_strength: float = 80.0
    transmission_available: bool = True
    cross_asset_confirmation: bool | None = True


def bar(tracker, timestamp, close, high=None, low=None, snapshot=None, symbol="XAUUSD"):
    high = high if high is not None else close
    low = low if low is not None else close
    return tracker.update(
        symbol=symbol, timeframe="M15", timestamp=timestamp,
        open_price=close, high=high, low=low, close=close,
        snapshot=snapshot or Snapshot(),
    )


class ShockOutcomeTrackerTests(unittest.TestCase):
    def test_emits_only_after_completed_forward_horizon(self):
        tracker = ShockOutcomeTracker((1, 3))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0)
        self.assertEqual(bar(tracker, 100, 100, snapshot=onset), [])
        self.assertEqual(tracker.active_event_count, 1)
        first = bar(tracker, 200, 101, high=102, low=99)
        self.assertEqual([x.horizon_bars for x in first], [1])
        self.assertAlmostEqual(first[0].directional_return_pct, 1.0)
        self.assertAlmostEqual(first[0].max_favourable_excursion_pct, 2.0)
        self.assertAlmostEqual(first[0].max_adverse_excursion_pct, -1.0)
        self.assertEqual(bar(tracker, 300, 100.5), [])
        third = bar(tracker, 400, 102)
        self.assertEqual([x.horizon_bars for x in third], [3])
        self.assertEqual(tracker.active_event_count, 0)

    def test_bearish_event_returns_are_direction_adjusted(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=-1, persistence_bars=0)
        bar(tracker, 100, 100, snapshot=onset)
        result = bar(tracker, 200, 98, high=101, low=97)[0]
        self.assertAlmostEqual(result.directional_return_pct, (100 / 98 - 1) * 100)
        self.assertAlmostEqual(result.max_favourable_excursion_pct, (100 / 97 - 1) * 100)
        self.assertAlmostEqual(result.max_adverse_excursion_pct, (100 / 101 - 1) * 100)

    def test_event_bar_wicks_are_not_counted_as_post_event_excursion(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0)
        bar(tracker, 100, 100, high=120, low=80, snapshot=onset)
        result = bar(tracker, 200, 100, high=101, low=99)[0]
        self.assertAlmostEqual(result.max_favourable_excursion_pct, 1.0)
        self.assertAlmostEqual(result.max_adverse_excursion_pct, -1.0)

    def test_bad_or_duplicate_bars_do_not_advance_horizon(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0)
        bar(tracker, 100, 100, snapshot=onset)
        invalid = Snapshot(valid=False)
        self.assertEqual(bar(tracker, 150, 110, snapshot=invalid), [])
        self.assertEqual(bar(tracker, 100, 110), [])
        self.assertEqual(tracker.active_event_count, 1)
        result = bar(tracker, 200, 101)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].observation_timestamp, 200)

    def test_out_of_order_and_non_sane_ohlc_are_rejected(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0)
        bar(tracker, 100, 100, snapshot=onset)
        self.assertEqual(bar(tracker, 200, 100, high=99, low=98), [])
        self.assertEqual(bar(tracker, 150, 100), [])
        self.assertEqual(tracker.active_event_count, 1)

    def test_overlapping_events_keep_independent_lifecycles(self):
        tracker = ShockOutcomeTracker((1, 2))
        long_onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                              direction=1, persistence_bars=0)
        short_onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                               direction=-1, persistence_bars=0)
        bar(tracker, 100, 100, snapshot=long_onset)
        first = bar(tracker, 200, 101, snapshot=short_onset)
        self.assertEqual(len(first), 1)
        self.assertEqual(first[0].direction, 1)
        self.assertEqual(tracker.active_event_count, 2)
        second = bar(tracker, 300, 100)
        self.assertEqual(len(second), 2)
        self.assertEqual(
            {(x.direction, x.horizon_bars) for x in second},
            {(1, 2), (-1, 1)},
        )
        self.assertEqual(tracker.active_event_count, 1)
        third = bar(tracker, 400, 99)
        self.assertEqual(len(third), 1)
        self.assertEqual(third[0].horizon_bars, 2)
        self.assertEqual(third[0].direction, -1)
        self.assertEqual(tracker.active_event_count, 0)

    def test_outcome_keeps_onset_context_not_later_bar_context(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0, regime="TREND_BULL",
                         regime_strength=88, confidence=82)
        bar(tracker, 100, 100, snapshot=onset)
        later = Snapshot(regime="RANGE", regime_strength=25, confidence=10)
        result = bar(tracker, 200, 101, snapshot=later)[0]
        self.assertEqual(result.regime, "TREND_BULL")
        self.assertEqual(result.regime_strength, 88)
        self.assertEqual(result.confidence, 82)

    def test_invalid_horizon_configuration_rejected(self):
        with self.assertRaises(ValueError):
            ShockOutcomeTracker((0, 1))
        with self.assertRaises(ValueError):
            ShockOutcomeTracker(())


if __name__ == "__main__":
    unittest.main()
