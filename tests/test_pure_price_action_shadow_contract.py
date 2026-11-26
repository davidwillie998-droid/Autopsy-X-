from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "MQL5/Include/AutopsyX/PurePriceAction.mqh"
EA = ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5"


def test_pure_price_action_is_ohlc_only_and_closed_bar_only():
    source = ENGINE.read_text(encoding="utf-8")
    assert 'CopyRates(m_symbol,m_timeframe,1,needed,rates)' in source
    assert "iTime(m_symbol,m_timeframe,1)" in source
    assert "iRSI(" not in source
    assert "iMACD(" not in source
    assert "iMA(" not in source
    assert "CopyBuffer(" not in source


def test_candle_geometry_is_normalized_and_guarded():
    source = ENGINE.read_text(encoding="utf-8")
    for field in (
        "bodyRatio",
        "upperWickRatio",
        "lowerWickRatio",
        "closeLocation",
    ):
        assert field in source
    assert "candleRange<=0.0" in source
    assert "AxClampD(bodyRatio,0.0,1.0)" in source
    assert "AxClampD(closeLocation,0.0,1.0)" in source


def test_impulse_context_excludes_the_candle_being_classified():
    source = ENGINE.read_text(encoding="utf-8")
    assert "The latest closed candle is excluded from the preceding impulse." in source
    assert "double impulseClose=rates[1].close;" in source
    assert "for(int i=1;i<m_lookback;i++)" in source


def test_bullish_and_bearish_expansion_are_symmetric():
    source = ENGINE.read_text(encoding="utf-8")
    assert "AX_PA_CANDLE_EXPANSION_BULL" in source
    assert "AX_PA_CANDLE_EXPANSION_BEAR" in source
    assert "closeLocation>=0.80" in source
    assert "closeLocation<=0.20" in source


def test_engine_has_no_execution_or_scoring_authority():
    source = ENGINE.read_text(encoding="utf-8")
    for forbidden in ("CTrade", "OrderSend(", "PositionOpen(", "Buy(", "Sell("):
        assert forbidden not in source
    assert "BullishScoreComponent" not in source
    assert "BearishScoreComponent" not in source


def test_ea_wires_engine_as_observational_shadow_only():
    source = EA.read_text(encoding="utf-8")
    assert '#include <AutopsyX/PurePriceAction.mqh>' in source
    assert "InpEnablePurePriceActionDiagnostics = true" in source
    assert "g_purePriceAction.Update();" in source
    assert "if(InpVerboseLogging) Print(\"AUTOPSY X SHADOW: \"" in source
    start = source.index("void AxApplyOrderFlowBonus")
    end = source.index("\n  }", start)
    assert "g_purePriceAction" not in source[start:end]
