"""Static contracts for per-ticket hedging full-close execution and recovery."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)
REGISTRY = (ROOT / "MQL5/Include/AutopsyX/VirtualExitRegistry.mqh").read_text(
    encoding="utf-8-sig"
)
LEDGER = (ROOT / "MQL5/Include/AutopsyX/HedgingFullCloseLedger.mqh").read_text(
    encoding="utf-8-sig"
)


class HedgingFullCloseLifecycleTests(unittest.TestCase):
    def test_full_close_has_distinct_durable_action_code_and_baseline(self):
        self.assertIn("BeginFullCloseAction(const ulong positionIdentifier", REGISTRY)
        self.assertIn("record.actionCode=4", REGISTRY)
        self.assertIn("record.actionBaselineVolume=baselineVolume", REGISTRY)

    def test_exact_ticket_close_requires_durable_lock_first(self):
        body = EA.split("bool AxCloseHedgingPositionByTicket", 1)[1].split(
            "bool AxManageHedgingPartialCloseTickets", 1
        )[0]
        self.assertLess(body.index("BeginFullCloseAction"), body.index("ClosePositionByTicket"))
        self.assertIn("live.ticket", body)
        self.assertIn("live.positionIdentifier", body)
        self.assertIn("live.magic", body)

    def test_uncertain_close_retains_lock_and_never_retries(self):
        body = EA.split("bool AxCloseHedgingPositionByTicket", 1)[1].split(
            "bool AxManageHedgingPartialCloseTickets", 1
        )[0]
        self.assertIn("if(!outcomeUncertain)", body)
        self.assertIn("action lock retained, no retry", body)
        self.assertIn("g_accountRiskReconciliationPending=true", body)

    def test_final_record_aggregates_complete_position_history(self):
        body = EA.split("bool AxBuildHedgingFullCloseRecord", 1)[1].split(
            "bool AxFinalizeHedgingFullClose", 1
        )[0]
        for term in (
            "HistorySelectByPosition", "DEAL_POSITION_ID", "DEAL_ENTRY_INOUT",
            "DEAL_ENTRY_IN", "DEAL_ENTRY_OUT", "DEAL_ENTRY_OUT_BY",
            "DEAL_PROFIT", "DEAL_COMMISSION", "DEAL_SWAP", "DEAL_FEE",
            "DEAL_VOLUME", "DEAL_PRICE",
        ):
            self.assertIn(term, body)
        self.assertIn("exitVolume-saved.entryVolume", body)
        self.assertIn("exitVolume-saved.partialClosedVolume", body)

    def test_partial_slice_must_match_its_own_durable_ledger_row(self):
        body = EA.split("bool AxBuildHedgingFullCloseRecord", 1)[1].split(
            "bool AxFinalizeHedgingFullClose", 1
        )[0]
        self.assertIn("g_hedgingPartialCloseLedger.Find", body)
        self.assertIn("partial.closedVolume-saved.partialClosedVolume", body)

    def test_full_close_ledger_precedes_virtual_exit_removal(self):
        body = EA.split("bool AxFinalizeHedgingFullClose", 1)[1].split(
            "bool AxRecoverLockedHedgingFullCloseActions", 1
        )[0]
        self.assertLess(body.index("g_hedgingFullCloseLedger.Record"),
                        body.index("g_virtualExitRegistry.Remove"))
        self.assertIn("g_hedgingFullCloseLedger.Find", body)

    def test_recovery_is_action_code_four_and_does_not_submit_close(self):
        body = EA.split("bool AxRecoverLockedHedgingFullCloseActions", 1)[1].split(
            "bool AxRecoverLockedPartialCloseActions", 1
        )[0]
        self.assertIn("saved.actionCode!=4", body)
        self.assertIn("AxFinalizeHedgingFullClose(saved)", body)
        self.assertNotIn("ClosePositionByTicket", body)
        self.assertIn("no close retry issued", body)

    def test_startup_and_tick_recover_full_closes_before_normal_reconciliation(self):
        self.assertIn("AxRecoverLockedHedgingFullCloseActions() &&", EA)
        tick = EA.split("void AxProcessTick(void)", 1)[1]
        self.assertLess(tick.index("AxRecoverLockedHedgingFullCloseActions"),
                        tick.index("AxReconcileVirtualExitTickets(false)"))

    def test_full_close_ledger_accounts_for_fees_and_is_idempotent(self):
        self.assertIn("double fees", LEDGER)
        self.assertIn("a.fees-b.fees", LEDGER)
        self.assertIn("return(SameRecord(m_records[index],record))", LEDGER)


if __name__ == "__main__":
    unittest.main(verbosity=2)
