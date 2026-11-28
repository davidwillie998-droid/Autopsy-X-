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

