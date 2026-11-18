"""Source contracts for ticket-specific hedging break-even management.

These checks do not compile MQL5 or simulate broker execution.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)


class HedgingBreakEvenManagerContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        start = EA.index("bool AxManageHedgingBreakEvenTickets(void)")
        end = EA.index("//====================================================================\n// MAIN TICK LOOP", start)
        cls.method = EA[start:end]

    def test_manager_iterates_every_broker_snapshot_leg(self):
        self.assertIn("i<g_hedgingPositionManager.Count()", self.method)
        self.assertIn("g_hedgingPositionManager.GetAt(i,live)", self.method)

    def test_stable_identity_and_unlocked_durable_state_are_required(self):
        self.assertIn("live.positionIdentifier", self.method)
        self.assertIn("saved.actionLocked", self.method)
        self.assertIn("saved.ticket!=live.ticket", self.method)

    def test_action_lock_precedes_exact_ticket_modification(self):
        lock = self.method.index("g_virtualExitRegistry.BeginAction(live.positionIdentifier,1)")
        modify = self.method.index("g_exec.ModifyStopsByTicket(")
        self.assertLess(lock, modify)

    def test_broker_identity_and_stop_are_verified_before_persistence(self):
        identity = self.method.index("PositionSelectByTicket(live.ticket)")
        persist = self.method.index("g_virtualExitRegistry.RecordBreakEven(")
        release = self.method.index("g_virtualExitRegistry.ResolveAction(live.positionIdentifier,1)")
        self.assertLess(identity, persist)
        self.assertLess(persist, release)

    def test_uncertain_failure_retains_lock_and_quarantines_campaign(self):
        failure = self.method.index("if(!g_exec.ModifyStopsByTicket(")
        block = self.method[failure:failure + 1100]
        self.assertIn("action lock retained", block)
        self.assertIn("g_hedgingLifecycleLock=true", block)

    def test_multi_leg_manager_runs_before_lifecycle_audit(self):
        call = EA.index("AxManageHedgingBreakEvenTickets()")
        audit = EA.index("g_hedgingCampaignLifecycle.Evaluate", call)
        refresh = EA.index("g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)", call)
        self.assertLess(call, refresh)
        self.assertLess(refresh, audit)


if __name__ == "__main__":
    unittest.main(verbosity=2)
