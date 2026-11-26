from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
VIRTUAL_EXIT = (ROOT / "MQL5/Include/AutopsyX/VirtualExitRegistry.mqh").read_text()
FULL_LEDGER = (ROOT / "MQL5/Include/AutopsyX/HedgingFullCloseLedger.mqh").read_text()


def recovery_block():
    start = EA.index("bool AxRecoverLockedHedgingFullCloseActions(void)")
    end = EA.index("bool AxRecoverLockedPartialCloseActions(void)", start)
    return EA[start:end]


def test_full_close_recovery_refreshes_broker_truth_before_finalization():
    recovery = recovery_block()
    refresh = recovery.index("g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)")
    live_check = recovery.index("g_hedgingPositionManager.FindByIdentifier(saved.positionIdentifier,stillLive)")
    finalize = recovery.index("AxFinalizeHedgingFullClose(saved)")
    assert refresh < live_check < finalize
    assert "broker snapshot incomplete; locked actions preserved" in recovery


def test_still_live_or_partially_closed_position_keeps_action_lock_without_retry():
    recovery = recovery_block()
    live_check = recovery.index("g_hedgingPositionManager.FindByIdentifier(saved.positionIdentifier,stillLive)")
    quarantine = recovery.index("action lock retained and no retry issued")
    assert live_check < quarantine
    assert "AxCloseHedgingPositionByTicket" not in recovery
    assert "ResolveAction" not in recovery


def test_broker_flat_is_not_enough_without_complete_exit_deal_volume():
    start = EA.index("bool AxBuildHedgingFullCloseRecord(")
    end = EA.index("bool AxFinalizeHedgingFullClose(", start)
    builder = EA[start:end]
    assert "MathAbs(exitVolume-saved.entryVolume)>volumeTolerance" in builder
    assert "MathAbs(entryVolume-saved.entryVolume)>volumeTolerance" in builder
    assert "lastExitTime<saved.actionStartedAt" in builder


def test_full_close_finalization_remains_idempotent_and_ordered():
    start = EA.index("bool AxFinalizeHedgingFullClose(")
    end = EA.index("bool AxRecoverLockedHedgingFullCloseActions(", start)
    finalizer = EA[start:end]
    assert "g_hedgingFullCloseLedger.Record(finalRecord)" in finalizer
    assert "g_hedgingFullCloseLedger.Find(saved.positionIdentifier,verified)" in finalizer
    assert finalizer.index("g_hedgingFullCloseLedger.Record(finalRecord)") < finalizer.index("g_positionStateRegistry.Remove(saved.positionIdentifier)") < finalizer.index("g_virtualExitRegistry.Remove(saved.positionIdentifier)")


def test_virtual_exit_lock_cannot_be_cleared_without_matching_action_code():
    assert "record.actionCode!=expectedActionCode" in VIRTUAL_EXIT
    assert "record.actionLocked=false;" in VIRTUAL_EXIT
    assert "record.actionBaselineVolume=0.0;" in VIRTUAL_EXIT


def test_full_close_journal_accepts_only_identical_replay_for_position_identity():
    assert "if(index>=0) return(SameRecord(m_records[index],record));" in FULL_LEDGER
    assert "a.positionIdentifier==b.positionIdentifier" in FULL_LEDGER
    assert "a.finalDealTicket==b.finalDealTicket" in FULL_LEDGER
    assert "a.totalClosedVolume-b.totalClosedVolume" in FULL_LEDGER
