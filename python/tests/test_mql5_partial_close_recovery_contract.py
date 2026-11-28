"""Source-contract regression tests for MQL5 hedging partial-close recovery.

These tests do not replace MetaEditor or Strategy Tester execution. They guard
critical fail-closed source invariants until the native MQL5 test harness runs.
"""
from pathlib import Path

import re


ROOT = Path(__file__).resolve().parents[2]
EA_SOURCE = ROOT / "MQL5" / "Experts" / "AutopsyX" / "AutopsyX_FlipDemon_Extreme.mq5"


def _source() -> str:
    assert EA_SOURCE.is_file(), f"EA source not found: {EA_SOURCE}"
    return EA_SOURCE.read_text(encoding="utf-8")


def _function_body(source: str, signature: str, next_signature: str) -> str:
    start = source.find(signature)
    assert start >= 0, f"Missing function signature: {signature}"
    end = source.find(next_signature, start + len(signature))
    assert end > start, f"Could not bound function: {signature}"
    return source[start:end]


def test_identifier_close_reader_rejects_reversal_and_foreign_deals():
    source = _source()
    body = _function_body(
        source,
        "bool AxFetchCloseFinancialsByIdentifier(",
        "// Persist one reconciled partial-exit slice",
    )
    assert "HistorySelectByPosition((long)positionIdentifier)" in body
    assert "DEAL_ENTRY_INOUT" in body
    assert "expectedSymbol" in body
    assert "expectedMagic" in body
    assert "expectedCloseType" in body
    assert "MathIsValidNumber(dealVolume)" in body
    assert "MathIsValidNumber(dealPrice)" in body
    assert "MathIsValidNumber(dealProfit)" in body
    assert "MathIsValidNumber(dealCommission)" in body
    assert "MathIsValidNumber(dealSwap)" in body


def test_restart_recovery_rebuilds_complete_broker_deal_slice():
    source = _source()
    body = _function_body(
        source,
        "bool AxRecoverHedgingPartialCloseAction(",
        "double closePrice=0.0,grossProfit=0.0,commission=0.0,swap=0.0,closedVolume=0.0;",
    )
    assert "AxFetchCloseFinancialsByIdentifier(" in body
    assert "historyLastDeal!=ledgerHighWater" in body
    assert "historyCloseTime!=accounted.closeTime" in body
    assert "historyClosedVolume-accounted.closedVolume" in body
    assert "historyClosePrice-accounted.closePrice" in body
    assert "historyGross-accounted.grossProfit" in body
    assert "historyCommission-accounted.commission" in body
    assert "historySwap-accounted.swap" in body


def test_action_lock_is_not_released_before_history_and_ledger_match():
    source = _source()
    body = _function_body(
        source,
        "bool AxRecoverHedgingPartialCloseAction(",
        "double closePrice=0.0,grossProfit=0.0,commission=0.0,swap=0.0,closedVolume=0.0;",
    )
    history_check = body.find("historySwap-accounted.swap")
    unlock = body.find("ResolveAction(saved.positionIdentifier,3)")
    assert history_check >= 0
    assert unlock > history_check


def test_uncertain_partial_recovery_never_submits_another_close_request():
    source = _source()
    body = _function_body(
        source,
        "bool AxRecoverHedgingPartialCloseAction(",
        "double closePrice=0.0,grossProfit=0.0,commission=0.0,swap=0.0,closedVolume=0.0;",
    )
    assert "ClosePartial(" not in body
    assert "OrderSend(" not in body
    assert "CTrade" not in body

def test_verified_full_close_removes_all_durable_lifecycle_indexes():
    source = _source()
    body = _function_body(
        source,
        "bool AxFinalizeHedgingFullClose(",
        "// Restart/tick recovery for actionCode=4",
    )
    ledger_commit = body.find("g_hedgingFullCloseLedger.Record(finalRecord)")
    setup_remove = body.find("RemoveOpenSetupByPositionIdentifier")
    position_remove = body.find("g_positionStateRegistry.Remove(saved.positionIdentifier)")
    exit_remove = body.find("g_virtualExitRegistry.Remove(saved.positionIdentifier)")
    assert min(ledger_commit, setup_remove, position_remove, exit_remove) >= 0
    assert ledger_commit < setup_remove < position_remove < exit_remove
    assert "!g_recoveryInitialized" in body
    assert "!g_restartRecovery.IsPersisting()" in body

def test_broker_ticket_refresh_updates_durable_position_state_by_stable_identifier():
    source = _source()
    body = _function_body(
        source,
        "bool AxReconcileVirtualExitTickets(",
        "// Reconstruct a completed position whose final close happened while the EA was offline.",
    )
    assert "FindByIdentifier(live.positionIdentifier,positionState)" in body
    assert "positionState.positionIdentifier!=live.positionIdentifier" in body
    assert "positionState.symbol!=live.symbol" in body
    assert "positionState.magic!=live.magic" in body
    assert "positionState.state.dir!=live.direction" in body
    assert "positionState.ticket!=live.ticket || positionState.state.ticket!=live.ticket" in body
    assert "Upsert(live.positionIdentifier,live.ticket" in body
    assert "g_posState.ticket=live.ticket" in body


