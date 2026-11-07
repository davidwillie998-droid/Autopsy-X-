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
VIRTUAL_EXIT = ROOT / "MQL5/Include/AutopsyX/VirtualExitRegistry.mqh"
PYRAMID = ROOT / "MQL5/Include/AutopsyX/PyramidEngine.mqh"
PYRAMID_CAMPAIGN = ROOT / "MQL5/Include/AutopsyX/PyramidCampaignRegistry.mqh"
DISTRIBUTED = ROOT / "MQL5/Include/AutopsyX/DistributedRiskCoordinator.mqh"
REGIME = ROOT / "MQL5/Include/AutopsyX/Regime.mqh"
README = ROOT / "MQL5/README.md"
AUTOPSY = ROOT / "MQL5/Include/AutopsyX/TradeAutopsy.mqh"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")

for path in (EA, RISK, EXEC, RECOVERY, VIRTUAL_EXIT, PYRAMID, PYRAMID_CAMPAIGN, DISTRIBUTED, REGIME, README):
    require(path.is_file(), f"required source exists: {path.relative_to(ROOT)}")

ea = EA.read_text(encoding="utf-8")
risk = RISK.read_text(encoding="utf-8")
execution = EXEC.read_text(encoding="utf-8")
recovery = RECOVERY.read_text(encoding="utf-8")
virtual_exit = VIRTUAL_EXIT.read_text(encoding="utf-8")
pyramid = PYRAMID.read_text(encoding="utf-8")
pyramid_campaign = PYRAMID_CAMPAIGN.read_text(encoding="utf-8")
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
require("critical symbol metadata is invalid" in ea and "SYMBOL_TRADE_MODE_DISABLED" in ea
        and "SYMBOL_TRADE_MODE_CLOSEONLY" in ea and "does not permit new positions" in ea,
        "invalid, disabled or close-only broker symbols fail closed instead of guessing specifications")
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
require("ModifyStopsByTicket(" in ea
        and "action lock retained, no retry" in ea
        and "g_hedgingLifecycleLock=true;" in ea
        and "g_engineState=AX_ENGINE_PAUSED;" in ea,
        "uncertain stop modifications retain their durable action lock and quarantine instead of retrying")
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
        and "LastAccountedDealTicketInFile(m_legacyFileName,positionIdentifier)" in autopsy
        and "TradeAutopsy_v3.csv" in autopsy
        and "TradeAutopsy_v4.csv" in autopsy
        and "WriteHeaderIfNew(void)" in autopsy
        and "ParseCsvField(const string line" in autopsy
        and "LoadRiskHistory" in autopsy
        and "RiskHistoryCount" in autopsy
        and "PositionIdentifier" in autopsy,
        "versioned trade journal restores deal boundaries and persistent risk history across upgrades")
require("ReadRiskHistoryFile(m_legacyFileName,true)" in autopsy
        and "ReadRiskHistoryFile(m_fileName,false)" in autopsy
        and 'fields[25]=="NA"' in autopsy
        and '(rec.rMultiple==EMPTY_VALUE ? "NA" : DoubleToString(rec.rMultiple,3))' in autopsy
        and "legacyV3 && rMultiple==0.0" in autopsy,
        "journal migration preserves known v3 outcomes and explicitly encodes unavailable v4 R values")
require("rMultiple!=EMPTY_VALUE" in (ROOT / "MQL5/Include/AutopsyX/Statistics.mqh").read_text(encoding="utf-8")
        and "autopsy.RiskHistoryCount()" in (ROOT / "MQL5/Include/AutopsyX/Statistics.mqh").read_text(encoding="utf-8"),
        "loss streak and Expected Shortfall are rebuilt from persisted, provenance-filtered records")
require("rec.dealIdOut=lastDealTicket;" in ea and "rec.positionIdentifier = g_positionIdentifier;" in ea and "rLastTicket>journalBoundary" in ea and "g_autopsy.LastAccountedDealTicket(g_positionIdentifier)" in ea
        and "NEW ENTRIES BLOCKED pending accounting reconciliation" in ea,
        "restart compares broker exit history with journal boundary and blocks entries on an accounting gap")

