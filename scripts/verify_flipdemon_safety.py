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

print("Static safety audit passed. This is not an MQL5 compile or runtime test.")
