from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
ENGINE = (ROOT / "MQL5/Include/AutopsyX/HedgingCampaignLifecycle.mqh").read_text()


def test_ticket_lifecycle_audits_each_live_leg_against_both_durable_registries():
    assert '#include <AutopsyX/HedgingCampaignLifecycle.mqh>' in EA
    assert 'CHedgingCampaignLifecycle g_hedgingCampaignLifecycle;' in EA
    assert 'virtualExits.Find(live.positionIdentifier,exitRecord)' in ENGINE
    assert 'campaigns.Find(live.positionIdentifier,campaign)' in ENGINE
    assert 'exitRecord.ticket!=live.ticket' in ENGINE
    assert 'campaign.ticket!=live.ticket' in ENGINE
    assert 'exitRecord.actionLocked' in ENGINE


def test_hedging_lifecycle_rejects_mixed_direction_or_unprotected_legs():
    assert 'MIXED_DIRECTION_CAMPAIGN' in ENGINE
    assert 'ONE_OR_MORE_LEGS_LACK_VALID_BROKER_STOP' in ENGINE
    assert 'snapshot.allProtected' in ENGINE
    assert 'snapshot.grossLots+=live.volume' in ENGINE


def test_ticket_lifecycle_is_observation_only_and_does_not_authorize_multi_leg_execution():
    assert 'CTrade' not in ENGINE
    assert 'OrderSend(' not in ENGINE
    assert 'PositionOpen(' not in ENGINE
    assert 'TICKET_SPECIFIC_VIRTUAL_EXIT_MISSING_OR_STALE' in ENGINE
    assert 'TICKET_SPECIFIC_CAMPAIGN_RECORD_MISSING_OR_STALE' in ENGINE
    assert 'if(g_hedgingPositionManager.HasMultiplePositions())' in EA
    assert 'g_engineState=AX_ENGINE_PAUSED;' in EA
    assert 'InpExecutionMode = AX_EXEC_ANALYSIS_ONLY' in EA