require("LastAccountedRecord(const ulong positionIdentifier" in autopsy
        and "ParseCsvField(line,28)" in autopsy
        and "ParseCsvField(line,9)" in autopsy,
        "journal exposes the last durable row's partial/full status for restart recovery")
require("DoubleToString(rec.lots,8)" in autopsy,
        "trade journal preserves broker micro-lot precision instead of rounding lots to two decimals")
partial_recovery_start = ea.index("bool AxRecoverLockedPartialCloseActions(void)")
partial_recovery_end = ea.index("bool AxReconcilePyramidCampaignTickets", partial_recovery_start)
partial_recovery = ea[partial_recovery_start:partial_recovery_end]
require("g_autopsy.LastAccountedRecord(saved.positionIdentifier" in partial_recovery
        and "saved.partialLastDealTicket>journalHighWater" in partial_recovery,
        "partial-close restart recovery reconciles registry and durable journal deal cursors")
require("journalExitVolume+=volume" in partial_recovery
        and "unaccountedExitVolume+=volume" in partial_recovery
        and "AxRecoverFullyClosedPosition(saved,unaccountedExitVolume" in partial_recovery,
        "full-close recovery excludes exit deals already accounted by the partial journal")
require("journalAdvanced && !journalRowPartial" in partial_recovery
        and "AxRecoverFullyClosedPosition(saved,historyExitVolume" in partial_recovery,
        "already-journalled full closes perform cleanup without writing a duplicate trade")
require("ResolveAction(saved.positionIdentifier,3)" in partial_recovery
        and "AxFetchCloseFinancials(live.ticket,journalCursor" in partial_recovery,
        "partial action lock clears only after exact broker history and journal reconciliation")
require("ClosePartial(" not in partial_recovery
        and "ClosePosition(" not in partial_recovery,
        "restart recovery never resends a broker close request")

require('rec.entryReason="RESTART_RECOVERED | ENTRY_THESIS_UNAVAILABLE"' in ea
        and "rec.exitReason=AX_EXIT_NONE;" in ea
        and "Record NONE rather than falsely labelling" in ea,
        "recovered trade rows mark unavailable entry thesis and exit reason instead of inventing classifications")

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
require("g_exec.ModifyStopsByTicket(_Symbol,managed.ticket,managed.positionIdentifier" in ea
        and "g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)" in ea
        and "AxReconcileVirtualExitTickets(false)" in ea,
        "stop modifications target the stable broker position and require a fresh post-modification snapshot")
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


# Persistent virtual-exit state is deliberately a preparation phase. Broker emergency
# stops remain active; no virtual exit is allowed to replace broker protection yet.
require('#include <AutopsyX/VirtualExitRegistry.mqh>' in ea
        and "CVirtualExitRegistry   g_virtualExitRegistry;" in ea,
        "virtual-exit registry is included and instantiated by the EA")
require("AX_VIRTUAL_EXIT_FIELD_COUNT 21" in virtual_exit
        and "AX_VIRTUAL_EXIT_LEGACY_FIELD_COUNT 12" in virtual_exit
        and "fieldCount!=20" in virtual_exit
        and "positionIdentifier" in virtual_exit
        and "FindIndex(record.positionIdentifier)" in virtual_exit,
        "virtual-exit persistence reads legacy 12/20-field rows and writes the 21-field identity record")
virtual_format = re.search(r'string line=StringFormat\("([^"]+)"', virtual_exit)
require(virtual_format is not None
        and len(re.findall(r"%I64u|%d|%s", virtual_format.group(1))) == 21
        and "Number(r.actionBaselineVolume)" in virtual_exit,
        "21-field virtual-exit serializer persists the pre-action broker volume baseline")
require("BeginPartialCloseAction" in virtual_exit
        and "record.actionBaselineVolume=baselineVolume" in virtual_exit
        and "record.actionBaselineVolume=0.0" in virtual_exit,
        "partial-close action baseline is durably captured and cleared only with its action lock")
