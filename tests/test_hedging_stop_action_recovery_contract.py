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
        start = EA.index("bool AxRecoverLockedPartialCloseActions(void)")
        end = EA.index("\n//", start)
        recovery = EA[start:end]
        self.assertIn("if(!g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting()", recovery)
        self.assertIn("AxRecoverHedgingPartialCloseAction(hedged)", recovery)
        self.assertIn("g_hedgingLifecycleLock=true", recovery)
        self.assertIn("no retry or journal mutation", recovery)

    def test_startup_recovers_full_close_before_partial_close_before_reconcile(self):
        init = EA.index("int OnInit(void)")
        tick = EA.index("void AxProcessTick(void)")
        startup = EA[init:tick]
        full_close = startup.index("if(AxRecoverLockedHedgingFullCloseActions() &&")
        partial_close = startup.index("AxRecoverLockedPartialCloseActions()", full_close)
        reconcile = startup.index("AxReconcileVirtualExitTickets(true)", partial_close)
        self.assertLess(full_close, partial_close)
        self.assertLess(partial_close, reconcile)
        self.assertIn("unresolved full/partial close recovery blocked startup reconciliation", startup)

    def test_tick_retries_full_and_partial_recovery_before_virtual_exit_reconciliation(self):
        tick = EA.index("void AxProcessTick(void)")
        tick_body = EA[tick:]
        full_close = tick_body.index("if(!AxRecoverLockedHedgingFullCloseActions()) return;")
        partial_close = tick_body.index("if(!AxRecoverLockedPartialCloseActions()) return;", full_close)
        reconcile = tick_body.index("if(!AxReconcileVirtualExitTickets(false)) return;", partial_close)
        self.assertLess(full_close, partial_close)
        self.assertLess(partial_close, reconcile)


if __name__ == "__main__":
    unittest.main(verbosity=2)


class HedgingPartialCloseHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        start = EA.index("bool AxFetchCloseFinancialsByIdentifier(")
        end = EA.index("bool AxFetchCloseFinancials(", start)
        cls.reader = EA[start:end]

    def test_reader_is_position_identifier_scoped(self):
        self.assertIn("HistorySelectByPosition((long)positionIdentifier)", self.reader)
        self.assertIn("DEAL_POSITION_ID", self.reader)
        self.assertNotIn("g_posState", self.reader)
        self.assertNotIn("g_positionIdentifier", self.reader)

    def test_reader_validates_symbol_magic_and_direction(self):
        self.assertIn("expectedSymbol", self.reader)
        self.assertIn("expectedMagic", self.reader)
        self.assertIn("expectedCloseType", self.reader)
        self.assertIn("DEAL_TYPE", self.reader)

    def test_reader_uses_exclusive_deal_ticket_cursor(self):
        self.assertIn("dealTicket<=sinceTicketExclusive", self.reader)
        self.assertIn("lastDealTicketOut=dealTicket", self.reader)

    def test_reader_rejects_ambiguous_reversal_allocation(self):
        self.assertIn("entryType==DEAL_ENTRY_INOUT", self.reader)

    def test_reader_aggregates_only_confirmed_exit_deals(self):
        self.assertIn("DEAL_ENTRY_OUT", self.reader)
        self.assertIn("DEAL_ENTRY_OUT_BY", self.reader)
        self.assertIn("weightedCloseValue+=dealPrice*dealVolume", self.reader)
        self.assertIn("closedVolumeOut+=dealVolume", self.reader)

    def test_reader_rejects_invalid_financial_values(self):
        self.assertIn("MathIsValidNumber(dealVolume)", self.reader)
        self.assertIn("MathIsValidNumber(dealProfit)", self.reader)
        self.assertIn("MathIsValidNumber(dealCommission)", self.reader)
        self.assertIn("MathIsValidNumber(dealSwap)", self.reader)


class PerPositionEntryMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = (ROOT / "MQL5/Include/AutopsyX/VirtualExitRegistry.mqh").read_text(
            encoding="utf-8-sig"
        )
        cls.save_state = EA[EA.index("bool AxSaveVirtualExitState("):EA.index(
            "bool AxRecoverLockedStopAction("
        )]

    def test_registry_persists_original_entry_price_and_volume(self):
        self.assertIn("double      entryPrice", self.registry)
        self.assertIn("double      entryVolume", self.registry)
        self.assertIn("Number(r.entryPrice),Number(r.entryVolume)", self.registry)
        self.assertIn("record.entryPrice<0.0 || record.entryVolume<0.0", self.registry)

    def test_new_registry_format_has_23_fields(self):
        self.assertIn("#define AX_VIRTUAL_EXIT_FIELD_COUNT 23", self.registry)
        serializer = self.registry[self.registry.index("string line=StringFormat("):
                                    self.registry.index("string payload=line", self.registry.index("string line=StringFormat("))]
        self.assertEqual(serializer.count("%I64u") + serializer.count("%s") + serializer.count("%d"), 23)

    def test_old_registry_formats_remain_readable(self):
        self.assertIn("fieldCount!=AX_VIRTUAL_EXIT_LEGACY_FIELD_COUNT", self.registry)
        self.assertIn("fieldCount!=20 && fieldCount!=21", self.registry)
        self.assertIn("fieldCount==21 || fieldCount==AX_VIRTUAL_EXIT_FIELD_COUNT", self.registry)
        self.assertIn("entryMetadataFormat=(fieldCount==AX_VIRTUAL_EXIT_FIELD_COUNT)", self.registry)

    def test_legacy_rows_do_not_invent_original_volume(self):
        self.assertIn("entryMetadataFormat ? StringToDouble(f[22]) : 0.0", self.registry)
        self.assertIn("record.entryVolume=(found ? existing.entryVolume : 0.0)", self.save_state)
        self.assertIn("if(!found && isNewFill)", self.save_state)

    def test_entry_price_and_original_volume_are_captured_from_broker_fill(self):
        self.assertIn("record.entryPrice=entry", self.save_state)
        self.assertIn("PositionGetDouble(POSITION_VOLUME)", self.save_state)
        self.assertIn("record.entryVolume=PositionGetDouble(POSITION_VOLUME)", self.save_state)


