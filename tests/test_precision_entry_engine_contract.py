from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
ENGINE = (ROOT / "MQL5/Include/AutopsyX/PrecisionEntryEngine.mqh").read_text()


def test_precision_engine_is_wired_to_live_entry_confluence():
    assert '#include <AutopsyX/PrecisionEntryEngine.mqh>' in EA
    assert 'CPrecisionEntryEngine g_precisionEntry;' in EA
    assert 'g_precisionEntry.Init(_Symbol,InpPrecisionTimeframe' in EA
    assert 'g_precisionEntry.Release();' in EA
    assert 'if(!g_precisionEntryReady || !g_precisionEntry.AllowsDirection(dir))' in EA


def test_precision_confirmation_uses_completed_m15_data_only():
    assert 'CopyRates(m_symbol,m_timeframe,1,2,rates)' in ENGINE
    assert 'CopyBuffer(m_fastHandle,0,1,2,fast)' in ENGINE
    assert 'CopyBuffer(m_slowHandle,0,1,2,slow)' in ENGINE
    assert 'CopyBuffer(m_atrHandle,0,1,1,atr)' in ENGINE
    assert 'rates[0].close>rates[0].open' in ENGINE
    assert 'rates[0].close<rates[0].open' in ENGINE
    assert 'bodyRatio<m_minBodyRatio' in ENGINE
    assert 'range<atr[0]*m_minRangeAtr' in ENGINE


def test_pyramid_adds_require_fresh_precision_confirmation_and_keep_safety_defaults():
    assert 'g_precisionEntry.AllowsDirection(campaign.dir)' in EA
    assert 'InpExecutionMode = AX_EXEC_ANALYSIS_ONLY' in EA
    assert 'InpEnablePyramidExecution    = false' in EA
    assert 'g_accountRisk.Evaluate(_Symbol,campaign.dir,requestedLots' in EA
    assert 'g_distributedRiskCoordinator.Reserve(riskDecision,reserveSnapshot' in EA
