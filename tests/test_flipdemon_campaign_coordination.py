"""Reference and source-contract tests for account/campaign risk coordination.

These tests do not execute MQL5. They validate deterministic accounting cases and
assert that the EA's live entry path calls the fail-closed coordinator. MetaEditor
and MT5 Strategy Tester verification remain separate mandatory gates.
"""
from dataclasses import dataclass
from pathlib import Path
import math
import unittest

ROOT = Path(__file__).resolve().parents[1]
COORDINATOR = ROOT / "MQL5/Include/AutopsyX/AccountCampaignCoordinator.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


@dataclass(frozen=True)
class Position:
    symbol: str
    magic: int
    ticket: int
    position_id: int
    volume: float
    stop_risk_money: float
    protected: bool = True


def aggregate_account_risk(positions):
    total = 0.0
    for p in positions:
        if not p.protected or not math.isfinite(p.stop_risk_money) or p.stop_risk_money <= 0:
            return None
        total += p.stop_risk_money
    return total


def aggregate_campaign_risk(positions, symbol, magic):
    risk = aggregate_account_risk(positions)
    if risk is None:
        return None
    return sum(p.stop_risk_money for p in positions
               if p.symbol == symbol and p.magic == magic)


def reconcile_hedging_positions(positions):
    """Each broker ticket is an independently selectable position/leg."""
    return {p.ticket: p for p in positions}


def reconcile_netting_position(positions, symbol):
    """A netting symbol must resolve to one aggregate broker position."""
    matches = [p for p in positions if p.symbol == symbol]
    if len(matches) > 1:
        return None
    return matches[0] if matches else None


class AccountRiskReferenceTests(unittest.TestCase):
    def setUp(self):
        self.positions = [
            Position("XAUUSD", 1500015, 101, 9001, 0.02, 4.0),
            Position("GBPJPY", 1500015, 102, 9002, 0.01, 2.0),
            Position("EURUSD", 77, 103, 9003, 0.03, 1.0),
        ]

    def test_account_risk_includes_all_symbols_and_magics(self):
        self.assertEqual(aggregate_account_risk(self.positions), 7.0)

    def test_campaign_risk_is_scoped_to_symbol_and_magic(self):
        self.assertEqual(aggregate_campaign_risk(self.positions, "XAUUSD", 1500015), 4.0)

    def test_any_unprotected_position_blocks_new_account_risk(self):
        positions = self.positions + [
            Position("US30", 999, 104, 9004, 0.1, 0.0, protected=False)
        ]
        self.assertIsNone(aggregate_account_risk(positions))

    def test_invalid_risk_value_fails_closed(self):
        bad = [Position("XAUUSD", 1500015, 1, 1, 0.1, float("nan"))]
        self.assertIsNone(aggregate_account_risk(bad))

    def test_hedging_reconciliation_keeps_each_ticket_separate(self):
        legs = self.positions[:2]
        reconciled = reconcile_hedging_positions(legs)
        self.assertEqual(set(reconciled), {101, 102})
        self.assertEqual(sum(p.stop_risk_money for p in reconciled.values()), 6.0)

    def test_netting_reconciliation_expects_one_aggregate_position_per_symbol(self):
        aggregate = Position("XAUUSD", 1500015, 201, 9901, 0.05, 6.5)
        self.assertEqual(reconcile_netting_position([aggregate], "XAUUSD"), aggregate)

    def test_netting_duplicate_symbol_snapshot_is_untrusted(self):
        duplicates = [
            Position("XAUUSD", 1500015, 201, 9901, 0.02, 2.0),
            Position("XAUUSD", 1500015, 202, 9902, 0.03, 3.0),
        ]
        self.assertIsNone(reconcile_netting_position(duplicates, "XAUUSD"))

    def test_coordinator_source_uses_broker_stop_profit_calculation(self):
        source = COORDINATOR.read_text(encoding="utf-8")
        self.assertIn("PositionsTotal()", source)
        self.assertIn("PositionGetTicket(i)", source)
        self.assertIn("PositionGetDouble(POSITION_SL)", source)
        self.assertIn("OrderCalcProfit(orderType,symbol,volume,entry,stop,pnlAtStop)", source)
        self.assertIn("UNPROTECTED_OR_INVALID_POSITION", source)
        self.assertIn("ACCOUNT_OPEN_RISK_CAP_EXCEEDED", source)
        self.assertIn("CAMPAIGN_RISK_CAP_EXCEEDED", source)

    def test_live_entry_path_calls_account_campaign_gate_after_final_sizing(self):
        source = EA.read_text(encoding="utf-8")
        self.assertIn('#include <AutopsyX/AccountCampaignCoordinator.mqh>', source)
        self.assertIn("g_campaignRisk.CanAdmitEntry(", source)
        self.assertIn("MathMin(2.0,InpMaxCampaignRiskPercent)", source)
        self.assertIn("InpMaxAccountOpenRiskPercent", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
