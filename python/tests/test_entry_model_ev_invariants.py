"""Regression checks for entry-model attribution and final-risk EV wiring.

These are source-level invariants. They do not execute MQL5 or replace
MetaEditor compilation, Strategy Tester runs, or broker-side validation.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
AUTOPSY = (ROOT / "MQL5/Include/AutopsyX/TradeAutopsy.mqh").read_text()
AFE = (ROOT / "MQL5/Include/AutopsyX/AdaptiveFlipEngine.mqh").read_text()
ELIGIBILITY = (ROOT / "MQL5/Include/AutopsyX/ExecutionEligibility.mqh").read_text()
SAFETY = (ROOT / "scripts/verify_flipdemon_safety.py").read_text()


def _method(source: str, signature: str, next_signature: str) -> str:
    start = source.index(signature)
    end = source.index(next_signature, start)
    return source[start:end]


def test_model_statistics_are_scoped_to_entry_model_and_provenance():
    method = _method(
        AUTOPSY,
        "bool              GetEntryModelStats(",
        "int               Count(void)",
    )
    assert 'model=="" || model=="UNKNOWN"' in method
    assert "campaign.entryModel!=model" in method
    assert "campaign.provenance!=provenance" in method
    assert "entryModelConsistent" in method
    assert "provenanceConsistent" in method


def test_partial_exits_are_aggregated_as_one_position_campaign():
    method = _method(
        AUTOPSY,
        "bool              GetEntryModelStats(",
        "int               Count(void)",
    )
    assert "positionIdentifier" in method
    assert "campaigns[group].net+=rec.netProfit;" in method
    assert "if(!rec.isPartial" in method
    assert "totalTrades++;" in method


def test_model_reward_and_loss_statistics_use_original_risk_units():
    method = _method(
        AUTOPSY,
        "bool              GetEntryModelStats(",
        "int               Count(void)",
    )
    assert "finalRec.rMultiple==EMPTY_VALUE" in method
    assert "originalRiskMoney=finalRec.netProfit/finalRec.rMultiple" in method
    assert "double campaignR=campaign.net/originalRiskMoney;" in method
    assert "winSumR+=campaignR;" in method
    assert "lossSumR+=campaignR;" in method
    assert "winSum+=campaign.net" not in method
    assert "lossSum+=campaign.net" not in method


def test_unknown_or_conflicting_campaigns_do_not_enter_model_statistics():
    method = _method(
        AUTOPSY,
        "bool              GetEntryModelStats(",
        "int               Count(void)",
    )
    assert 'rec.entryModel=="UNKNOWN"' in method
    assert "rec.entryModel!=campaigns[group].entryModel" in method
    assert "(int)rec.provenance!=campaigns[group].provenance" in method
    assert "!campaign.entryModelConsistent" in method
    assert "!campaign.provenanceConsistent" in method


def test_candidate_ev_uses_final_candidate_stop_risk_not_portfolio_risk_estimate():
    candidate = _method(
        AFE,
        "bool              CandidateExpectedValueR(",
        "//--- accessors for dashboard/autopsy ---",
    )
    assert "riskCurrency<=0.0" in candidate
    assert "winProbability<=0.0 || winProbability>=1.0" in candidate
    assert "costCurrency==EMPTY_VALUE" in candidate
    assert "costR=costCurrency/riskCurrency;" in candidate
    assert "expectedValueR=winProbability*rewardRisk-(1.0-winProbability)-costR;" in candidate


def test_missing_execution_cost_data_is_not_treated_as_free():
    cost = _method(
        AFE,
        "double            CalculateExpectedCost(",
        "//--- the core decision:",
    )
    assert "return(EMPTY_VALUE);" in cost
    assert "if(spreadPts<0) return(EMPTY_VALUE);" in cost
    assert "MathIsValidNumber(ptsToCurrency)" in cost


def test_live_entry_uses_broker_calculated_risk_and_final_lots():
    assert "OrderCalcProfit(candidateRiskOrder,_Symbol,lots,marginPrice,slPrice,candidateStopPnl)" in EA
    assert "CandidateExpectedValueR(_Symbol,dir,lots" in EA
    assert "MathAbs(candidateStopPnl)" in EA
    assert "executionThesis.expectedValueR=EMPTY_VALUE;" in EA
    assert "candidate cost or risk inputs unavailable" in EA
    assert "executionThesis.expectedValueR=0.0;" not in EA


def test_model_statistics_are_cleared_before_exact_model_lookup():
    reset = EA.index("afeStats.totalTrades=0;")
    lookup = EA.index("GetEntryModelStats(tag,(int)AxDetectProvenance()")
    assert reset < lookup
    assert "afeStats.avgWin=0.0;" in EA[reset:lookup]
    assert "afeStats.avgLoss=0.0;" in EA[reset:lookup]


def test_existing_safety_audit_checks_the_new_ev_contract():
    assert "CandidateExpectedValueR(_Symbol,dir,lots" in SAFETY
    assert "GetEntryModelStats(tag,(int)AxDetectProvenance()" in SAFETY
    assert "double campaignR=campaign.net/originalRiskMoney;" in SAFETY
    assert "executionThesis.expectedValueR=0.0;" not in SAFETY
