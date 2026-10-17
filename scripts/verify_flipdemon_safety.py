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
require(bool(re.search(r"InpDailyLossLimitPercent\s*=\s*4\.0", ea))
        and bool(re.search(r"InpWeeklyLossLimitPercent\s*=\s*8\.0", ea))
        and bool(re.search(r"InpMaxLossesPerRolling24Hours\s*=\s*4", ea)),
        "EA defaults match the 4% daily, 8% weekly, and rolling-24-hour loss safety policy")
require("m_dailyLossLimitPercent=4.0" in risk and "m_maxLossesRolling24h=4" in risk
        and "m_weeklyLossLimitPercent=8.0" in risk and "weeklyLossLimitPercent=8.0" in risk
        and "Rolling24HourLossLimitBreached" in risk and "LossesInRolling24Hours" in risk,
        "risk-engine fallback and Configure defaults match the EA loss limits")
require("GlobalVariableSet" in risk and "LoadLossTimes" in risk
        and "PersistLossTimes" in risk and "m_lossPersistenceOk" in risk,
        "rolling 24-hour loss history persists across restarts and blocks entries if persistence fails")
require("EquityStateKey" in risk and "PersistEquityState" in risk
        and "LoadEquityState" in risk and "m_equityPersistenceOk" in risk
        and "AXFDEQ_%I64d_%s" in risk,
        "account-wide daily/weekly baselines and lockouts persist across restarts and fail closed on corrupt state")
require("RegisterTradeClosed(rec.netProfit,closeTime)" in ea
        and "datetime closedAt=(closeTime>0) ? closeTime : TimeCurrent()" in risk
        and "datetime writtenAt=GlobalVariableSet(key,storedValue)" in risk,
        "rolling loss guard uses the broker close timestamp and verifies persistent writes")
require("ConfirmPosition(symbol,dir,lots,ticketOut,fillPriceOut,actualLotsOut)" in execution,
        "market entries require broker position confirmation")
require("retcode!=TRADE_RETCODE_DONE" in execution,
        "stop modifications require an accepted server retcode")
require("g_posState.modifyFailCount>=InpMaxModifyFailures" in ea
        and "AxCloseAndRecord(AX_EXIT_EXECUTION_QUALITY)" in ea,
        "repeated stop-management failures trigger a defensive exit")
require("not a martingale" in readme.lower() and "never averages down" in readme.lower(),
        "documentation explicitly prohibits martingale and averaging down")


# Guard ordering matters: risk, margin and exposure must be checked against the final
# normalized volume AFTER every adaptive multiplier and affordability adjustment.
afe_i = ea.find("if(!g_afe.Evaluate(")
impact_i = ea.find("g_heatmap.EstimateExecution(")
final_risk_i = ea.find("bool finalRiskOk=")
open_i = ea.find("g_exec.OpenMarket(_Symbol,dir,lots,slPrice,tpPrice")
require(afe_i >= 0 and impact_i >= 0 and final_risk_i > afe_i and final_risk_i > impact_i and open_i > final_risk_i,
        "final risk/margin/exposure checks run after adaptive and impact sizing, before order submission")
require("OrderCalcProfit(finalOrderType,_Symbol,lots,intendedPrice,slPrice,finalStopProfit)" in ea
        and "OrderCalcMargin(finalOrderType,_Symbol,lots,intendedPrice,requiredMargin)" in ea
        and "!finalRiskOk" in ea and "!finalMarginOk" in ea,
        "final volume is rejected if account-currency stop risk or projected margin cannot be verified")
require("bool finalExposureOk=g_risk.ProjectedExposureAcceptable(symbolExposureLots," in ea
        and "bool finalAccountExposureOk=(accountExposureLots+lots<=InpMaxExposureLots+0.0000001)" in ea,
        "symbol/directional and account-wide caps are independently enforced on final volume")

open_market_i = execution.find("bool              OpenMarket(")
close_i = execution.find("bool              ClosePosition(")
open_market = execution[open_market_i:close_i] if open_market_i >= 0 and close_i > open_market_i else ""
require("bool serverConfirmedFill=(retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL)" in open_market
        and "Ambiguous order result, not retried" in open_market
        and "retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION" in open_market,
        "ambiguous market-order acknowledgements fail closed without blind duplicate retries")
close_body = execution[close_i:] if close_i >= 0 else ""
close_send_i = close_body.find("ok = m_trade.PositionClose(symbol)")
close_reconcile_i = close_body.find("if(!PositionSelect(symbol))", close_send_i)
close_retry_i = close_body.find("if(ok || !RetryableRetcode(retcode))", close_send_i)
require(close_send_i >= 0 and close_reconcile_i > close_send_i and close_retry_i > close_reconcile_i,
        "close requests reconcile broker position state before any retry decision")

print("Static safety audit passed. This is not an MQL5 compile or runtime test.")

# Research-driven VWAP/Kelly integration guardrails. These remain source-level checks,
# not a substitute for MetaEditor compilation or MT5 Strategy Tester execution.
KELLY = ROOT / "MQL5/Include/AutopsyX/KellyRuin.mqh"
require(KELLY.is_file(), "Kelly risk gate source exists")
kelly = KELLY.read_text(encoding="utf-8")
require(bool(re.search(r"InpUseVWAPExit\s*=\s*true", ea)),
        "mechanical VWAP exit is enabled by default while execution remains ANALYSIS_ONLY")
require("vwapExitCurrentPrice" in ea and "g_lastClosedBarClose,vwapExitCurrentPrice,false" in ea,
        "IMMEDIATE VWAP exit receives the live executable-side quote")
require("AX_VWAP_EXIT_CONFIRMED_CROSS_PLUS_STRUCTURE" in ea and "return(INIT_PARAMETERS_INCORRECT)" in ea,
        "unsupported structure-confirmed VWAP mode fails initialization instead of silently falling back")
require("#include <AutopsyX/KellyRuin.mqh>" in ea and "EvaluateConservative" in ea,
        "Kelly estimator is included and called by the entry gate")
require("95% Wilson lower bound" in kelly and "AX_KELLY_MIN_SAMPLE" in kelly,
        "Kelly sizing uses a conservative win-rate bound and minimum sample requirement")
require("InpKellyWarmupRiskPercent" in ea and "MathMin(configuredRiskPct,kellyReport.halfKellyFraction*100.0)" in ea,
        "Kelly gate caps risk during warm-up and at no more than half conservative Kelly")
