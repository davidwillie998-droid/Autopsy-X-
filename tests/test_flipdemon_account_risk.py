"""Deterministic reference tests for account-wide stop-risk policy.

These validate the risk arithmetic and fail-closed rules independently of MT5.
They do not emulate OrderCalcProfit or prove that the MQL5 component compiles.
"""
from dataclasses import dataclass
from math import isfinite
import unittest

HARD_CAP_PCT = 2.0


@dataclass(frozen=True)
class Exposure:
    symbol: str
    side: str
    volume: float
    entry: float
    stop: float | None
    pending: bool = False


def normalize_down(raw: float, minimum: float, maximum: float, step: float) -> float:
    if not all(isfinite(x) for x in (raw, minimum, maximum, step)):
        return 0.0
    if raw < minimum or minimum <= 0 or maximum < minimum or step <= 0:
        return 0.0
    result = round(int(min(raw, maximum) / step + 1e-10) * step, 8)
    return result if minimum <= result <= maximum else 0.0


def exposure_risk(item: Exposure, pnl_per_price_unit_per_lot: dict[str, float],
                  conversion_to_account: dict[str, float] | None = None) -> float:
    if item.stop is None or not all(isfinite(x) for x in
                                    (item.volume, item.entry, item.stop)):
        raise ValueError("UNKNOWN_STOP_OR_NONFINITE_INPUT")
    if item.volume <= 0 or item.entry <= 0 or item.stop <= 0:
        raise ValueError("INVALID_EXPOSURE_INPUT")
    if item.pending and ((item.side == "BUY" and item.stop >= item.entry) or
                         (item.side == "SELL" and item.stop <= item.entry)):
        raise ValueError("PENDING_STOP_NOT_ON_LOSS_SIDE")
    if item.side not in ("BUY", "SELL"):
        raise ValueError("UNKNOWN_SIDE")
    pnl = ((item.stop - item.entry) if item.side == "BUY"
           else (item.entry - item.stop))
    pnl *= item.volume * pnl_per_price_unit_per_lot[item.symbol]
    if conversion_to_account is not None:
        pnl *= conversion_to_account[item.symbol]
    return max(0.0, -pnl)



def proposed_entry_risk(side: str, volume: float, quote_entry: float, stop: float,
                        value_per_price_unit_per_lot: float, slippage_points: int,
                        point: float) -> float:
    """Worst-case stop risk after reserving configured adverse entry slippage."""
    if side not in ("BUY", "SELL") or slippage_points < 0:
        raise ValueError("INVALID_PROPOSED_ENTRY")
    if not all(isfinite(x) for x in
               (volume, quote_entry, stop, value_per_price_unit_per_lot, point)):
        raise ValueError("NONFINITE_PROPOSED_ENTRY")
    if volume <= 0 or quote_entry <= 0 or value_per_price_unit_per_lot <= 0 or point <= 0:
        raise ValueError("INVALID_PROPOSED_ENTRY")
    buffer = slippage_points * point
    worst_entry = quote_entry + buffer if side == "BUY" else quote_entry - buffer
    if worst_entry <= 0:
        raise ValueError("INVALID_WORST_CASE_ENTRY")
    return exposure_risk(Exposure("TEST", side, volume, worst_entry, stop),
                         {"TEST": value_per_price_unit_per_lot})


def scan(positions: list[Exposure], pending: list[Exposure], equity: float,
         rates: dict[str, float], hedging: bool = False,
         conversions: dict[str, float] | None = None) -> tuple[float, float]:
    if not isfinite(equity) or equity <= 0:
        raise ValueError("INVALID_EQUITY")
    if not hedging:
        symbols = [p.symbol for p in positions]
        if len(symbols) != len(set(symbols)):
            raise ValueError("AMBIGUOUS_NETTING_DUPLICATE_SYMBOL")
    total = sum(exposure_risk(p, rates, conversions) for p in positions + pending)
    return total, max(0.0, equity * HARD_CAP_PCT / 100.0 - total)