require("FileMove(tempName,0,m_fileName,FILE_REWRITE)" in virtual_exit
        and "written!=expected" in virtual_exit
        and "m_persistOk=false" in virtual_exit,
        "virtual-exit persistence detects short writes and failed staged-file replacement")
require("bool AxSaveVirtualExitState(const bool allowEmergencyUpdate=false,const bool isNewFill=false)" in ea
        and "POSITION_IDENTIFIER" in ea
        and "POSITION_MAGIC" in ea,
        "EA state persistence binds the record to broker ticket, position identifier and magic")
require("!isNewFill || !stopOnLossSide" in ea
        and "original risk cannot be reconstructed safely" in ea,
        "untracked pre-existing positions cannot receive an invented original-risk denominator")
require("existing.initialSlPrice" in ea
        and "existing.originalRiskDistance" in ea
        and "g_posState.originalSlPrice=existing.initialSlPrice" in ea,
        "restart restores the original stop and original risk distance instead of substituting a trailed stop")
require("AxSaveVirtualExitState(false,true)" in ea
        and "RecordBreakEven(g_positionIdentifier,newSl)" in ea
        and "RecordTrailingStop(g_positionIdentifier,newSl)" in ea,
        "confirmed fills persist initial state and broker-confirmed break-even/trailing stops update the registry")
require("g_virtualExitRegistry.Remove(g_positionIdentifier)" in ea
        and "position closed but state removal failed" in ea,
        "virtual-exit state is removed only after the broker position has been finalized")
require("if(!g_virtualExitReady || !g_virtualExitRegistry.IsPersisting())" in ea
        and "if(!g_recoveryReady)" in ea,
        "unverified virtual-exit persistence blocks new entries without disabling existing-position management")
virtual_reconcile_start = ea.index("bool AxReconcileVirtualExitTickets(")
virtual_reconcile_end = ea.index("bool AxRecoverFullyClosedPosition(", virtual_reconcile_start)
virtual_reconcile = ea[virtual_reconcile_start:virtual_reconcile_end]
require("g_virtualExitRegistry.Init(" in ea
        and ea.index("g_virtualExitRegistry.Init(") < ea.index("AxReconcileExistingPosition();")
        and "AxReconcileVirtualExitTickets(true)" in ea
        and "g_hedgingPositionManager.IsComplete()" in virtual_reconcile
        and "if(removeStaleRecords)" in virtual_reconcile,
        "virtual-exit state loads before broker reconciliation and stale rows clear only after a complete broker snapshot")
require("virtual execution remains disabled in this phase" in ea
        and "g_exec.ModifyStopsByTicket(_Symbol,managed.ticket,managed.positionIdentifier" in ea
        and "managed.magic,newSl,managed.takeProfit" in ea,
        "virtual exits remain disabled while broker-side stops use exact-ticket modification")


# Pyramid calculation module: no order submission here. Campaign execution is a
# separate integration phase and must retain the account-wide risk coordinator.
require('#include <AutopsyX/PyramidEngine.mqh>' in ea
        and "CPyramidEngine         g_pyramidEngine;" in ea,
        "pyramid calculation engine is compiled as part of the existing FlipDemon EA")
require("enum ENUM_AX_PYRAMID_TRIGGER" in pyramid
        and "AX_PYRAMID_FIXED_GAP" in pyramid
        and "AX_PYRAMID_ATR_GAP" in pyramid
        and "AX_PYRAMID_CLOSED_BAR" in pyramid,
        "pyramid engine exposes fixed-gap, ATR and completed-bar tier triggers")
require("iMA(symbol,timeframe,period,0,method,PRICE_CLOSE)" in pyramid
        and "close2<=ma[1] && close1>ma[2] && slopeUp" in pyramid
        and "close2>=ma[1] && close1<ma[2] && slopeDown" in pyramid,
        "first-tier MA cross requires completed-bar price crossing and aligned MA slope")
