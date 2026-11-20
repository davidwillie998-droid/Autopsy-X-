"""Regression tests for normalized, persistent shock outcome research."""
from dataclasses import dataclass
from enum import Enum
import tempfile
import unittest
from pathlib import Path
import re

from python.autopsy_research.shock_outcomes import (
    ShockEventLedger, ShockOutcomeTracker, ShockSnapshotAdapter,
)


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
    timestamp: int | None = None


def bar(tracker, timestamp, close, high=None, low=None, snapshot=None, symbol="XAUUSD"):
    high = high if high is not None else close
    low = low if low is not None else close
    return tracker.update(
        symbol=symbol, timeframe="M15", timestamp=timestamp,
        open_price=close, high=high, low=low, close=close,
        snapshot=snapshot or Snapshot(timestamp=timestamp),
    )


class ShockOutcomeTrackerTests(unittest.TestCase):
    def test_short_return_uses_conventional_simple_notional_pnl(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=-1, persistence_bars=0, timestamp=100)
        bar(tracker, 100, 100, snapshot=onset)
        result = bar(tracker, 200, 90, high=105, low=88)[0]
        self.assertAlmostEqual(result.underlying_return_pct, -10.0)
        self.assertAlmostEqual(result.directional_return_pct, 10.0)
        self.assertAlmostEqual(result.max_favourable_excursion_pct, 12.0)
        self.assertAlmostEqual(result.max_adverse_excursion_pct, 5.0)

    def test_long_return_and_excursions(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0, timestamp=100)
        bar(tracker, 100, 100, snapshot=onset)
        result = bar(tracker, 200, 101, high=103, low=98)[0]
        self.assertAlmostEqual(result.underlying_return_pct, 1.0)
        self.assertAlmostEqual(result.directional_return_pct, 1.0)
        self.assertAlmostEqual(result.max_favourable_excursion_pct, 3.0)
        self.assertAlmostEqual(result.max_adverse_excursion_pct, 2.0)

    def test_onset_and_observation_magnitudes_are_distinct(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0, normalized_magnitude=2.4,
                         event_magnitude_atr=2.4, timestamp=100)
        bar(tracker, 100, 100, snapshot=onset)
        later = Snapshot(event_magnitude_atr=0.7, timestamp=200)
        result = bar(tracker, 200, 101, snapshot=later)[0]
        self.assertEqual(result.onset_magnitude_atr, 2.4)
        self.assertEqual(result.event_magnitude_at_observation_atr, 0.7)

    def test_event_bar_wicks_are_not_counted(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0, timestamp=100)
        bar(tracker, 100, 100, high=120, low=80, snapshot=onset)
        result = bar(tracker, 200, 100, high=101, low=99)[0]
        self.assertAlmostEqual(result.max_favourable_excursion_pct, 1.0)
        self.assertAlmostEqual(result.max_adverse_excursion_pct, 1.0)

    def test_invalid_bars_do_not_advance_event_horizons_or_accept_late_stale_bars(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0, timestamp=100)
        bar(tracker, 100, 100, snapshot=onset)
        self.assertEqual(bar(tracker, 150, 110, snapshot=Snapshot(valid=False)), [])
        self.assertEqual(bar(tracker, 140, 110), [])
        result = bar(tracker, 200, 101)[0]
        self.assertEqual(result.observation_timestamp, 200)

    def test_streams_are_independent(self):
        tracker = ShockOutcomeTracker((1,))
        onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                         direction=1, persistence_bars=0, timestamp=100)
        bar(tracker, 100, 100, snapshot=onset, symbol="XAUUSD")
        other = tracker.update(symbol="GBPJPY", timeframe="M15", timestamp=50,
            open_price=100, high=100, low=100, close=100, snapshot=Snapshot(timestamp=50))
        self.assertEqual(other, [])
        result = bar(tracker, 200, 101)[0]
        self.assertEqual(result.symbol, "XAUUSD")

    def test_overlapping_events_keep_independent_lifecycles(self):
        tracker = ShockOutcomeTracker((1, 2))
        long_onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                              direction=1, persistence_bars=0, timestamp=100)
        short_onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                               direction=-1, persistence_bars=0, timestamp=200)
        bar(tracker, 100, 100, snapshot=long_onset)
        first = bar(tracker, 200, 101, snapshot=short_onset)
        self.assertEqual(len(first), 1)
        self.assertEqual(first[0].direction, 1)
        second = bar(tracker, 300, 100)
        self.assertEqual({(x.direction, x.horizon_bars) for x in second}, {(1, 2), (-1, 1)})
        third = bar(tracker, 400, 99)
        self.assertEqual((third[0].direction, third[0].horizon_bars), (-1, 2))


    def test_adapter_enum_maps_match_authoritative_mql5_enum_order(self):
        root = Path(__file__).resolve().parents[1]
        shock = (root / "MQL5/Include/AutopsyX/ShockDNAEngine.mqh").read_text()
        regime = (root / "MQL5/Include/AutopsyX/RegimeClassifierEngine.mqh").read_text()
        transmission = (root / "MQL5/Include/AutopsyX/InformationTransmissionEngine.mqh").read_text()

        def enum_members(source, enum_name, prefix):
            match = re.search(r"enum\s+" + enum_name + r"\s*\{([^}]*)\}", source, re.S)
            self.assertIsNotNone(match, enum_name)
            return re.findall(prefix + r"[A-Z_]+", match.group(1))

        self.assertEqual(enum_members(shock, "ENUM_AX_SHOCK_STATE", "AX_SHOCK_"), [
            "AX_SHOCK_UNKNOWN", "AX_SHOCK_INSUFFICIENT_DATA", "AX_SHOCK_NONE",
            "AX_SHOCK_ONSET", "AX_SHOCK_IMPULSE", "AX_SHOCK_FOLLOW_THROUGH",
            "AX_SHOCK_ABSORPTION", "AX_SHOCK_REVERSAL", "AX_SHOCK_NORMALIZING",
        ])
        self.assertEqual(enum_members(regime, "ENUM_AX_REGIME_CLASS", "AX_RC_"), [
            "AX_RC_UNAVAILABLE", "AX_RC_PERSISTENT_BULLISH_TREND",
            "AX_RC_BULLISH_UNSTABLE", "AX_RC_RANGE_CHOP",
            "AX_RC_BEARISH_TRANSITION", "AX_RC_PERSISTENT_BEARISH_TREND",
            "AX_RC_VOLATILITY_SHOCK", "AX_RC_INFORMATION_CONFLICT",
            "AX_RC_STRUCTURAL_BREAK",
        ])
        self.assertEqual(enum_members(transmission, "ENUM_AX_TRANSMISSION_STATE", "AX_TS_"), [
            "AX_TS_UNKNOWN", "AX_TS_INSUFFICIENT_DATA", "AX_TS_INACTIVE",
            "AX_TS_LEADER", "AX_TS_CONFIRMING", "AX_TS_WEAKENING",
            "AX_TS_DIVERGING", "AX_TS_INVERTED",
        ])

    def test_mql5_snapshot_struct_contains_all_consumed_adapter_fields(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "MQL5/Include/AutopsyX/ShockDNAEngine.mqh").read_text()
        match = re.search(r"struct\s+SAxShockDNASnapshot\s*\{([^}]*)\}", source, re.S)
        self.assertIsNotNone(match)
        struct_body = match.group(1)
        for field in (
            "timestamp", "valid", "dataQualityOk", "dataQualityReason",
            "shockDetected", "shockState", "direction", "normalizedMagnitude",
            "eventMagnitudeAtr", "persistenceBars", "regime", "regimeStrength",
            "transmissionState", "transmissionAvailable",
            "crossAssetConfirmationAvailable", "crossAssetConfirmation", "confidence",
        ):
            self.assertRegex(struct_body, r"\b" + field + r"\b")

    def test_mql5_adapter_maps_enum_and_optional_confirmation(self):
        mapped = ShockSnapshotAdapter.from_mql5({
            "timestamp": 100, "valid": True, "dataQualityOk": True,
            "shockDetected": True, "shockState": 3, "direction": -1,
            "persistenceBars": 0, "normalizedMagnitude": 1.8,
            "eventMagnitudeAtr": 2.1, "confidence": 75,
            "regime": 5, "regimeStrength": 60, "transmissionState": 6,
            "transmissionAvailable": False, "crossAssetConfirmationAvailable": False,
            "crossAssetConfirmation": False,
        })
        self.assertEqual(mapped["shock_state"], "ONSET")
        self.assertIsNone(mapped["cross_asset_confirmation"])
        self.assertEqual(mapped["event_magnitude_atr"], 2.1)
        self.assertEqual(mapped["regime"], "R5_PERSISTENT_BEARISH_TREND")
        self.assertEqual(mapped["information_transmission_state"], "DIVERGING")

    def test_ledger_restores_open_events_and_deduplicates_outcomes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "events.sqlite"
            ledger = ShockEventLedger(path)
            tracker = ShockOutcomeTracker((1, 2), ledger=ledger)
            onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                             direction=1, persistence_bars=0, timestamp=100)
            bar(tracker, 100, 100, snapshot=onset)
            ledger.close()

            ledger2 = ShockEventLedger(path)
            resumed = ShockOutcomeTracker((1, 2), ledger=ledger2)
            self.assertEqual(resumed.active_event_count, 1)
            result = bar(resumed, 200, 102)
            self.assertEqual(len(result), 1)
            ledger2.save_outcome(result[0])
            self.assertEqual(ledger2.export_csv(Path(tmp) / "outcomes.csv"), 1)
            ledger2.close()


    def test_mql5_snapshot_adapter_feeds_tracker_with_same_bar_timestamp(self):
        tracker = ShockOutcomeTracker((1,))
        onset = {
            "timestamp": 100, "valid": True, "dataQualityOk": True,
            "shockDetected": True, "shockState": 3, "direction": 1,
            "persistenceBars": 0, "normalizedMagnitude": 1.8,
            "eventMagnitudeAtr": 1.8, "confidence": 70,
            "regimeStrength": 80, "transmissionAvailable": True,
            "crossAssetConfirmationAvailable": True,
            "crossAssetConfirmation": True,
        }
        self.assertEqual(tracker.update_mql5(
            symbol="XAUUSD", timeframe="M15", timestamp=100,
            open_price=100, high=101, low=99, close=100,
            snapshot_payload=onset,
        ), [])
        later = dict(onset, timestamp=200, shockDetected=False, shockState=4,
                     persistenceBars=1, eventMagnitudeAtr=2.0)
        result = tracker.update_mql5(
            symbol="XAUUSD", timeframe="M15", timestamp=200,
            open_price=100, high=102, low=99, close=101,
            snapshot_payload=later,
        )
        self.assertEqual(len(result), 1)
        self.assertAlmostEqual(result[0].directional_return_pct, 1.0)

    def test_restart_restores_stream_watermark_and_rejects_duplicate_bar(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "watermark.sqlite"
            ledger = ShockEventLedger(path)
            tracker = ShockOutcomeTracker((1,), ledger=ledger)
            onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                             direction=1, persistence_bars=0, timestamp=100)
            bar(tracker, 100, 100, snapshot=onset)
            ledger.close()
            ledger2 = ShockEventLedger(path)
            resumed = ShockOutcomeTracker((1,), ledger=ledger2)
            self.assertEqual(bar(resumed, 100, 100, snapshot=onset), [])
            self.assertEqual(resumed.active_event_count, 1)
            matured = bar(resumed, 200, 101)
            self.assertEqual(len(matured), 1)
            self.assertEqual(matured[0].horizon_bars, 1)
            self.assertEqual(resumed.active_event_count, 0)
            ledger2.close()

    def test_duplicate_onset_cannot_reopen_matured_event_after_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "dedupe.sqlite"
            ledger = ShockEventLedger(path)
            tracker = ShockOutcomeTracker((1,), ledger=ledger)
            onset = Snapshot(shock_detected=True, shock_state=State.ONSET,
                             direction=1, persistence_bars=0, timestamp=100)
            bar(tracker, 100, 100, snapshot=onset)
            bar(tracker, 200, 101)
            ledger.close()
            ledger2 = ShockEventLedger(path)
            resumed = ShockOutcomeTracker((1,), ledger=ledger2)
            # The persisted watermark rejects replay of the old onset bar.
            self.assertEqual(bar(resumed, 100, 100, snapshot=onset), [])
            self.assertEqual(resumed.active_event_count, 0)
            ledger2.close()

    def test_mismatched_snapshot_timestamp_is_rejected(self):
        tracker = ShockOutcomeTracker((1,))
        mismatch = Snapshot(shock_detected=True, shock_state=State.ONSET,
                            direction=1, persistence_bars=0, timestamp=99)
        self.assertEqual(bar(tracker, 100, 100, snapshot=mismatch), [])
        self.assertEqual(tracker.active_event_count, 0)


if __name__ == "__main__":
    unittest.main()
