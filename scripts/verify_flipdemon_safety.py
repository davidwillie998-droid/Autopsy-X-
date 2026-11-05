#!/usr/bin/env python3
"""Static guardrails for AUTOPSY X FLIPDEMON EXTREME.

These checks catch regressions in critical source-level safety invariants. They do NOT
compile MQL5, emulate broker behavior, or replace MetaEditor and MT5 Strategy Tester.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"
RISK = ROOT / "MQL5/Include/AutopsyX/RiskEngine.mqh"
EXEC = ROOT / "MQL5/Include/AutopsyX/ExecutionEngine.mqh"
RECOVERY = ROOT / "MQL5/Include/AutopsyX/RestartRecovery.mqh"
DISTRIBUTED = ROOT / "MQL5/Include/AutopsyX/DistributedRiskCoordinator.mqh"
REGIME = ROOT / "MQL5/Include/AutopsyX/Regime.mqh"
README = ROOT / "MQL5/README.md"
AUTOPSY = ROOT / "MQL5/Include/AutopsyX/TradeAutopsy.mqh"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")

for path in (EA, RISK, EXEC, RECOVERY, DISTRIBUTED, REGIME, README):
    require(path.is_file(), f"required source exists: {path.relative_to(ROOT)}")

ea = EA.read_text(encoding="utf-8")
risk = RISK.read_text(encoding="utf-8")
execution = EXEC.read_text(encoding="utf-8")
recovery = RECOVERY.read_text(encoding="utf-8")
distributed = DISTRIBUTED.read_text(encoding="utf-8")
regime = REGIME.read_text(encoding="utf-8")
readme = README.read_text(encoding="utf-8")

require("#property strict" in ea, "MQL5 strict mode is enabled")
require("CopyBuffer(m_atrHandle,0,1,need,atrBuf)" in regime
        and "int need = AX_REGIME_ATR_LOOKBACK+1" in regime,
        "regime ATR uses the latest completed bar and a separate prior-bar reference window")
require("CopyClose(m_symbol,m_tf,1,AX_REGIME_TREND_BARS,closes)" in regime,
        "regime trend regression uses completed closes rather than the forming bar")
require("CopyHigh(m_symbol,m_tf,1,n,high)" in regime
        and "CopyLow(m_symbol,m_tf,1,n,low)" in regime
        and "CopyClose(m_symbol,m_tf,1,n,close)" in regime,
        "breakout detection compares the latest completed OHLC bar with prior completed bars")
require("DetectBreakout(bool &dataAvailable)" in regime
        and "if(!breakoutDataAvailable)" in regime
        and "ResetUnavailable();" in regime,
        "incomplete or invalid regime history fails closed instead of reusing stale readings")
require("bool AxLogBrokerCompatibility(void)" in ea and "if(!AxLogBrokerCompatibility())" in ea,
        "EA inspects connected broker/symbol capabilities before module initialization")
require("ACCOUNT_COMPANY" in ea and "ACCOUNT_SERVER" in ea and "ACCOUNT_CURRENCY" in ea
        and "ACCOUNT_LEVERAGE" in ea and "TERMINAL_BUILD" in ea,
        "broker identity, account currency, leverage and terminal build are logged at runtime")
require("SYMBOL_TRADE_TICK_SIZE" in ea and "SYMBOL_TRADE_TICK_VALUE_PROFIT" in ea
        and "SYMBOL_TRADE_TICK_VALUE_LOSS" in ea and "SYMBOL_TRADE_CONTRACT_SIZE" in ea,
        "symbol tick economics and contract size are logged from live broker metadata")
require("SYMBOL_VOLUME_MIN" in ea and "SYMBOL_VOLUME_MAX" in ea and "SYMBOL_VOLUME_STEP" in ea
        and "SYMBOL_TRADE_STOPS_LEVEL" in ea and "SYMBOL_TRADE_FREEZE_LEVEL" in ea
        and "SYMBOL_TRADE_EXEMODE" in ea and "SYMBOL_FILLING_MODE" in ea,
        "broker volume, stop/freeze, execution and filling constraints are logged")
require("critical symbol metadata is invalid" in ea and "trade-disabled by the broker" in ea,
        "invalid or disabled broker symbols fail closed instead of guessing specifications")
require("broker-name allowlist" in ea and "broker names" in ea,
        "broker compatibility is metadata-driven rather than restricted to named providers")
require("OrderCalcMargin(marginOrderType,_Symbol,lots,marginPrice,requiredMargin)" in ea,
        "final order size receives broker-aware OrderCalcMargin preflight")
require("requiredMargin>freeMargin" in ea and "entry blocked" in ea,
        "entry is blocked when estimated required margin exceeds available free margin")
require("FLIPDEMON MARGIN OK" in ea and "FLIPDEMON MARGIN BLOCK" in ea,
        "margin preflight outcome is auditable in the terminal Journal")
require(bool(re.search(r"InpExecutionMode\s*=\s*AX_EXEC_ANALYSIS_ONLY", ea)),
        "execution defaults to ANALYSIS_ONLY")
require("ACCOUNT_MARGIN_MODE_RETAIL_HEDGING" in ea and "return(INIT_FAILED)" in ea,
        "unsupported hedging accounts fail initialization")
require("bool AxHasForeignPositionOnSymbol(string &reasonOut)" in ea
        and "if(AxHasForeignPositionOnSymbol(gateReason))" in ea,
        "entries refuse to trade against a foreign position on the same netting symbol")
require("void AxCountAccountExposure(int &positionsOut,double &grossLotsOut)" in ea,
        "account-wide open positions and gross lots are measured")
require("PreTradeAllowed(accountOpenPositions,accountExposureLots" in ea
        and not re.search(r"PreTradeAllowed\(\s*0\s*,\s*0\.0", ea),
        "account-wide counts reach the hard pre-trade risk gate")
require(bool(re.search(r"remainingExposureLots\s*=\s*InpMaxExposureLots\s*-\s*accountExposureLots", ea)),
        "new order size is capped to remaining account-wide gross-lot allowance")
require("remainingExposureLots<g_md.VolumeMin()" in ea and "lots=0.0" in ea,
        "under-minimum remaining exposure fails closed")
require("projectedRiskPct > g_risk.RiskPercent()+0.0001" in ea,
        "broker minimum volume cannot silently exceed configured trade-risk budget")
require("m_riskPercent               = AxClampD(riskPercent,0.05,2.0)" in risk,
        "risk engine hard-clamps risk per trade to 2 percent")

market_data_path = ROOT / "MQL5/Include/AutopsyX/MarketData.mqh"
require(market_data_path.is_file(), "market data volume normalization source exists")
market_data = market_data_path.read_text(encoding="utf-8")
normalize_start = market_data.index("double            NormalizeVolume(")
normalize_end = market_data.index("double            NormalizePrice(", normalize_start)
normalize_volume = market_data[normalize_start:normalize_end]
require("if(rawLots+1e-12<m_volMin) return(0.0);" in normalize_volume,
        "risk-sized volume below broker minimum is rejected, never rounded up")
require("m_volMax<m_volMin || m_volStep<=0.0" in normalize_volume
        and "if(vol+1e-12<m_volMin || vol>m_volMax+1e-12) return(0.0);" in normalize_volume,
        "invalid broker volume metadata and out-of-range normalized lots fail closed")
require("DailyLossLimitBreached()" in risk and "WeeklyLossLimitBreached()" in risk,
        "daily and weekly loss locks are checked in the risk engine")
require("ConfirmPosition(symbol,dir,lots,ticketOut,fillPriceOut,actualLotsOut)" in execution,
        "market entries require broker position confirmation")
require("retcode!=TRADE_RETCODE_DONE" in execution,
        "stop modifications require an accepted server retcode")
require("g_posState.modifyFailCount>=InpMaxModifyFailures" in ea
        and "AxCloseAndRecord(AX_EXIT_EXECUTION_QUALITY)" in ea,
        "repeated stop-management failures trigger a defensive exit")
require("not a martingale" in readme.lower() and "never averages down" in readme.lower(),
        "documentation explicitly prohibits martingale and averaging down")

require("if(FileIsExist(m_fileName))" in recovery
        and "registry exists but cannot be read" in recovery,
        "restart recovery refuses to overwrite an existing unreadable registry")
require("malformed registry row; refusing to rewrite" in recovery
        and "invalid registry record; refusing to rewrite" in recovery,
        "restart recovery fails closed on malformed or invalid records")

require('string tempName=m_fileName+".tmp";' in recovery
        and "FileMove(tempName,0,m_fileName,FILE_REWRITE)" in recovery,
        "registry is written to a staged file before replacing the active registry")
require("previous registry retained" in recovery
        and "could not replace registry" in recovery,
        "failed staged writes/replacement report failure without claiming persistence")
require("written!=expected" in recovery
        and "short registry write" in recovery,
        "short writes are detected before the staged registry can replace the active file")
require("SAxOpenSetupRecord snapshot[AX_RECOVERY_MAX_ENTRIES];" in recovery
        and "original registry restored in memory" in recovery
        and "staleRemovedOut=0;" in recovery,
        "failed stale-record cleanup restores the prior in-memory registry snapshot")

require("metadata does not match broker state" in recovery
        and "liveMagic==magic" in recovery
        and "m_records[i].dir==liveDir" in recovery,
        "recovery validates saved ticket identity against live symbol, magic and direction")
require("A fresh successful reconciliation is required to clear that safety latch." in ea
        and "else if(g_recoveryInitialized)" not in ea,
        "trade-exit callbacks cannot accidentally clear a startup recovery block")
require("registry exceeds capacity" in recovery
        and "duplicate ticket" in recovery,
        "restart recovery rejects overflow and duplicate position tickets")
require("bool               RecordOpenSetup(" in recovery
        and "if(RewriteFile()) return(true);" in recovery
        and "m_count=previousCount;" in recovery,
        "failed open-record persistence is reported and in-memory state is rolled back")
require("bool               RemoveOpenSetup(" in recovery
        and "could not persist removal" in recovery,
        "failed record removal is reported to the caller")

require("#include <AutopsyX/RestartRecovery.mqh>" in ea
        and "CRestartRecovery       g_restartRecovery;" in ea,
        "restart-recovery component is included and instantiated by the EA")
require("g_restartRecovery.Init(" in ea
        and "g_restartRecovery.Reconcile(" in ea
        and "g_restartRecovery.IsPersisting()" in ea,
        "EA initializes the recovery registry and reconciles it against broker positions")
require("if(!g_recoveryReady)" in ea
        and "new entry blocked" in ea,
        "unverified recovery state hard-blocks new entries")
require("g_restartRecovery.RecordOpenSetup(" in ea
        and "g_recoveryReady = false;" in ea,
        "confirmed fills are persisted and persistence failure blocks subsequent entries")
require("g_restartRecovery.RemoveOpenSetup(g_posState.ticket)" in ea
        and "registry removal was not persisted" in ea,
        "closed positions clear recovery records and fail closed when removal cannot be persisted")
require("Existing positions will still be managed; new entries are blocked." in ea,
        "recovery failure preserves existing-position management while blocking new entries")

partial_start = ea.index("void AxExecutePartialClose(")
partial_end = ea.index("void AxInitPositionState(", partial_start)
partial = ea[partial_start:partial_end]
require(partial_start >= 0 and partial_end > partial_start,
        "partial-close execution and retry functions are present")
require("partial close confirmed but deal history is not ready; accounting deferred." in partial
        and "AxRecordPartialClose(volumeToClose,pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket)" not in partial,
        "partial-close history misses defer accounting instead of recording fabricated zero-PnL results")
require("if(g_partialClosePending)" in partial
        and "refusing another scale-out" in partial,
        "a pending partial close blocks duplicate scale-out requests")
require("g_posState.lots-PositionGetDouble(POSITION_VOLUME)" in partial,
        "partial-close accounting reconciles against actual broker remaining volume")
require("AxRetryPendingPartialClose();" in ea,
        "pending partial-close accounting is retried from the tick lifecycle")

require("HistorySelectByPosition((long)positionId)" in ea
        and "HistorySelectByPosition((long)posTicket)" not in ea,
        "exit history selection uses POSITION_IDENTIFIER rather than assuming position ticket identity")
require("g_positionIdentifier          = (ulong)PositionGetInteger(POSITION_IDENTIFIER);" in ea
        and "g_positionIdentifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);" in ea,
        "position identifier is captured on restart reconciliation and fresh position initialization")
autopsy = AUTOPSY.read_text(encoding="utf-8")
require("LastAccountedDealTicket(const ulong positionIdentifier)" in autopsy
        and "TradeAutopsy_v3.csv" in autopsy
        and "PositionIdentifier" in autopsy,
        "trade journal restores DealIdOut boundary per stable position identifier")
require("rec.dealIdOut=lastDealTicket;" in ea and "rec.positionIdentifier = g_positionIdentifier;" in ea and "rLastTicket>journalBoundary" in ea and "g_autopsy.LastAccountedDealTicket(g_positionIdentifier)" in ea
        and "NEW ENTRIES BLOCKED pending accounting reconciliation" in ea,
        "restart compares broker exit history with journal boundary and blocks entries on an accounting gap")

require("struct SAxRiskSizingDecision" in risk
        and "rejectionReason" in risk and "projectedRiskPercent" in risk,
        "risk engine exposes an auditable sizing decision and explicit rejection reason")
require("OrderCalcProfit(orderType,_Symbol,1.0,entryPrice,stopPrice,oneLotProfit)" in risk
        and "OrderCalcProfit(orderType,_Symbol,lots,entryPrice,stopPrice,sizedProfit)" in risk,
        "one-lot and normalized-volume stop risk use broker-aware profit calculations")
require("CalculateLotSize(g_md,intendedPrice,slPrice,dir,sizingDecision)" in ea
        and "sizingDecision.rejectionReason" in ea,
        "EA logs the risk engine sizing decision at the entry evaluation point")
require("m_riskPercent               = AxClampD(riskPercent,0.05,2.0)" in risk,
        "decision-record integration retains the absolute per-entry risk clamp")


# Account-wide monetary risk calculator: this is a source guard, not an MQL5 compile.
ACCOUNT_RISK = ROOT / "MQL5/Include/AutopsyX/AccountRiskCalculator.mqh"
require(ACCOUNT_RISK.is_file(), "dedicated account-wide risk calculator exists")
account_risk = ACCOUNT_RISK.read_text(encoding="utf-8")
require("#define AX_ACCOUNT_RISK_HARD_CAP_PCT 2.0" in account_risk,
        "account-wide monetary risk has an immutable 2 percent hard ceiling")
require("PositionsTotal()" in account_risk and "PositionGetTicket(i)" in account_risk
        and "POSITION_SL" in account_risk and "POSITION_PRICE_OPEN" in account_risk,
        "all broker-confirmed open positions and protective stops are enumerated")
require("OrderCalcProfit(orderType,symbol,volume,entryPrice,stopPrice,result)" in account_risk,
        "existing exposure is valued with broker-aware OrderCalcProfit in account currency")
require("OrdersTotal()" in account_risk and "ORDER_VOLUME_CURRENT" in account_risk
        and "ORDER_SL" in account_risk,
        "active pending orders use remaining unfilled volume and their broker stop")
require("UNPROTECTED_POSITION" in account_risk and "UNPROTECTED_PENDING_ORDER" in account_risk
        and "exposureKnown=false" in account_risk,
        "missing protection is classified as unknown exposure and fails closed")
require("AMBIGUOUS_NETTING_DUPLICATE_SYMBOL" in account_risk
        and "ACCOUNT_MARGIN_MODE_RETAIL_HEDGING" in account_risk,
        "netting and hedging exposure reconciliation paths are distinguished")
require("PROPOSED_ORDER_EXCEEDS_ACCOUNT_WIDE_2_PERCENT_CAP" in account_risk
        and "PROPOSED_ORDER_EXCEEDS_PER_ENTRY_RISK_LIMIT" in account_risk,
        "proposed order must pass both aggregate and configured per-entry monetary limits")
require("RISK_AUDIT_PERSISTENCE_FAILED" in account_risk
        and "WriteAudit(decision)" in account_risk,
        "new entries fail closed when the auditable decision row cannot be persisted")
require("#include <AutopsyX/AccountRiskCalculator.mqh>" in ea
        and "CAccountRiskCalculator g_accountRisk;" in ea,
        "account risk calculator is included and instantiated by the EA")
require("g_accountRisk.Evaluate(_Symbol,dir,lots,slPrice,deviationPts,g_risk.RiskPercent()" in ea,
        "final broker exposure is re-scanned immediately before market order submission with execution deviation")
require("maxAdverseSlippagePoints*point" in account_risk
        and "tick.ask+slippageBuffer" in account_risk
        and "tick.bid-slippageBuffer" in account_risk,
        "proposed stop risk reserves adverse execution deviation for both directions")
require("adverseSlippagePoints" in account_risk and "worstCaseEntryPrice" in account_risk
        and "adverse_slippage_points" in account_risk and "worst_case_entry_price" in account_risk,
        "risk audit persists the slippage allowance and worst-case entry used for approval")

require("g_accountRisk.Scan(postFillRisk)" in ea
        and "postFillRisk.existingRiskMoney>postFillRisk.hardRiskBudgetMoney+0.01" in ea,
        "broker-confirmed post-fill exposure is rescanned and checked against the immutable account cap")
require("g_accountRiskIntegrityLock=true" in ea
        and "AxCloseAndRecord(AX_EXIT_EXECUTION_QUALITY)" in ea,
        "unknown or over-cap post-fill exposure locks new entries and triggers a defensive close attempt")
require("g_accountRiskIntegrityLock" in ea and "cleared after a clean broker exposure rescan" in ea,
        "post-fill risk lock clears only after a clean broker-confirmed rescan")

require("g_accountRiskReconciliationPending=true" in ea
        and "if(g_accountRiskReconciliationPending)" in ea,
        "every broker transaction dirties the account-wide exposure snapshot for tick-time reconciliation")
require("g_accountRisk.Scan(transactionRisk)" in ea
        and "transactionRisk.existingRiskMoney>transactionRisk.hardRiskBudgetMoney+0.01" in ea,
        "partial fills, pending-order changes and netting updates are reconciled from broker-confirmed account state")

require("PositionRisk(const ulong ticket" in account_risk
        and "PositionGetDouble(POSITION_VOLUME)" in account_risk
        and "PositionGetDouble(POSITION_PRICE_OPEN)" in account_risk
        and "PositionGetDouble(POSITION_SL)" in account_risk,
        "live position risk uses broker-confirmed remaining volume, entry price and current stop")
require("POSITION_STOP_CROSSED_OR_INVALID" in account_risk
        and "stop>=tick.bid" in account_risk and "stop<=tick.ask" in account_risk,
        "removed, crossed or invalid live stops make account exposure unknown and block new entries")
require("g_exec.ModifyStops(_Symbol,newSl,g_posState.initialTpPrice,modErr)" in ea
        and "g_accountRiskReconciliationPending=true" in ea,
        "stop modification requests trigger broker-state reconciliation rather than trusting requested stop values")
require("double actualClosed=g_posState.lots-PositionGetDouble(POSITION_VOLUME)" in ea,
        "partial-close accounting reads broker-confirmed remaining position volume")

require("class CAccountRiskCoordinator" in account_risk
        and "GlobalVariableTemp(m_lockName)" in account_risk
        and "GlobalVariableSetOnCondition(m_lockName,m_ownerToken,0.0)" in account_risk,
        "account mutex uses an atomic terminal-global-variable compare-and-set")
require("g_accountRiskCoordinator.TryAcquire()" in ea
        and ea.index("g_accountRiskCoordinator.TryAcquire()") < ea.index("g_accountRisk.Evaluate")
        and "g_accountRiskCoordinator.Release()" in ea,
        "account mutex is acquired before final approval and released on entry outcomes")
require("g_accountRisk.Scan(postFillRisk)" in ea
        and ea.index("g_accountRisk.Scan(postFillRisk)") < ea.index("g_accountRiskCoordinator.Release()", ea.index("g_accountRisk.Scan(postFillRisk)")),
        "account mutex remains held through broker-confirmed post-fill risk reconciliation")
require('#include <AutopsyX/DistributedRiskCoordinator.mqh>' in ea
        and "CDistributedRiskCoordinator g_distributedRiskCoordinator;" in ea,
        "EA includes and instantiates the distributed coordinator adapter")
require("WebRequest(" in distributed and "x-risk-coordinator-key:" in distributed
        and 'StringFind(m_baseUrl,"https://")!=0' in distributed,
        "distributed adapter uses authenticated HTTPS WebRequest and rejects non-HTTPS endpoints")
require("TERMINAL_DATA_PATH" in distributed and "BuildInstanceId" in distributed
        and "g_distributedRiskCoordinator.InstanceId()" in ea,
        "reservation ownership and idempotency are scoped to a terminal-specific instance identity")
require("InpExecutionMode==AX_EXEC_LIVE" in ea
        and "g_distributedRiskCoordinator.Init" in ea
        and "startupRisk" in ea and "startupWithinCap" in ea,
        "LIVE mode requires coordinator credentials and a clean startup broker reconciliation")
require(ea.index("g_accountRiskCoordinator.TryAcquire()") < ea.index("g_accountRisk.Evaluate")
        and ea.index("g_accountRisk.Evaluate") < ea.index("g_distributedRiskCoordinator.Reserve")
        and ea.index("g_distributedRiskCoordinator.Reserve") < ea.index("g_exec.OpenMarket"),
        "LIVE order path acquires local mutex, passes local risk approval, reserves centrally, then submits")
require("g_distributedRiskCoordinator.Release(distributedReservationId" in ea
        and "failedOrderSnapshot" in ea,
        "failed or ambiguous order outcomes release reservations only after a fresh broker exposure scan")
require("g_distributedRiskCoordinator.Settle(distributedReservationId" in ea
        and ea.index("g_accountRisk.Scan(postFillRisk)") < ea.index("g_distributedRiskCoordinator.Settle")
        and ea.index("g_distributedRiskCoordinator.Settle") < ea.index("g_accountRiskCoordinator.Release()",ea.index("g_distributedRiskCoordinator.Settle")),
        "successful fills settle central reservations from broker-confirmed post-fill exposure while mutex remains held")
require("g_distributedRiskCoordinator.Reconcile(transactionRisk" in ea
        and "g_accountRiskReconciliationPending=false" in ea,
        "manual and external broker transactions are reconciled to the central ledger before clearing the dirty flag")
require("InpRiskCoordinatorKey" in ea and "PrintFormat" in ea
        and "InpRiskCoordinatorKey" not in ea[ea.find("void OnTick"):],
        "coordinator secret is not written into tick-path logs")
require("InpExecutionMode = AX_EXEC_ANALYSIS_ONLY" in ea,
        "distributed coordinator wiring preserves ANALYSIS_ONLY as the default execution mode")
require("g_accountRiskReconciliationPending=false" in ea
        and "exposure unknown; entries locked" in ea,
        "unknown transaction snapshots retain the retry flag and fail closed")

print("Static safety audit passed. This is not an MQL5 compile or runtime test.")


# Stable restart identity guardrails: broker position identifiers survive ticket changes.
require("AX_RECOVERY_FIELD_COUNT 6" in recovery,
        "restart registry schema includes stable position identity")
require("positionIdentifier" in recovery and "FindByPositionIdentifier" in recovery,
        "recovery matching is keyed by stable POSITION_IDENTIFIER rather than ticket alone")
require("POSITION_IDENTIFIER" in recovery and "OpenSetups_v2.csv" in recovery,
        "versioned registry avoids misreading the previous ticket-only schema")
require("RecordOpenSetup(newTicket,g_positionIdentifier,recoverySetupId" in ea,
        "confirmed fills persist the broker position identifier with the setup mapping")
