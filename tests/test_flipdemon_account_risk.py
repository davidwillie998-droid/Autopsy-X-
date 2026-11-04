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


def broker_position_risk(item: Exposure, bid: float, ask: float,
                         rates: dict[str, float]) -> float:
    """Mirror live position checks: actual SL must exist and remain beyond market."""
    if item.pending:
        raise ValueError("NOT_A_LIVE_POSITION")
    if not all(isfinite(x) for x in (bid, ask)) or bid <= 0 or ask < bid:
        raise ValueError("POSITION_QUOTE_UNAVAILABLE")
    if item.stop is None:
        raise ValueError("UNPROTECTED_POSITION")
    if ((item.side == "BUY" and item.stop >= bid) or
            (item.side == "SELL" and item.stop <= ask)):
        raise ValueError("POSITION_STOP_CROSSED_OR_INVALID")
    return exposure_risk(item, rates)




class TerminalRiskMutex:
    """Reference model for one MT5 terminal's atomic account mutex."""
    def __init__(self):
        self.owner = None

    def acquire(self, owner):
        if owner is None or self.owner is not None:
            return False
        self.owner = owner
        return True

    def release(self, owner):
        if self.owner != owner:
            return False
        self.owner = None
        return True


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


def reconcile_transaction_snapshot(dirty: bool, snapshot_known: bool,
                                   actual_risk: float, hard_budget: float) -> tuple[bool, bool]:
    """Return (retry_next_tick, lock_new_entries) from the broker-confirmed snapshot."""
    if not dirty:
        return False, False
    if not snapshot_known or not all(isfinite(x) for x in (actual_risk, hard_budget)):
        return True, True
    if actual_risk < 0 or hard_budget < 0:
        return True, True
    return False, actual_risk > hard_budget + 0.01


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

    def test_live_position_without_broker_stop_is_unprotected(self):
        with self.assertRaisesRegex(ValueError, "UNPROTECTED_POSITION"):
            broker_position_risk(Exposure("EURUSD", "BUY", 0.1, 1.10, None),
                                 1.1000, 1.1002, self.rates)

    def test_stop_widening_increases_actual_broker_risk(self):
        tight = Exposure("EURUSD", "BUY", 0.1, 1.10, 1.0995)
        widened = Exposure("EURUSD", "BUY", 0.1, 1.10, 1.0980)
        tight_risk = broker_position_risk(tight, 1.1000, 1.1002, self.rates)
        widened_risk = broker_position_risk(widened, 1.1000, 1.1002, self.rates)
        self.assertAlmostEqual(tight_risk, 5.0)
        self.assertAlmostEqual(widened_risk, 20.0)
        self.assertGreater(widened_risk, tight_risk)

    def test_stop_tightening_reduces_actual_broker_risk(self):
        original = Exposure("EURUSD", "BUY", 0.1, 1.10, 1.0980)
        tightened = Exposure("EURUSD", "BUY", 0.1, 1.10, 1.0995)
        self.assertLess(broker_position_risk(tightened, 1.1000, 1.1002, self.rates),
                        broker_position_risk(original, 1.1000, 1.1002, self.rates))

    def test_stop_crossed_by_market_is_not_accepted_as_protection(self):
        crossed_buy = Exposure("EURUSD", "BUY", 0.1, 1.10, 1.1001)
        crossed_sell = Exposure("EURUSD", "SELL", 0.1, 1.10, 1.0999)
        with self.assertRaisesRegex(ValueError, "POSITION_STOP_CROSSED_OR_INVALID"):
            broker_position_risk(crossed_buy, 1.1000, 1.1002, self.rates)
        with self.assertRaisesRegex(ValueError, "POSITION_STOP_CROSSED_OR_INVALID"):
            broker_position_risk(crossed_sell, 1.0998, 1.1000, self.rates)

    def test_partial_close_recalculates_risk_from_remaining_volume(self):
        before = Exposure("EURUSD", "BUY", 0.4, 1.10, 1.099)
        after = Exposure("EURUSD", "BUY", 0.15, 1.10, 1.099)
        before_risk = broker_position_risk(before, 1.1000, 1.1002, self.rates)
        after_risk = broker_position_risk(after, 1.1000, 1.1002, self.rates)
        self.assertAlmostEqual(before_risk, 40.0)
        self.assertAlmostEqual(after_risk, 15.0)

    def test_netting_reversal_uses_actual_reversed_position_side_and_entry(self):
        # A reversal is one broker net position. Risk must follow its new SELL side,
        # actual open price and current stop, never the old BUY campaign metadata.
        reversed_position = Exposure("EURUSD", "SELL", 0.2, 1.1010, 1.1020)
        self.assertAlmostEqual(broker_position_risk(reversed_position, 1.1000, 1.1002,
                                                    self.rates), 20.0)

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

    def test_transaction_reconciliation_retries_unknown_broker_snapshot(self):
        self.assertEqual(reconcile_transaction_snapshot(True, False, 0.0, 200.0), (True, True))

    def test_transaction_reconciliation_locks_on_actual_account_risk_breach(self):
        self.assertEqual(reconcile_transaction_snapshot(True, True, 225.0, 200.0), (False, True))

    def test_transaction_reconciliation_clears_dirty_state_after_clean_snapshot(self):
        self.assertEqual(reconcile_transaction_snapshot(True, True, 175.0, 200.0), (False, False))

    def test_no_transaction_does_not_trigger_unnecessary_rescan(self):
        self.assertEqual(reconcile_transaction_snapshot(False, True, 500.0, 200.0), (False, False))

    def test_account_mutex_allows_only_one_same_terminal_approval(self):
        mutex = TerminalRiskMutex()
        self.assertTrue(mutex.acquire("chart-A"))
        self.assertFalse(mutex.acquire("chart-B"))
        self.assertTrue(mutex.release("chart-A"))
        self.assertTrue(mutex.acquire("chart-B"))

    def test_account_mutex_rejects_release_by_non_owner(self):
        mutex = TerminalRiskMutex()
        self.assertTrue(mutex.acquire("chart-A"))
        self.assertFalse(mutex.release("chart-B"))
        self.assertFalse(mutex.acquire("chart-C"))

    def test_terminal_local_mutex_does_not_claim_cross_terminal_coordination(self):
        terminal_a = TerminalRiskMutex()
        terminal_b = TerminalRiskMutex()
        self.assertTrue(terminal_a.acquire("chart-A"))
        # Separate MT5 terminals have separate terminal-global-variable stores.
        self.assertTrue(terminal_b.acquire("chart-B"))

    def test_existing_exposure_already_over_cap_rejects_any_new_order(self):
        self.assertFalse(approve(10000, 201, 0.01))

    def test_zero_or_invalid_equity_fails_closed(self):
        for equity in (0, -1, float("nan")):
            with self.assertRaisesRegex(ValueError, "INVALID_EQUITY"):
                scan([], [], equity, self.rates)




