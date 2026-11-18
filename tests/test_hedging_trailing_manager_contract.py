"""Static contracts for per-ticket hedging trailing-stop management."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)
REGISTRY = (ROOT / "MQL5/Include/AutopsyX/VirtualExitRegistry.mqh").read_text(
    encoding="utf-8-sig"
)


class HedgingTrailingManagerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        start = EA.index("bool AxManageHedgingTrailingTickets(void)")
        end = EA.index("//====================================================================\n// MAIN TICK LOOP", start)
        cls.method = EA[start:end]

    def test_manager_processes_each_live_leg(self):
        self.assertIn("i<g_hedgingPositionManager.Count()", self.method)
        self.assertIn("g_hedgingPositionManager.GetAt(i,live)", self.method)

    def test_trailing_only_activates_after_configured_favorable_move(self):
        self.assertIn("InpTrailStartPoints", self.method)
        self.assertIn("favorablePoints<InpTrailStartPoints", self.method)
        self.assertIn("InpTrailDistancePoints", self.method)

    def test_trailing_stop_is_monotonic_for_both_directions(self):
        self.assertIn("candidate<=live.stopLoss+tickSize*0.5", self.method)
        self.assertIn("candidate>=live.stopLoss-tickSize*0.5", self.method)
        self.assertIn("candidate<=saved.trailingStopPrice+tickSize*0.5", self.method)
        self.assertIn("candidate>=saved.trailingStopPrice-tickSize*0.5", self.method)

    def test_action_lock_precedes_exact_ticket_modification(self):
        lock = self.method.index("BeginAction(live.positionIdentifier,2)")
        modify = self.method.index("g_exec.ModifyStopsByTicket(")
        self.assertLess(lock, modify)

    def test_broker_stop_and_tp_verified_before_trailing_state_persisted(self):
        identity = self.method.index("PositionSelectByTicket(live.ticket)")
        persist = self.method.index("RecordTrailingStop(live.positionIdentifier,confirmedSl)")
        release = self.method.index("ResolveAction(live.positionIdentifier,2)")
        self.assertLess(identity, persist)
        self.assertLess(persist, release)
        self.assertIn("tpPreserved", self.method)

    def test_uncertain_broker_result_keeps_lock_and_quarantines(self):
        start = self.method.index("if(!g_exec.ModifyStopsByTicket(")
        block = self.method[start:start + 900]
        self.assertIn("action lock retained", block)
        self.assertIn("g_hedgingLifecycleLock=true", block)

    def test_trailing_manager_runs_after_break_even_before_snapshot_refresh(self):
        be = EA.index("AxManageHedgingBreakEvenTickets()")
        trail = EA.index("AxManageHedgingTrailingTickets()", be)
        refresh = EA.index("g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)", trail)
        self.assertLess(be, trail)
        self.assertLess(trail, refresh)

    def test_registry_rejects_invalid_or_weaker_trailing_prices(self):
        start = REGISTRY.index("bool RecordTrailingStop(")
        end = REGISTRY.index("bool RecordBreakEven(", start)
        method = REGISTRY[start:end]
        self.assertIn("!MathIsValidNumber(confirmedStop)", method)
        self.assertIn("confirmedStop<record.initialSlPrice", method)
        self.assertIn("confirmedStop>record.initialSlPrice", method)
        self.assertIn("confirmedStop<record.trailingStopPrice", method)
        self.assertIn("confirmedStop>record.trailingStopPrice", method)


if __name__ == "__main__":
    unittest.main(verbosity=2)
