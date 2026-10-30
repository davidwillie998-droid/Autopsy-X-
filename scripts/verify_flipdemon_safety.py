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
README = ROOT / "MQL5/README.md"
AUTOPSY = ROOT / "MQL5/Include/AutopsyX/TradeAutopsy.mqh"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")

for path in (EA, RISK, EXEC, RECOVERY, README):
    require(path.is_file(), f"required source exists: {path.relative_to(ROOT)}")

ea = EA.read_text(encoding="utf-8")
risk = RISK.read_text(encoding="utf-8")
execution = EXEC.read_text(encoding="utf-8")
recovery = RECOVERY.read_text(encoding="utf-8")
readme = README.read_text(encoding="utf-8")

require("#property strict" in ea, "MQL5 strict mode is enabled")
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