require("SYMBOL:PIPS:MIN:MAX" in pyramid
        and "PipSize(symbol)" in pyramid
        and "priceUnits?1.0:PipSize(symbol)" in pyramid,
        "per-symbol gap presets are input-parsed with explicit pips versus price units")
require("MathPow(1.0-shrink,tier-1)" in pyramid
        and "ClampShrink(shrinkPercent)" in pyramid,
        "tier spacing can shrink by a bounded percentage without negative gaps")
require("CalculateTierVolume" in pyramid
        and "AX_PYRAMID_MULTIPLIER" in pyramid
        and "AX_PYRAMID_INCREMENT" in pyramid
        and "AX_PYRAMID_CUSTOM" in pyramid,
        "pyramid engine calculates multiplier, fixed-increment and custom tier volumes")
require("TierTriggerReached" in pyramid
        and "lastClosedBarClose>lastTierEntry" in pyramid
        and "lastClosedBarClose<lastTierEntry" in pyramid,
        "closed-bar continuation trigger compares against the last tier fill price")
require("CTrade" not in pyramid and "PositionOpen" not in pyramid
        and "Buy(" not in pyramid and "Sell(" not in pyramid,
        "pyramid calculation module cannot bypass FlipDemon execution and risk controls")

# Persistent pyramid campaign state is groundwork only. Broker deal history remains
# the source of truth for tier fills; this registry stores stable campaign checkpoints.
require('#include <AutopsyX/PyramidCampaignRegistry.mqh>' in ea
        and "CPyramidCampaignRegistry g_pyramidCampaignRegistry;" in ea,
        "persistent campaign registry is compiled into the EA but not yet activated")
require("AX_PYRAMID_CAMPAIGN_MAX_TIERS 10" in pyramid_campaign
        and "AX_PYRAMID_CAMPAIGN_FIELD_COUNT 17" in pyramid_campaign,
        "campaign persistence has a bounded ten-tier schema with an explicit versioned field count")
require("positionIdentifier" in pyramid_campaign
        and "FindIndex(const ulong positionIdentifier)" in pyramid_campaign
        and "ACCOUNT_LOGIN" in pyramid_campaign
        and "m_magic" in pyramid_campaign,
        "campaign records are scoped to account, magic and stable broker position identity")
require("lastTierDealTicket" in pyramid_campaign
        and "lastTierFillPrice" in pyramid_campaign
        and "lastTierFilledLots" in pyramid_campaign
        and "lastTriggerBarTime" in pyramid_campaign,
        "campaign checkpoints retain broker-confirmed fill and duplicate-trigger boundaries")
require("FileMove(tempName,0,m_fileName,FILE_REWRITE)" in pyramid_campaign
        and "written!=expected" in pyramid_campaign
        and "FileFlush(handle)" in pyramid_campaign,
        "campaign registry uses staged writes, flush verification and replacement")
require("refusing to overwrite it" in pyramid_campaign
        and "malformed or mismatched campaign registry row" in pyramid_campaign
        and "duplicate position identifier" in pyramid_campaign,
        "corrupt, mismatched or duplicate campaign state fails closed instead of being silently reset")
require("record.tierCount<previous.tierCount" in pyramid_campaign
        and "record.lastTierDealTicket<previous.lastTierDealTicket" in pyramid_campaign,
        "campaign updates reject tier-count or confirmed-deal sequence regression")
require("CTrade" not in pyramid_campaign
        and "PositionOpen" not in pyramid_campaign
        and "Buy(" not in pyramid_campaign
        and "Sell(" not in pyramid_campaign,
        "campaign registry cannot submit orders or bypass execution and risk gates")

# Stable restart identity guardrails: broker position identifiers survive ticket changes.
require("AX_RECOVERY_FIELD_COUNT 6" in recovery,
        "restart registry schema includes stable position identity")
require("positionIdentifier" in recovery and "FindByPositionIdentifier" in recovery,
        "recovery matching is keyed by stable POSITION_IDENTIFIER rather than ticket alone")
