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
README = ROOT / "MQL5/README.md"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"PASS: {message}")

for path in (EA, RISK, EXEC, README):
    require(path.is_file(), f"required source exists: {path.relative_to(ROOT)}")

ea = EA.read_text(encoding="utf-8")
risk = RISK.read_text(encoding="utf-8")
execution = EXEC.read_text(encoding="utf-8")
readme = README.read_text(encoding="utf-8")

require("#property strict" in ea, "MQL5 strict mode is enabled")
require(bool(re.search(r"InpExecutionMode\s*=\s*AX_EXEC_ANALYSIS_ONLY", ea)),
        "execution defaults to ANALYSIS_ONLY")
require("ACCOUNT_MARGIN_MODE_RETAIL_HEDGING" in ea and "return(INIT_FAILED)" in ea,
        "unsupported hedging accounts fail initialization")
require(
        ("bool AxHasForeignPositionOnSymbol(string &reasonOut)" in ea
         and "if(AxHasForeignPositionOnSymbol(gateReason))" in ea)
        or ("bool foreignPositionOnSymbol=false;" in ea
            and "if(foreignPositionOnSymbol)" in ea
            and "AxCountRealPositions(accountPositions,symbolExposureLots,realPositionsForSymbol," in ea),
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
require("OrderCalcProfit(orderType,_Symbol,lots,intendedPrice,slPrice,projectedProfitAtStop)" in ea
        and "projectedLoss>riskBudget+0.01" in ea,
        "broker-account-currency loss calculation rejects sizes above configured trade-risk budget")
require("bool finalAccountExposureOk=(accountExposureLots+lots<=InpMaxExposureLots+0.0000001)" in ea
        and "!finalExposureOk || !finalAccountExposureOk" in ea,
        "final normalized volume cannot breach account-wide gross-lot cap")
require("m_riskPercent               = AxClampD(riskPercent,0.05,2.0)" in risk,
        "risk engine hard-clamps risk per trade to 2 percent")
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

print("Static safety audit passed. This is not an MQL5 compile or runtime test.")