class Mql5SourceContractTests(unittest.TestCase):
    """Static wiring checks for the production MQL5 implementation.

    These checks catch source-level regressions, but they do not replace MetaEditor
    compilation, MT5 Strategy Tester runs, or broker-side execution tests.
    """

    @classmethod
    def setUpClass(cls):
        from pathlib import Path
        root = Path(__file__).resolve().parents[1]
        cls.ea = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
        cls.risk = (root / "MQL5/Include/AutopsyX/AccountRiskCalculator.mqh").read_text()

    def test_production_ea_includes_account_risk_calculator(self):
        self.assertIn("#include <AutopsyX/AccountRiskCalculator.mqh>", self.ea)
        self.assertIn("CAccountRiskCalculator g_accountRisk", self.ea)

    def test_production_calculator_uses_account_currency_order_calc_profit(self):
        self.assertIn("OrderCalcProfit(orderType,symbol,volume,entryPrice,stopPrice,result)", self.risk)
        self.assertIn("#define AX_ACCOUNT_RISK_HARD_CAP_PCT 2.0", self.risk)

    def test_pending_orders_use_remaining_unfilled_volume(self):
        self.assertIn("OrderGetDouble(ORDER_VOLUME_CURRENT)", self.risk)
        self.assertIn("PendingOrderRisk(ticket,risk,error)", self.risk)

    def test_live_ea_keeps_hedging_disabled_until_multi_ticket_management_exists(self):
        # Risk arithmetic can enumerate hedging tickets, but this EA's position
        # lifecycle remains single-position oriented. Do not remove this guard
        # until entry, exit, partial-close and restart recovery are multi-ticket safe.
        self.assertIn("marginMode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING", self.ea)
        self.assertIn("return(INIT_FAILED);", self.ea[
            self.ea.index("marginMode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING"):
            self.ea.index("marginMode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING") + 800
        ])

    def test_execution_defaults_to_analysis_only(self):
        self.assertIn("InpExecutionMode = AX_EXEC_ANALYSIS_ONLY", self.ea)

    def test_account_mutex_covers_final_risk_check_and_order_submission(self):
        acquire = self.ea.index("g_accountRiskCoordinator.TryAcquire()")
        evaluate = self.ea.index("g_accountRisk.Evaluate(", acquire)
        submit = self.ea.index("g_exec.OpenMarket(", evaluate)
        self.assertLess(acquire, evaluate)
        self.assertLess(evaluate, submit)
        self.assertIn("g_accountRisk.Scan(postFillRisk)", self.ea[submit:])

    def test_broker_transactions_mark_account_snapshot_dirty(self):
        on_tick = self.ea.index("void OnTick(void)")
        callback = self.ea.rindex("void OnTradeTransaction(")
        dirty = self.ea.index("g_accountRiskReconciliationPending=true;", callback)
        self.assertLess(on_tick, callback)
        self.assertLess(callback, dirty)
        self.assertIn("if(g_accountRiskReconciliationPending)", self.ea[on_tick:callback])


class FullMarginModeSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from pathlib import Path
        root = Path(__file__).resolve().parents[1]
        cls.ea = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
        cls.risk = (root / "MQL5/Include/AutopsyX/RiskEngine.mqh").read_text()
        cls.account_risk = (root / "MQL5/Include/AutopsyX/AccountRiskCalculator.mqh").read_text()
        cls.execution = (root / "MQL5/Include/AutopsyX/ExecutionEngine.mqh").read_text()

    def test_mode_is_disabled_by_default_and_risk_remains_capped(self):
        self.assertIn("InpEnableFullMarginMode    = false", self.ea)
        self.assertIn("AxClampD(riskPercent,0.05,2.0)", self.risk)
        self.assertIn("#define AX_ACCOUNT_RISK_HARD_CAP_PCT 2.0", self.account_risk)

    def test_full_margin_requires_directional_momentum(self):
        self.assertIn("AxStrongMomentumForDirection(dir)", self.ea)
        self.assertIn("g_mom.PersistentBull()", self.ea)
        self.assertIn("g_mom.PersistentBear()", self.ea)
        self.assertIn("g_mom.IsExhausted()", self.ea)

    def test_full_margin_checks_broker_stopout_buffer(self):
        self.assertIn("ACCOUNT_MARGIN_SO_MODE", self.ea)
        self.assertIn("ACCOUNT_STOPOUT_MODE_PERCENT", self.ea)
        self.assertIn("ACCOUNT_MARGIN_SO_CALL", self.ea)
        self.assertIn("ACCOUNT_MARGIN_SO_SO", self.ea)
        self.assertIn("AxFullMarginStopoutSafe(requiredMargin,stopoutReason)", self.ea)
        self.assertIn("projectedMarginLevel<=requiredMarginLevel", self.ea)

    def test_standard_margin_limits_remain_default(self):
        self.assertIn("InpMinFreeMarginPercent    = 150.0", self.ea)
        self.assertIn("InpMaxMarginUsagePercent   = 50.0", self.ea)

    def test_full_margin_requires_confidence_strictly_above_75_and_direction_match(self):
        start = self.ea.index("bool AxFullMarginQualityQualified(")
        end = self.ea.index("// Fail closed unless the broker reports percentage-based stop-out levels", start)
        gate = self.ea[start:end]
        self.assertIn("score.confidence<=75.0", gate)
        self.assertIn("score.action!=dir", gate)
        self.assertIn("AxStrongMomentumForDirection(dir)", gate)

    def test_full_margin_requires_vwap_and_clear_htf_alignment(self):
        start = self.ea.index("bool AxFullMarginQualityQualified(")
        end = self.ea.index("// Fail closed unless the broker reports percentage-based stop-out levels", start)
        gate = self.ea[start:end]
        self.assertIn('g_vwapTrend!="BULLISH"', gate)
        self.assertIn('g_vwapTrend!="BEARISH"', gate)
        self.assertIn("g_regimeHtf.R2()<InpHtfMinR2ToBlock", gate)
        self.assertIn("g_regimeHtf.Slope()", gate)
        self.assertIn("if(InpUseOrderFlow)", gate)
        self.assertIn("buyEvidence<=sellEvidence", gate)
        self.assertIn("sellEvidence<=buyEvidence", gate)

    def test_non_qualifying_setup_keeps_standard_margin_policy(self):
        self.assertIn("bool fullMarginCandidate=AxFullMarginQualityQualified(dir,score)", self.ea)
        self.assertIn("quality threshold or confluence not met; standard margin limits will apply", self.ea)
        self.assertIn("fullMarginActive?100.0:-1.0", self.ea)
        self.assertIn("fullMarginActive?0.0:-1.0", self.ea)

    def test_full_margin_risk_gate_runs_after_standard_entry_confluence(self):
        attempt = self.ea[self.ea.index("bool AxAttemptEntry("):]
        self.assertLess(attempt.index("SessionAllowed("), attempt.index("PreTradeAllowed("))
        self.assertLess(attempt.index("g_chop.IsInCooldown()"), attempt.index("PreTradeAllowed("))
        self.assertLess(attempt.index("AxHtfConfluenceOk(dir)"), attempt.index("PreTradeAllowed("))


    def test_runtime_guard_is_opt_in_and_only_runs_for_an_open_ea_position(self):
        start = self.ea.index("bool AxFullMarginRuntimeProtection(void)")
        end = self.ea.index("void AxRecordExternalClose(void)", start)
        guard = self.ea[start:end]
        self.assertIn("if(!InpEnableFullMarginMode || !g_haveOpenPosition) return(false)", guard)
        self.assertIn("(ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber", guard)

    def test_runtime_guard_fails_closed_on_non_percent_stopout_mode_and_invalid_data(self):
        start = self.ea.index("bool AxFullMarginRuntimeProtection(void)")
        end = self.ea.index("void AxRecordExternalClose(void)", start)
        guard = self.ea[start:end]
        self.assertIn("ACCOUNT_MARGIN_SO_MODE", guard)
        self.assertIn("ACCOUNT_STOPOUT_MODE_PERCENT", guard)
        self.assertIn("ACCOUNT_MARGIN_LEVEL", guard)
        self.assertIn("FULL_MARGIN_RUNTIME_MARGIN_DATA_INVALID", guard)
        self.assertIn("MathIsValidNumber(marginLevel)", guard)

    def test_runtime_guard_uses_broker_floor_plus_configured_buffer(self):
        start = self.ea.index("bool AxFullMarginRuntimeProtection(void)")
        end = self.ea.index("void AxRecordExternalClose(void)", start)
        guard = self.ea[start:end]
        self.assertIn("MathMax(callLevel,stopoutLevel)+InpFullMarginStopoutBufferPercent", guard)
        self.assertIn("marginLevel<=safetyFloor", guard)

    def test_runtime_breach_latches_entries_and_uses_recorded_risk_exit(self):
        start = self.ea.index("bool AxFullMarginRuntimeProtection(void)")
        end = self.ea.index("void AxRecordExternalClose(void)", start)
        guard = self.ea[start:end]
        self.assertIn("g_emergency.TriggerEmergencyStop(failureReason)", guard)
        self.assertIn("AxCloseAndRecord(AX_EXIT_RISK_SHUTDOWN)", guard)
        self.assertIn("if(!AxCloseAndRecord(AX_EXIT_RISK_SHUTDOWN))", guard)

    def test_runtime_guard_runs_before_signal_processing_and_retries_normal_management_on_close_failure(self):
        on_tick = self.ea[self.ea.index("void OnTick(void)"):]
        self.assertLess(on_tick.index("AxFullMarginRuntimeProtection()"),
                        on_tick.index("g_mom.Update(g_md)"))
        self.assertIn("if(AxFullMarginRuntimeProtection()) return;", on_tick)
        self.assertIn("normal position management remains active for retry", self.ea)

    def test_execution_close_rechecks_magic_before_initial_and_retry_close(self):
        close_start = self.execution.index("bool              ClosePosition(")
        close_end = self.execution.index("//--- close part of an open position", close_start)
        close_method = self.execution[close_start:close_end]
        self.assertGreaterEqual(close_method.count("POSITION_MAGIC"), 2)
        self.assertIn("!=m_magic", close_method)
        self.assertIn("Position ownership changed before close", close_method)

if __name__ == "__main__":
    unittest.main(verbosity=2)