require("POSITION_IDENTIFIER" in recovery and "OpenSetups_v2.csv" in recovery,
        "versioned registry avoids misreading the previous ticket-only schema")
require("RecordOpenSetup(newTicket,g_positionIdentifier,recoverySetupId" in ea,
        "confirmed fills persist the broker position identifier with the setup mapping")


# Volume Profile node classification: source-level regression checks only.
VOLUME_PROFILE = ROOT / "MQL5/Include/AutopsyX/VolumeProfile.mqh"
require(VOLUME_PROFILE.is_file(), "volume profile source exists")
volume_profile = VOLUME_PROFILE.read_text(encoding="utf-8")
# Strip comments and quoted strings before checking delimiter balance.
vp_code = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', '',
                 volume_profile, flags=re.S)
depth = 0
for char in vp_code:
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        require(depth >= 0, "volume profile braces never close before opening")
require(depth == 0, "volume profile class and method braces are balanced")
require("MathAbs(m_binPrice[idx]-m_binPrice[order[pos-1]])<=m_binSize*1.5" in volume_profile
        and "MathAbs(m_binPrice[idx]-m_binPrice[order[pos+1]])<=m_binSize*1.5" in volume_profile,
        "HVN/LVN comparisons require genuinely adjacent occupied price bins")
require("bool localLow=(hasBelow && hasAbove" in volume_profile,
        "LVN classification requires occupied neighbors on both sides")
require("((hasBelow && vol>below) || (hasAbove && vol>above))" in volume_profile,
        "HVN classification requires a strict local maximum against at least one adjacent bin")
require("NearestHighVolumeNode" in volume_profile
        and "NearestLowVolumeNode" in volume_profile
        and "return(NearestNode(refPrice,true,nodePrice,distanceBins));" in volume_profile
        and "return(NearestNode(refPrice,false,nodePrice,distanceBins));" in volume_profile,
        "nearest HVN/LVN APIs share the validated node lookup path")

# Repository-wide MQL5 include and indicator-handle checks. These are source
# contracts only; MetaEditor remains the authority on compiler diagnostics.
MQL5_ROOT = ROOT / "MQL5"
mql_sources = list(MQL5_ROOT.rglob("*.mq5")) + list(MQL5_ROOT.rglob("*.mqh"))
source_text = {p.resolve(): p.read_text(encoding="utf-8") for p in mql_sources}
require(bool(mql_sources), "MQL5 source tree is present for repository-wide checks")

for source_path, source in source_text.items():
    relative = source_path.relative_to(ROOT)
    if source_path.suffix.lower() == ".mqh":
        guard = re.search(
            r"^\s*#ifndef\s+([A-Za-z_]\w*)\s*$[\s\S]*?"
            r"^\s*#define\s+\1\s*$",
            source, flags=re.M
        )
        require(guard is not None,
                f"include guard exists and matches: {relative}")

    for match in re.finditer(
            r'^\s*#include\s+([<"])([^>"]+)[>"]',
            source, flags=re.M):
        delimiter, include_name = match.groups()
        if delimiter == '"':
            target = (source_path.parent / include_name).resolve()
            require(target in source_text or target.is_file(),
                    f"quoted include resolves: {relative} -> {include_name}")
        elif include_name.startswith("AutopsyX/"):
            target = (MQL5_ROOT / "Include" / include_name).resolve()
            require(target in source_text or target.is_file(),
                    f"project angle include resolves: {relative} -> {include_name}")

    iMA_calls = len(re.findall(r"\biMA\s*\(", source))
    if iMA_calls:
        require(re.search(r"=\s*iMA\s*\(", source) is not None,
                f"iMA calls are assigned to indicator handles: {relative}")
        require("CopyBuffer(" in source,
                f"iMA handle is read through CopyBuffer: {relative}")
        require("IndicatorRelease(" in source,
                f"iMA handle has an IndicatorRelease lifecycle: {relative}")

print("Static safety audit passed. This is not an MQL5 compile or runtime test.")

