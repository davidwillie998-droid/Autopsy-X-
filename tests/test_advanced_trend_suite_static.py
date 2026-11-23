from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
SUITE = (ROOT / "MQL5/Include/AutopsyX/AdvancedTrendSuite.mqh").read_text()
IQ200 = (ROOT / "MQL5/Include/AutopsyX/IQ200Telemetry.mqh").read_text()


def test_advanced_suite_contains_requested_engines():
    for symbol in (
        "class CMFIEngine",
        "class CAlphaTrendEngine",
        "class CSlingshotEMAEngine",
        "class CChandelierExitEngine",
        "class CUltimateTrendAlphaEngine",
        "class CAdaptiveMarketRegimeEngine",
        "class CExecutionFeedbackEngine",
    ):
        assert symbol in SUITE


def test_advanced_suite_is_observational_not_an_order_router():
    assert "CTrade" not in SUITE
    assert "OrderSend(" not in SUITE
    assert "PositionClose(" not in SUITE
    assert "OrderCalcMargin(" not in SUITE


def test_shadow_river_is_included_and_sampled():
    assert '#include <AutopsyX/ShadowRiverEngine.mqh>' in EA
    assert "g_shadowRiver.ConfigurePoints" in EA
    assert "g_shadowRiver.Update(g_md.CurrentMid(),TimeCurrent())" in EA


def test_indicator_suite_is_initialized_sampled_and_released():
    for token in (
        "g_alphaTrend.Init",
        "g_mfi.Init",
        "g_slingshot.Init",
        "g_chandelier.Init",
        "g_alphaTrend.Update",
        "g_mfi.Update",
        "g_slingshot.Update",
        "g_chandelier.Update",
        "g_alphaTrend.Deinit",
        "g_mfi.Deinit",
        "g_slingshot.Deinit",
        "g_chandelier.Deinit",
    ):
        assert token in EA


def test_ultimate_alpha_uses_weekly_and_daily_permissions():
    assert "g_w1Institutional.AllowsDirection(AX_DIR_BUY)" in EA
    assert "g_d1Institutional.AllowsDirection(AX_DIR_BUY)" in EA
    assert "g_ultimateTrendAlpha.Evaluate(" in EA


def test_adaptive_regime_reuses_existing_classification():
    assert "g_adaptiveMarketRegime.Update(g_regimeClassification)" in EA
    assert "SAxRegimeClassification" in SUITE


def test_execution_feedback_receives_only_valid_observations():
    assert "g_executionFeedback.RecordFill" in EA
    assert "g_executionFeedback.RecordMarkout" in EA
    assert "markoutValid[markoutIndex]" in EA
    assert "markoutValid[outputIndex]=quoteReady" in IQ200


def test_advanced_suite_does_not_change_account_risk_authority():
    assert "g_accountRisk.Evaluate" in EA
    assert "g_accountRiskCoordinator" in EA
    assert "InpExtremeRiskPercent      = 5.0" in EA
    assert "InpMaxAccountStopRiskPercent = 10.0" in EA
    assert "InpMaxAccountStopRiskPercent" in EA
    assert "InpEnablePyramidExecution    = false" in EA


def test_advanced_suite_remains_analysis_only():
    assert "ANALYSIS ONLY" in EA
    assert "InpExecutionMode" in EA
    assert "AX_EXEC_ANALYSIS" in EA
