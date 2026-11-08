"""Source-contract regression tests for the live FlipDemon trade lifecycle.

These tests inspect the actual MQL5 implementation. They do not emulate broker
execution and do not replace MetaEditor compilation or MT5 Strategy Tester runs.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")
LIFECYCLE = (ROOT / "MQL5/Include/AutopsyX/TradeLifecycle.mqh").read_text(encoding="utf-8-sig")
RECOVERY = (ROOT / "MQL5/Include/AutopsyX/RestartRecovery.mqh").read_text(encoding="utf-8-sig")


def section(source: str, start: str, end: str) -> str:
    begin = source.find(start)
    if begin < 0:
        raise AssertionError(f"start marker not found: {start}")
    finish = source.find(end, begin + len(start))
    if finish < 0:
        raise AssertionError(f"end marker not found: {end}")
    return source[begin:finish]


class FlipDemonLifecycleContractTests(unittest.TestCase):
    def test_lifecycle_rejects_skipped_execution_states(self):
        self.assertIn(
            "case AX_LIFECYCLE_ORDER_SUBMITTED:  return(to==AX_LIFECYCLE_ORDER_FILLED);",
            LIFECYCLE,
        )
        self.assertIn(
            "case AX_LIFECYCLE_ORDER_FILLED:     return(to==AX_LIFECYCLE_POSITION_ACTIVE);",
            LIFECYCLE,
        )
        self.assertIn(
            "case AX_LIFECYCLE_POSITION_ACTIVE:  return(to==AX_LIFECYCLE_POSITION_MANAGED || to==AX_LIFECYCLE_EXIT_TRIGGERED);",
            LIFECYCLE,
        )

    def test_partial_fill_uses_broker_confirmed_volume(self):
        entry = section(EA, "bool entryOutcomeUncertain=false;", "// Snapshot the actual engine states at fill time.")
        self.assertIn("g_exec.OpenMarket(", entry)
        self.assertIn("g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_ORDER_FILLED)", entry)
        self.assertIn("lots = actualLots;", entry)
        self.assertRegex(entry, r"AxInitPositionState\(newTicket,dir,lots,fillPrice")
        self.assertNotIn("lots = requestedLots;", entry)

    def test_uncertain_submission_is_not_marked_failed_or_retried(self):
        entry = section(EA, "bool entryOutcomeUncertain=false;", "// Snapshot the actual engine states at fill time.")
        self.assertIn(
            "if(!entryOutcomeUncertain && g_tradeLifecycle.State()==AX_LIFECYCLE_ORDER_SUBMITTED)",
            entry,
        )
        self.assertIn("g_distributedRecoveryPending=true;", entry)
        self.assertIn("g_accountRiskIntegrityLock=true;", entry)
        self.assertIn("reservation retained and all new entries locked", entry)
        self.assertIn("MarkExecutionUncertain", entry)

    def test_definitive_broker_rejection_fails_lifecycle_and_reconciles_reservation(self):
        entry = section(EA, "bool entryOutcomeUncertain=false;", "// Snapshot the actual engine states at fill time.")
        self.assertIn("g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_FAILED);", entry)
        self.assertIn("MarkExecutionRejected", entry)
        self.assertIn("g_distributedRiskCoordinator.Release(", entry)
        self.assertIn("g_distributedRecoveryPending=true;", entry)

    def test_restart_recovery_restores_only_persisted_setup_identity(self):
        self.assertIn("FindByPositionIdentifier", RECOVERY)
        self.assertIn("UNTRACKED", RECOVERY)
        self.assertIn("m_records[i].setupId", RECOVERY)
        self.assertIn("positionIdentifier", RECOVERY)
        self.assertIn("g_restartRecovery.Reconcile(", EA)
        self.assertIn("g_recoveryReady=false;", EA)

    def test_external_close_requires_real_exit_deal_and_durable_journal_before_autopsy(self):
        transaction = section(EA, "void OnTradeTransaction(", "void OnChartEvent(")
        self.assertIn("TRADE_TRANSACTION_DEAL_ADD", transaction)
        self.assertIn("DEAL_ENTRY_OUT", transaction)
        self.assertIn("AxFetchCloseFinancials(", transaction)
        self.assertIn("AxFinalizeTrade(", transaction)

        finalize = section(EA, "void AxFinalizeTrade(", "bool AxCloseAndRecord(")
        self.assertIn("g_autopsy.RecordTrade(rec);", finalize)
        self.assertIn("LastAccountedDealTicket(g_positionIdentifier)<lastDealTicket", finalize)
        self.assertIn("AX_LIFECYCLE_EXIT_TRIGGERED", finalize)
        self.assertIn("AX_LIFECYCLE_POSITION_CLOSED", finalize)
        self.assertIn("AX_LIFECYCLE_JOURNALED", finalize)
        self.assertIn("AX_LIFECYCLE_AUTOPSIED", finalize)


if __name__ == "__main__":
    unittest.main(verbosity=2)
