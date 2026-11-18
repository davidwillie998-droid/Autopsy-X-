"""Static contracts for restart recovery of locked stop modifications."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)


class HedgingStopActionRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        start = EA.index("bool AxRecoverLockedStopAction(")
        end = EA.index("// Reconcile every persisted virtual-exit row", start)
        cls.recovery = EA[start:end]
        start = EA.index("bool AxReconcileVirtualExitTickets(")
        end = EA.index("\n// Reconstruct a completed position", start)
        cls.reconcile = EA[start:end]

    def test_recovery_uses_stable_identity_and_live_broker_stop(self):
        self.assertIn("saved.positionIdentifier!=live.positionIdentifier", self.recovery)
        self.assertIn("live.hasValidBrokerStop", self.recovery)
        self.assertIn("live.stopLoss", self.recovery)

    def test_unchanged_stop_resolves_only_matching_stop_action(self):
        self.assertIn("MathAbs(live.stopLoss-saved.emergencySlPrice)", self.recovery)
        self.assertIn("ResolveAction(live.positionIdentifier,saved.actionCode)", self.recovery)

    def test_tighter_break_even_stop_is_validated_against_entry(self):
        self.assertIn("atBreakEven", self.recovery)
        self.assertIn("RecordBreakEven(live.positionIdentifier", self.recovery)

    def test_trailing_recovery_requires_durable_break_even(self):
        self.assertIn("if(!saved.breakEvenDone) return(false)", self.recovery)
        self.assertIn("RecordTrailingStop(live.positionIdentifier", self.recovery)

    def test_persisted_state_precedes_action_lock_release(self):
        persist = self.recovery.index("stateRecorded=g_virtualExitRegistry.Record")
        release = self.recovery.index("ResolveAction(live.positionIdentifier,saved.actionCode)", persist)
        self.assertLess(persist, release)

    def test_unknown_or_unprovable_action_remains_quarantined(self):
        self.assertIn("saved.actionLocked", self.reconcile)
        self.assertIn("no retry or lock release", self.reconcile)
        self.assertIn("deal-history/manual reconciliation required", self.reconcile)

    def test_recovery_runs_before_normal_stop_state_comparison(self):
        recover = self.reconcile.index("AxRecoverLockedStopAction(live,saved)")
        normal_compare = self.reconcile.index("MathAbs(saved.emergencySlPrice-live.stopLoss)")
        self.assertLess(recover, normal_compare)


    def test_existing_partial_close_recovery_remains_a_real_function(self):
        self.assertIn("bool AxRecoverLockedPartialCloseActions(void)", EA)
        self.assertNotIn("//bool AxRecoverLockedPartialCloseActions(void)", EA)
        self.assertIn("if(AxRecoverLockedPartialCloseActions())", EA)

    def test_startup_runs_locked_action_recovery_before_normal_trading(self):
        recovery = EA.index("if(AxRecoverLockedPartialCloseActions())")
        init_tail = EA.index("void AxProcessTick(void)")
        self.assertLess(recovery, init_tail)


if __name__ == "__main__":
    unittest.main(verbosity=2)