def test_ticket_refresh_persistence_failure_keeps_execution_blocked():
    source = _source()
    body = _function_body(
        source,
        "bool AxReconcileVirtualExitTickets(",
        "// Reconstruct a completed position whose final close happened while the EA was offline.",
    )
    refresh = body.find("Upsert(live.positionIdentifier,live.ticket")
    persistence_check = body.find("!g_positionStateRegistry.IsPersisting()", refresh)
    fail_closed = body.find("g_hedgingLifecycleLock=true", persistence_check)
    return_false = body.find("return(false)", fail_closed)
    assert refresh >= 0
    assert persistence_check > refresh
    assert fail_closed > persistence_check
    assert return_false > fail_closed



def test_single_position_stop_modification_requires_broker_sl_tp_confirmation():
    source = _source()
    start = source.find("bool recorded=isBreakEvenMove")
    assert start >= 0
    body = source[source.rfind("if(wantModify)", 0, start):start]
    assert "PositionSelectByTicket(managed.ticket)" in body
    assert "POSITION_IDENTIFIER" in body
    assert "POSITION_MAGIC" in body
    assert "double confirmedStop=PositionGetDouble(POSITION_SL)" in body
    assert "double confirmedTakeProfit=PositionGetDouble(POSITION_TP)" in body
    assert "takeProfitPreserved" in body
    assert "confirmedStop>managed.stopLoss" in body
    assert "confirmedStop<managed.stopLoss" in body
    assert "RecordBreakEven(g_positionIdentifier,confirmedStop)" in body
    assert "RecordTrailingStop(g_positionIdentifier,confirmedStop)" in body


def test_single_position_unconfirmed_stop_keeps_action_lock_and_quarantines():
    source = _source()
    start = source.find("bool stopConfirmed=(managed.direction==AX_DIR_BUY)")
    assert start >= 0
    end = source.find("bool recorded=isBreakEvenMove", start)
    body = source[start:end]
    assert "if(!stopConfirmed || !takeProfitPreserved)" in body
    assert "g_hedgingLifecycleLock=true" in body
    assert "g_engineState=AX_ENGINE_PAUSED" in body
    assert "action lock retained" in body
    assert "ResolveAction" not in body


def test_initial_virtual_exit_state_uses_exact_confirmed_fill_ticket():
    source = _source()
    start = source.find("bool AxSaveVirtualExitState(const ulong expectedTicket")
    assert start >= 0
    end = source.find("// Recover interrupted stop-modification actions", start)
    body = source[start:end]
    assert "PositionSelectByTicket(expectedTicket)" in body
    assert "POSITION_TICKET)!=expectedTicket" in body
    assert "POSITION_SYMBOL)!=_Symbol" in body
    assert "POSITION_MAGIC)!=InpMagicNumber" in body
    assert "!isNewFill || !stopOnLossSide" in body
    assert "AxSaveVirtualExitState(newTicket,true)" in source


def test_initial_position_protection_rejects_missing_or_wrong_side_stop():
    source = _source()
    start = source.find("bool AxSaveVirtualExitState(const ulong expectedTicket")
    end = source.find("// Recover interrupted stop-modification actions", start)
    body = source[start:end]
    assert "brokerSl<=0.0" in body
    assert "dir==AX_DIR_BUY" in body
    assert "dir==AX_DIR_SELL" in body
    assert "riskDistance<=tickSize*0.5" in body


def _execution_source() -> str:
    path = ROOT / "MQL5" / "Include" / "AutopsyX" / "ExecutionEngine.mqh"
    assert path.is_file(), f"Execution engine source not found: {path}"
    return path.read_text(encoding="utf-8")


def test_post_fill_protection_repair_verifies_exact_position_and_broker_levels():
    source = _execution_source()
    body = _function_body(
        source,
        "bool              EnsurePostFillProtection(",
        "//--- confirm a fresh entry from its exact broker order",
    )
    assert "PositionSelectByTicket(positionTicket)" in body
    assert "POSITION_IDENTIFIER" in body
    assert "POSITION_MAGIC" in body
    assert "m_trade.PositionModify(positionTicket,repairSl,repairTp)" in body
    assert "repairRetcode==TRADE_RETCODE_DONE" in body
    assert "MathAbs(verifiedSl-repairSl)<=tolerance" in body
    assert "MathAbs(verifiedTp-repairTp)<=tolerance" in body


def test_failed_protection_repair_closes_only_exact_ticket_and_verifies_flat():
    source = _execution_source()
    body = _function_body(
        source,
        "bool              EnsurePostFillProtection(",
        "//--- confirm a fresh entry from its exact broker order",
    )
    assert "m_trade.PositionClose(positionTicket)" in body
    assert "DEAL_ORDER)==closeOrder" in body
    assert "DEAL_POSITION_ID)==positionId" in body
    assert "DEAL_ENTRY_OUT" in body
    assert "PositionSelectByTicket(positionTicket)" in body
    assert "bool positionFlat=!PositionSelectByTicket(positionTicket)" in body
    assert "closedVolume+volumeTolerance>=volumeBeforeClose" in body
    assert "outcomeUncertain=true" in body


