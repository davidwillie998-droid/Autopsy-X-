"""Source-level regression guards for multi-position recovery and exits.

These checks protect lifecycle wiring and fail-closed invariants. They do not
simulate broker callbacks or replace MetaEditor/Strategy Tester validation.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
POSITION_STATE = (ROOT / "MQL5/Include/AutopsyX/PositionStateRegistry.mqh").read_text()
POSITION_MANAGER = (ROOT / "MQL5/Include/AutopsyX/HedgingPositionManager.mqh").read_text()
VIRTUAL_EXITS = (ROOT / "MQL5/Include/AutopsyX/VirtualExitRegistry.mqh").read_text()
PYRAMID = (ROOT / "MQL5/Include/AutopsyX/PyramidCampaignRegistry.mqh").read_text()
CAMPAIGN_AUDIT = (ROOT / "MQL5/Include/AutopsyX/HedgingCampaignLifecycle.mqh").read_text()


def _method(source: str, signature: str, next_signature: str) -> str:
    start = source.index(signature)
    end = source.index(next_signature, start)
    return source[start:end]


def test_broker_snapshot_enumerates_all_ea_owned_positions_and_rejects_duplicate_ids():
    refresh = _method(
        POSITION_MANAGER,
        "bool Refresh(const string symbol,const ulong magic)",
        "int Count(void) const",
    )
    assert "int total=PositionsTotal();" in refresh
    assert "PositionGetTicket(i)" in refresh
    assert "PositionSelectByTicket(ticket)" in refresh
    assert "POSITION_IDENTIFIER" in refresh
    assert "DUPLICATE_POSITION_IDENTIFIER" in refresh
    assert "m_complete=true;" in refresh


def test_durable_position_state_is_identifier_keyed_and_ticket_unique():
    assert "FindIndex(record.positionIdentifier)>=0" in POSITION_STATE
    assert "m_records[duplicateIndex].ticket==record.ticket" in POSITION_STATE
    upsert = _method(
        POSITION_STATE,
        "bool Upsert(const ulong id,const ulong ticket",
        "bool FindByIdentifier(",
    )
    assert "BROKER_TICKET_OWNERSHIP_CONFLICT" in upsert
    assert "POSITION_IDENTITY_OWNERSHIP_CONFLICT" in upsert
    assert "if(RewriteFile()) return(true);" in upsert
    assert "m_records[index]=previous;" in upsert


def test_startup_rehydrates_each_open_position_without_synthetic_state():
    assert "for(int stateIndex=0;stateIndex<g_hedgingPositionManager.Count();stateIndex++)" in EA
    assert "FindByIdentifier(liveStatePosition.positionIdentifier,savedStateRecord)" in EA
    assert "no synthetic state created" in EA
    assert "savedStateRecord.ticket=liveStatePosition.ticket;" in EA


def test_multi_leg_managers_iterate_and_close_exact_position_ticket():
    manager = _method(
        EA,
        "bool AxManageHedgingSignalExitTickets(",
        "bool AxCloseOneHedgingPositionForRiskShutdown(",
    )
    assert "for(int i=0;i<g_hedgingPositionManager.Count();i++)" in manager
    assert "FindByIdentifier(live.positionIdentifier,saved)" in manager
    assert "AxCloseHedgingPositionByTicket(live)" in manager
    assert "return(true);" in manager


def test_full_close_uses_persisted_action_lock_and_broker_confirmation():
    close = _method(
        EA,
        "bool AxCloseHedgingPositionByTicket(",
        "bool AxManageHedgingVirtualExitTickets(",
    )
    assert "BeginFullCloseAction(live.positionIdentifier,baselineVolume)" in close
    assert "outcomeUncertain" in close
    assert "action lock retained, no retry" in close
    assert "g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)" in close
    assert "FindByIdentifier(live.positionIdentifier,stillLive)" in close
    assert "AxFinalizeHedgingFullClose(actionState)" in close


def test_virtual_exit_actions_cannot_be_replayed_while_locked():
    assert "if(!Find(positionIdentifier,record) || record.actionLocked) return(false);" in VIRTUAL_EXITS
    assert "actionLocked && (record.actionCode<=0 || record.actionStartedAt<=0)" in VIRTUAL_EXITS
    assert "(!record.actionLocked && (record.actionCode!=0" in VIRTUAL_EXITS
    assert "ResolveAction(const ulong positionIdentifier,const int expectedActionCode)" in VIRTUAL_EXITS


def test_campaign_audit_requires_matching_exit_and_campaign_identity_per_leg():
    assert "virtualExits.Find(live.positionIdentifier,exitRecord)" in CAMPAIGN_AUDIT
    assert "exitRecord.ticket!=live.ticket" in CAMPAIGN_AUDIT
    assert "exitRecord.symbol!=live.symbol" in CAMPAIGN_AUDIT
    assert "campaigns.Find(live.positionIdentifier,campaign)" in CAMPAIGN_AUDIT
    assert "campaign.ticket!=live.ticket" in CAMPAIGN_AUDIT
    assert "campaign.dir!=live.direction" in CAMPAIGN_AUDIT
    assert "if(exitRecord.actionLocked)" in CAMPAIGN_AUDIT


def test_multi_position_execution_is_held_until_ticket_specific_management_runs():
    tick = _method(
        EA,
        "void AxProcessTick(void)",
        "void OnTick(void)",
    )
    assert "AxManageHedgingVirtualExitTickets()" in tick
    assert "AxManageHedgingBreakEvenTickets()" in tick
    assert "AxManageHedgingTrailingTickets()" in tick
    assert "AxManageHedgingPartialCloseTickets()" in tick
    assert "g_hedgingCampaignLifecycle.Evaluate(" in tick
    assert "multiPositionLifecycleActive=true;" in tick
    assert "AxManageHedgingSignalExitTickets(g_lastScore" in tick


def test_risk_shutdown_closes_one_confirmed_leg_at_a_time():
    assert "AxCloseOneHedgingPositionForRiskShutdown()" in EA
    shutdown = _method(
        EA,
        "bool AxCloseOneHedgingPositionForRiskShutdown(void)",
        "bool AxCloseHedgingPositionByTicket(",
    )
    assert "g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)" in shutdown
    assert "GetAt(0,live)" in shutdown
    assert "AxCloseHedgingPositionByTicket(live)" in shutdown
