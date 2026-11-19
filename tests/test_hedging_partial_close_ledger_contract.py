"""Static contracts for the durable per-position partial-close ledger."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LEDGER = (ROOT / "MQL5/Include/AutopsyX/HedgingPartialCloseLedger.mqh").read_text(
    encoding="utf-8-sig"
)
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)


class HedgingPartialCloseLedgerTests(unittest.TestCase):
    def test_ledger_identity_is_position_and_deal_scoped(self):
        self.assertIn("FindIndex(const ulong positionIdentifier,const ulong dealTicket)", LEDGER)
        self.assertIn("m_records[i].positionIdentifier==positionIdentifier", LEDGER)
        self.assertIn("m_records[i].dealTicket==dealTicket", LEDGER)

    def test_ledger_persists_broker_confirmed_entry_and_exit_facts(self):
        for field in (
            "positionIdentifier", "dealTicket", "symbol", "magic", "direction",
            "entryTime", "entryPrice", "entryVolume", "closeTime", "closePrice",
            "closedVolume", "grossProfit", "commission", "swap",
        ):
            self.assertIn(field, LEDGER)
        self.assertIn("closedVolume>=r.entryVolume", LEDGER)

    def test_ledger_rejects_invalid_numeric_values(self):
        self.assertIn("MathIsValidNumber(r.entryPrice)", LEDGER)
        self.assertIn("MathIsValidNumber(r.entryVolume)", LEDGER)
        self.assertIn("MathIsValidNumber(r.closePrice)", LEDGER)
        self.assertIn("MathIsValidNumber(r.closedVolume)", LEDGER)
        self.assertIn("MathIsValidNumber(r.grossProfit)", LEDGER)
        self.assertIn("MathIsValidNumber(r.commission)", LEDGER)
        self.assertIn("MathIsValidNumber(r.swap)", LEDGER)

    def test_duplicate_replay_requires_identical_payload(self):
        record = LEDGER[LEDGER.index("bool Record("):LEDGER.index("bool Find(", LEDGER.index("bool Record("))]
        self.assertIn("if(index>=0)", record)
        self.assertIn("MathAbs(old.grossProfit-record.grossProfit)", record)
        self.assertIn("MathAbs(old.closedVolume-record.closedVolume)", record)

    def test_persistence_uses_staged_atomic_replacement(self):
        self.assertIn('string tempName=m_fileName+".tmp"', LEDGER)
        self.assertIn("FileFlush(handle)", LEDGER)
        self.assertIn("FileMove(tempName,0,m_fileName,FILE_REWRITE)", LEDGER)

    def test_ledger_file_is_scoped_to_account_symbol_and_magic(self):
        self.assertIn("AccountInfoInteger(ACCOUNT_LOGIN)", LEDGER)
        self.assertIn("%I64d_%I64u_HedgingPartialCloses_v1.csv", LEDGER)

    def test_no_single_position_global_state_dependency(self):
        self.assertNotIn("g_posState", LEDGER)
        self.assertNotIn("g_positionIdentifier", LEDGER)

    def test_ea_initializes_independent_ledger_and_stays_fail_closed(self):
        self.assertIn('#include <AutopsyX/HedgingPartialCloseLedger.mqh>', EA)
        self.assertIn("g_hedgingPartialCloseLedger.Init(", EA)
        self.assertIn("g_hedgingPartialLedgerReady=false", EA)
        self.assertIn("multi-position partial-close lifecycle remains quarantined", EA)

    def test_per_position_adapter_uses_saved_entry_facts_not_global_position_state(self):
        start = EA.index("bool AxRecordHedgingPartialCloseLedger(")
        end = EA.index("bool AxFetchCloseFinancials(", start)
        adapter = EA[start:end]
        self.assertIn("saved.positionIdentifier", adapter)
        self.assertIn("saved.entryPrice", adapter)
        self.assertIn("saved.entryVolume", adapter)
        self.assertIn("g_hedgingPartialCloseLedger.Record(record)", adapter)
        self.assertNotIn("g_posState", adapter)
        self.assertNotIn("g_positionIdentifier", adapter)

    def test_partial_slice_cannot_be_misclassified_as_full_position_exit(self):
        self.assertIn("closedVolume>=saved.entryVolume", EA)

    def test_multi_position_recovery_uses_independent_leg_ledger(self):
        start = EA.index("bool AxRecoverHedgingPartialCloseAction(")
        end = EA.index("bool AxRecoverLockedPartialCloseActions(", start)
        recovery = EA[start:end]
        self.assertIn("FindByIdentifier(saved.positionIdentifier,live)", recovery)
        self.assertIn("AxFetchCloseFinancialsByIdentifier(", recovery)
        self.assertIn("AxRecordHedgingPartialCloseLedger(", recovery)
        self.assertIn("RecordPartialClose(saved.positionIdentifier,closedVolume,lastDeal)", recovery)
        self.assertIn("ResolveAction(saved.positionIdentifier,3)", recovery)
        self.assertNotIn("g_posState", recovery)
        self.assertNotIn("g_positionIdentifier", recovery)

    def test_multi_position_recovery_branches_before_single_position_journal(self):
        start = EA.index("bool AxRecoverLockedPartialCloseActions(void)")
        end = EA.index("bool AxReconcilePyramidCampaignTickets(", start)
        recovery = EA[start:end]
        multi = recovery.index("if(g_hedgingPositionManager.HasMultiplePositions())")
        single_journal = recovery.index("g_autopsy.LastAccountedRecord(")
        self.assertLess(multi, single_journal)
        self.assertIn("AxRecoverHedgingPartialCloseAction(hedged)", recovery)
        self.assertIn("g_engineState=AX_ENGINE_PAUSED", recovery)

    def test_ticket_partial_close_manager_uses_per_leg_state_and_exact_ticket(self):
        start = EA.index("bool AxManageHedgingPartialCloseTickets(void)")
        end = EA.index("bool AxManageHedgingBreakEvenTickets(void)", start)
        manager = EA[start:end]
        self.assertIn("g_hedgingPositionManager.GetAt(i,live)", manager)
        self.assertIn("g_virtualExitRegistry.Find(live.positionIdentifier,saved)", manager)
        self.assertIn("g_exec.ClosePartial(live.symbol,live.ticket,live.positionIdentifier", manager)
        self.assertNotIn("g_posState", manager)
        self.assertNotIn("g_positionIdentifier", manager)

    def test_partial_manager_requires_protection_and_validates_completed_slice_ledger(self):
        start = EA.index("bool AxManageHedgingPartialCloseTickets(void)")
        end = EA.index("bool AxManageHedgingBreakEvenTickets(void)", start)
        manager = EA[start:end]
        self.assertIn("!live.hasValidBrokerStop", manager)
        self.assertIn("saved.partialCloseCount!=1", manager)
        self.assertIn("g_hedgingPartialCloseLedger.Find(live.positionIdentifier", manager)
        self.assertIn("accounted.closedVolume-saved.partialClosedVolume", manager)

    def test_partial_close_is_profitable_only_and_broker_volume_grid_safe(self):
        start = EA.index("bool AxManageHedgingPartialCloseTickets(void)")
        end = EA.index("bool AxManageHedgingBreakEvenTickets(void)", start)
        manager = EA[start:end]
        self.assertIn("favorableMove/saved.originalRiskDistance", manager)
        self.assertIn("achievedRR<InpPartialTriggerRR", manager)
        self.assertIn("MathFloor(requestedRaw/volumeStep+1e-9)*volumeStep", manager)
        self.assertIn("residualVolume<minimumVolume", manager)
        self.assertIn("saved.partialCloseCount>0", manager)

    def test_partial_action_lock_precedes_broker_request_and_ledger_commit(self):
        start = EA.index("bool AxManageHedgingPartialCloseTickets(void)")
        end = EA.index("bool AxManageHedgingBreakEvenTickets(void)", start)
        manager = EA[start:end]
        self.assertLess(manager.index("BeginPartialCloseAction("), manager.index("g_exec.ClosePartial("))
        self.assertLess(manager.index("g_exec.ClosePartial("), manager.index("AxFetchCloseFinancialsByIdentifier("))
        self.assertLess(manager.index("AxFetchCloseFinancialsByIdentifier("), manager.index("AxRecordHedgingPartialCloseLedger("))
        self.assertLess(manager.index("AxRecordHedgingPartialCloseLedger("), manager.index("RecordPartialClose("))
        self.assertLess(manager.index("RecordPartialClose("), manager.rindex("ResolveAction("))

    def test_uncertain_partial_execution_retains_lock_and_pauses_campaign(self):
        start = EA.index("bool AxManageHedgingPartialCloseTickets(void)")
        end = EA.index("bool AxManageHedgingBreakEvenTickets(void)", start)
        manager = EA[start:end]
        definite_rejection = manager.index("if(!outcomeUncertain)")
        uncertain = manager.index("g_virtualExitReady=false", definite_rejection)
        self.assertIn("g_hedgingLifecycleLock=true", manager[uncertain:])
        self.assertIn("g_engineState=AX_ENGINE_PAUSED", manager[uncertain:])
        self.assertIn("no second close request", manager[uncertain:])

    def test_multi_position_tick_runs_partial_manager_before_quarantine(self):
        start = EA.index("void AxProcessTick(void)")
        end = EA.index("SAxHedgingCampaignSnapshot hedgingSnapshot", start)
        tick = EA[start:end]
        self.assertIn("AxManageHedgingPartialCloseTickets()", tick)
        self.assertLess(tick.index("AxManageHedgingPartialCloseTickets()"),
                        tick.index("g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)", tick.index("AxManageHedgingPartialCloseTickets()")))
        self.assertIn("AxReconcileVirtualExitTickets(false)", tick)

    def test_runtime_tick_recovers_locked_partial_before_virtual_exit_reconcile(self):
        start = EA.index("void AxProcessTick(void)")
        end = EA.index("SAxHedgingCampaignSnapshot hedgingSnapshot", start)
        tick = EA[start:end]
        self.assertLess(tick.index("AxRecoverLockedPartialCloseActions()"),
                        tick.index("AxReconcileVirtualExitTickets(false)"))
        self.assertIn("AxManageHedgingPartialCloseTickets()", tick)

    def test_recovery_handles_ledger_commit_before_virtual_exit_cursor(self):
        start = EA.index("bool AxRecoverHedgingPartialCloseAction(")
        end = EA.index("bool AxRecoverLockedPartialCloseActions(", start)
        recovery = EA[start:end]
        self.assertIn("ledgerHighWater>=saved.partialLastDealTicket", recovery)
        self.assertIn("RecordPartialClose(saved.positionIdentifier,", recovery)
        self.assertIn("accounted.closeTime<saved.actionStartedAt", recovery)
        self.assertNotIn("if(ledgerHighWater>saved.partialLastDealTicket)\n      return(false);", recovery)

    def test_recovery_resolves_crash_after_ledger_and_registry_commit(self):
        start = EA.index("bool AxRecoverHedgingPartialCloseAction(")
        end = EA.index("bool AxRecoverLockedPartialCloseActions(", start)
        recovery = EA[start:end]
        self.assertIn("g_hedgingPartialCloseLedger.Find(saved.positionIdentifier", recovery)
        self.assertIn("accounted.closeTime<saved.actionStartedAt", recovery)
        self.assertIn("HistorySelectByPosition((long)saved.positionIdentifier)", recovery)
        self.assertIn("dealTime==accounted.closeTime", recovery)
        self.assertIn("ResolveAction(saved.positionIdentifier,3)", recovery)


if __name__ == "__main__":
    unittest.main(verbosity=2)