def test_market_entry_cannot_succeed_before_post_fill_protection_is_verified():
    source = _execution_source()
    body = _function_body(
        source,
        "bool              OpenMarket(",
        "//--- flip = close, confirm flat, then open opposite direction ---",
    )
    assert "ConfirmMarketOrder(" in body
    assert "EnsurePostFillProtection(symbol,dir,ticketOut,alignedSl,alignedTp" in body
    assert "if(!EnsurePostFillProtection" in body
    assert "return(true); // confirmed fill and broker-retained protection" in body


def test_netting_pyramid_add_requires_existing_protection_and_exact_campaign_identity():
    source = _execution_source()
    body = _function_body(
        source,
        "bool              AddToNettingPosition(",
        "//--- close one exact broker position",
    )
    assert "beforeTicket!=expectedTicket" in body
    assert "beforeId!=expectedPositionId" in body
    assert "beforeMagic!=expectedMagic" in body
    assert "beforeSl<=0.0" in body
    assert "PrepareProtectionPrices(symbol,dir,beforeSl,beforeTp,false,0.0,0.0,errorReason)" in body


def test_netting_pyramid_fill_reconciles_deals_volume_identity_and_retained_protection():
    source = _execution_source()
    body = _function_body(
        source,
        "bool              AddToNettingPosition(",
        "//--- close one exact broker position",
    )
    assert "DEAL_ORDER)!=orderTicketOut" in body
    assert "DEAL_POSITION_ID)!=beforeId" in body
    assert "dealVolume+=volume" in body
    assert "MathAbs(volumeIncrease-dealVolume)<=tolerance" in body
    assert "afterTicket==0 || afterId!=beforeId || afterMagic!=expectedMagic" in body
    assert "EnsurePostFillProtection(symbol,dir,afterTicket,beforeSl,beforeTp" in body
    assert "positionTicketOut=afterTicket" in body
    assert "actualAddLotsOut=dealVolume" in body


def test_pending_pyramid_add_reconciles_exact_live_position_and_durable_history():
    source = _source()
    body = _function_body(
        source,
        "bool AxReconcilePyramidCampaignTickets(",
        "void AxInitPositionState(",
    )
    pending = body.find("if(g_pyramidReconcilePending)")
    exact_ticket = body.find("PositionSelectByTicket(live.ticket)", pending)
    identity = body.find("POSITION_IDENTIFIER", exact_ticket)
    protection = body.find("bool brokerProtected=", identity)
    history = body.find("g_pyramidCampaignRegistry.ReconcileLivePosition(live.ticket,reconciled)", protection)
    durable_clear = body.find("g_pyramidReconcilePending=false", history)
    assert pending >= 0
    assert exact_ticket > pending
    assert identity > exact_ticket
    assert protection > identity
    assert history > protection
    assert "if(!reconciled)" in body[history:durable_clear]
    assert "g_pyramidReady=false" in body[history:durable_clear]
    assert durable_clear > history
    assert "liveCount>0" in body[durable_clear:]


def test_uncertain_pyramid_add_stays_blocked_until_history_reconciliation():
    source = _source()
    caller = _function_body(
        source,
        "bool AxAttemptPyramidNettingAdd(",
        "//--- self-tuning:",
    )
    assert "if(outcomeUncertain)" in caller
    assert "g_pyramidReconcilePending=true" in caller
    assert "no retry permitted" in caller
    assert "g_pyramidReady=false" in caller
    reconciliation = _function_body(
        source,
        "bool AxReconcilePyramidCampaignTickets(",
        "void AxInitPositionState(",
    )
    assert "if(g_pyramidReconcilePending)" in reconciliation
    assert "ReconcileLivePosition(live.ticket,reconciled)" in reconciliation
    assert "g_pyramidReconcilePending=false" in reconciliation


def test_closed_uncertain_pyramid_add_resolves_only_after_flat_snapshot_and_durable_cleanup():
    source = _source()
    body = _function_body(
        source,
        "bool AxReconcilePyramidCampaignTickets(",
        "void AxInitPositionState(",
    )
    flat_guard = body.find("bool resolveClosedPending=(g_pyramidReconcilePending && liveCount==0)")
    cleanup = body.find("if(removeStaleRecords || resolveClosedPending)", flat_guard)
    empty_registry = body.find("g_pyramidCampaignRegistry.Count()==0", cleanup)
    durable = body.find("g_pyramidCampaignRegistry.IsPersisting()", empty_registry)
    clear_pending = body.find("g_pyramidReconcilePending=false", empty_registry)
    quarantine = body.find("g_pyramidReady=false", durable)
    assert flat_guard >= 0
    assert cleanup > flat_guard
    assert empty_registry > cleanup
    assert durable > empty_registry
    assert clear_pending > durable
    assert quarantine > durable
    assert "complete flat broker snapshot" in body
    assert "Account-risk reconciliation remains independently required" in body