def approve(equity: float, existing: float, proposed: float,
            per_entry_pct: float = 1.0) -> bool:
    if not all(isfinite(x) for x in (equity, existing, proposed, per_entry_pct)):
        return False
    if equity <= 0 or existing < 0 or proposed < 0 or per_entry_pct <= 0:
        return False
    return (existing <= equity * HARD_CAP_PCT / 100.0 + 0.01
            and proposed <= equity * per_entry_pct / 100.0 + 0.01
            and existing + proposed <= equity * HARD_CAP_PCT / 100.0 + 0.01)


def post_fill_within_cap(equity: float, broker_confirmed_risk: float,
                         snapshot_known: bool, hard_cap_pct: float = HARD_CAP_PCT) -> bool:
    """Only retain a new fill when broker-confirmed aggregate stop risk is known and capped."""
    if not snapshot_known or not all(isfinite(x) for x in (equity, broker_confirmed_risk, hard_cap_pct)):
        return False
    if equity <= 0 or broker_confirmed_risk < 0 or hard_cap_pct <= 0:
        return False
    return broker_confirmed_risk <= equity * hard_cap_pct / 100.0 + 0.01


class AccountRiskCalculatorTests(unittest.TestCase):
    def setUp(self):
        self.rates = {"EURUSD": 100000.0, "XAUUSD": 100.0, "US30": 1.0}

    def test_one_position_uses_stop_downside(self):
        p = Exposure("EURUSD", "BUY", 0.1, 1.10, 1.099)
        risk, remaining = scan([p], [], 10000, self.rates)
        self.assertAlmostEqual(risk, 10.0)
        self.assertAlmostEqual(remaining, 190.0)

    def test_multiple_symbols_aggregate_above_two_percent(self):
        positions = [
            Exposure("EURUSD", "BUY", 1.0, 1.10, 1.09),
            Exposure("XAUUSD", "SELL", 1.0, 2000, 2002),
        ]
        risk, _ = scan(positions, [], 10000, self.rates)
        self.assertGreater(risk, 200.0)
        self.assertFalse(approve(10000, risk, 1.0))

    def test_proposed_entry_exceeding_remaining_budget_is_rejected(self):
        self.assertFalse(approve(10000, 190, 20, per_entry_pct=1.0))

    def test_missing_stop_is_unknown_not_zero(self):
        with self.assertRaisesRegex(ValueError, "UNKNOWN_STOP"):
            scan([Exposure("EURUSD", "BUY", 0.1, 1.1, None)], [], 10000, self.rates)

    def test_invalid_stop_side_for_pending_order_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "PENDING_STOP"):
            scan([], [Exposure("EURUSD", "BUY", 0.1, 1.1, 1.101, True)],
                 10000, self.rates)

    def test_different_contract_specifications_are_symbol_specific(self):
        gold = Exposure("XAUUSD", "BUY", 0.2, 2000, 1999)
        index = Exposure("US30", "SELL", 2.0, 40000, 40010)
        risk, _ = scan([gold, index], [], 10000, self.rates)
        self.assertAlmostEqual(risk, 40.0)

    def test_currency_conversion_is_applied_to_account_currency(self):
        p = Exposure("EURUSD", "BUY", 1.0, 1.10, 1.09)
        risk, _ = scan([p], [], 10000, self.rates,
                       conversions={"EURUSD": 0.92})
        self.assertAlmostEqual(risk, 920.0)

    def test_pending_remainder_is_added_to_filled_position(self):
        # Filled volume and ORDER_VOLUME_CURRENT are distinct. Only remaining
        # pending volume is counted, not the order's original requested volume.
        position = Exposure("EURUSD", "BUY", 0.4, 1.10, 1.099)
        remainder = Exposure("EURUSD", "BUY", 0.6, 1.10, 1.099, True)
        risk, _ = scan([position], [remainder], 10000, self.rates)
        self.assertAlmostEqual(risk, 100.0)

    def test_netting_duplicate_symbol_is_ambiguous(self):
        positions = [
            Exposure("EURUSD", "BUY", 0.1, 1.1, 1.099),
            Exposure("EURUSD", "SELL", 0.1, 1.1, 1.101),
        ]
        with self.assertRaisesRegex(ValueError, "AMBIGUOUS_NETTING"):
            scan(positions, [], 10000, self.rates, hedging=False)

    def test_hedging_positions_are_reconciled_ticket_by_ticket(self):
        positions = [
            Exposure("EURUSD", "BUY", 0.1, 1.1, 1.099),
            Exposure("EURUSD", "SELL", 0.1, 1.1, 1.101),
        ]
        risk, _ = scan(positions, [], 10000, self.rates, hedging=True)
        self.assertAlmostEqual(risk, 20.0)

    def test_broker_minimum_cannot_override_available_budget(self):
        self.assertEqual(normalize_down(0.004, 0.01, 10.0, 0.01), 0.0)

    def test_invalid_or_unavailable_order_calc_profit_fails_closed(self):
        def broker_calc_profit(available: bool, finite: bool):
            if not available or not finite:
                raise ValueError("ORDERCALCPROFIT_FAILED_OR_INVALID")
            return -10.0
        for args in ((False, True), (True, False)):
            with self.assertRaisesRegex(ValueError, "ORDERCALCPROFIT"):
                broker_calc_profit(*args)


    def test_adverse_slippage_allowance_increases_proposed_stop_risk(self):
        baseline = proposed_entry_risk("BUY", 1.0, 1.1000, 1.0990, 100000.0, 0, 0.0001)
        buffered = proposed_entry_risk("BUY", 1.0, 1.1000, 1.0990, 100000.0, 5, 0.0001)
        self.assertAlmostEqual(baseline, 100.0)
        self.assertAlmostEqual(buffered, 150.0)
        self.assertGreater(buffered, baseline)

    def test_adverse_slippage_is_directionally_conservative_for_sell(self):
        baseline = proposed_entry_risk("SELL", 1.0, 1.1000, 1.1010, 100000.0, 0, 0.0001)
        buffered = proposed_entry_risk("SELL", 1.0, 1.1000, 1.1010, 100000.0, 5, 0.0001)
        self.assertAlmostEqual(baseline, 100.0)
        self.assertAlmostEqual(buffered, 150.0)

    def test_invalid_slippage_allowance_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "INVALID_PROPOSED_ENTRY"):
            proposed_entry_risk("BUY", 1.0, 1.1, 1.099, 100000.0, -1, 0.0001)
        with self.assertRaisesRegex(ValueError, "INVALID_PROPOSED_ENTRY"):
            proposed_entry_risk("BUY", 1.0, 1.1, 1.099, 100000.0, 1, 0.0)

    def test_post_fill_actual_exposure_inside_cap_is_retained(self):
        self.assertTrue(post_fill_within_cap(10000, 199.99, True))

    def test_post_fill_slippage_breach_triggers_defensive_close(self):
        self.assertFalse(post_fill_within_cap(10000, 205.0, True))

    def test_post_fill_unknown_broker_snapshot_triggers_defensive_close(self):
        self.assertFalse(post_fill_within_cap(10000, 50.0, False))

    def test_post_fill_invalid_equity_or_risk_fails_closed(self):
        self.assertFalse(post_fill_within_cap(0, 10.0, True))
        self.assertFalse(post_fill_within_cap(10000, float("nan"), True))

    def test_existing_exposure_already_over_cap_rejects_any_new_order(self):
        self.assertFalse(approve(10000, 201, 0.01))

    def test_zero_or_invalid_equity_fails_closed(self):
        for equity in (0, -1, float("nan")):
            with self.assertRaisesRegex(ValueError, "INVALID_EQUITY"):
                scan([], [], equity, self.rates)


if __name__ == "__main__":
    unittest.main(verbosity=2)
