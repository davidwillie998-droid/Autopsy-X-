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


def test_verified_multi_leg_state_does_not_latch_the_integrity_quarantine():
    audit = EA.index("// Audit every leg against its durable exit", EA.index("void AxProcessTick(void)"))
    start = EA.index("if(g_hedgingPositionManager.HasMultiplePositions())", audit)
    end = EA.index("if(g_hedgingLifecycleLock)", start)
    block = EA[start:end]
    assert "g_hedgingLifecycleLock=true" not in block
    assert "g_engineState=AX_ENGINE_PAUSED;" in block
    assert "AxManageHedgingVirtualExitTickets()" in EA
    assert "fresh entries are blocked until the multi-leg set is resolved" in block


def test_startup_multi_leg_detection_does_not_latch_sticky_lock():
    init_start = EA.index("int OnInit(void)")
    init_end = EA.index("void OnDeinit", init_start)
    init_block = EA[init_start:init_end]
    multi_start = init_block.index("else if(g_hedgingPositionManager.HasMultiplePositions())")
    multi_end = init_block.index("// Rehydrate complete state by stable POSITION_IDENTIFIER", multi_start)
    multi_block = init_block[multi_start:multi_end]
    assert "g_hedgingLifecycleLock=true" not in multi_block
    assert "g_pyramidReady=false" in multi_block


def test_single_leg_handoff_rehydrates_exact_remaining_identifier():
    tick_start = EA.index("void AxProcessTick(void)")
    tick_block = EA[tick_start:]
    handoff_start = tick_block.index("Rehydrate the legacy single-position controller")
    handoff_end = tick_block.index("if(g_hedgingLifecycleLock)", handoff_start)
    handoff = tick_block[handoff_start:handoff_end]
    assert "FindByIdentifier(remainingPosition.positionIdentifier,remainingState)" in handoff
    assert "remainingState.ticket!=remainingPosition.ticket" in handoff
    assert "g_posState=remainingState.state;" in handoff
    assert "g_haveOpenPosition=true;" in handoff
    assert "g_positionIdentifier=0;" in handoff

def test_virtual_exit_reconciliation_accepts_missing_broker_stop_only_with_persisted_levels():
    start = EA.index("bool AxReconcileVirtualExitTickets(const bool removeStaleRecords)")
    end = EA.index("bool AxRecoverFullyClosedPosition(", start)
    reconcile = EA[start:end]
    assert "(live.hasValidBrokerStop && MathAbs(saved.emergencySlPrice-live.stopLoss)" in reconcile
    assert "(!live.hasValidBrokerStop && (saved.emergencySlPrice<=0.0 || saved.virtualSlPrice<=0.0))" in reconcile
    assert "saved.virtualSlPrice<=0.0 || saved.entryTime<=0" in reconcile


def test_virtual_sl_tp_runs_before_managers_that_require_broker_stop():
    start = EA.index("void AxProcessTick(void)")
    end = EA.index("void OnTick(void)", start)
    tick = EA[start:end]
    virtual_exit = tick.index("AxManageHedgingVirtualExitTickets()")
    break_even = tick.index("AxManageHedgingBreakEvenTickets()")
    trailing = tick.index("AxManageHedgingTrailingTickets()")
    partial = tick.index("AxManageHedgingPartialCloseTickets()")
    assert virtual_exit < break_even < trailing < partial


def test_unprotected_legs_skip_stop_modification_and_scaleout_without_claiming_protection():
    be_start = EA.index("bool AxManageHedgingBreakEvenTickets(void)")
    be_end = EA.index("bool AxManageHedgingTrailingTickets(void)", be_start)
    be = EA[be_start:be_end]
    trail_start = be_end
    trail_end = EA.index("void AxProcessTick(void)", trail_start)
    trail = EA[trail_start:trail_end]
    partial_start = EA.index("bool AxManageHedgingPartialCloseTickets(void)")
    partial_end = be_start
    partial = EA[partial_start:partial_end]
    for manager in (be, trail, partial):
        assert "if(!live.hasValidBrokerStop)" in manager
        assert "continue;" in manager
    assert "broker protection is absent" in be
    assert "trailing modification skipped" in trail
    assert "scale-out skipped" in partial

