from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()


def test_multi_leg_lifecycle_defers_return_until_same_tick_blended_score():
    assert "bool multiPositionLifecycleActive=false;" in EA
    assert "multiPositionLifecycleActive=true;" in EA
    branch = EA[EA.index("FLIPDEMON HEDGING MULTI-LEG MANAGEMENT:"):
                EA.index("// Rehydrate the legacy single-position controller")]
    assert "return;" not in branch
    score = EA.index("g_lastScore = score;")
    controller = EA.index("AxManageHedgingSignalExitTickets(g_lastScore,isNewBarThisTick")
    assert controller > score


def test_each_leg_uses_its_own_durable_position_identity_and_direction():
    start = EA.index("bool AxManageHedgingSignalExitTickets(")
    end = EA.index("// Manage break-even independently", start)
    controller = EA[start:end]
    for required in (
        "FindByIdentifier(live.positionIdentifier,saved)",
        "saved.positionIdentifier!=live.positionIdentifier",
        "saved.ticket!=live.ticket",
        "saved.state.ticket!=live.ticket",
        "saved.symbol!=live.symbol",
        "saved.magic!=live.magic",
        "saved.state.dir!=live.direction",
        "saved.state.entryPrice-live.openPrice",
    ):
        assert required in controller


def test_signal_exit_uses_blended_score_and_existing_mechanical_exit_engine():
    start = EA.index("bool AxManageHedgingSignalExitTickets(")
    end = EA.index("// Manage break-even independently", start)
    controller = EA[start:end]
    assert "g_exit.Evaluate(saved.state,g_md,g_mom,g_micro,score" in controller
    assert "InpUseVWAPExit?g_effectiveVwapExitMode:AX_VWAP_EXIT_OFF" in controller
    assert "vwapExitCheckDue,g_vwapValue" in controller
    assert "g_lastClosedBarClose,currentPrice,false" in controller


def test_signal_exit_closes_only_one_exact_ticket_per_tick_and_blocks_new_entries():
    start = EA.index("bool AxManageHedgingSignalExitTickets(")
    end = EA.index("// Manage break-even independently", start)
    controller = EA[start:end]
    assert "AxCloseHedgingPositionByTicket(live)" in controller
    assert "return(true);" in controller
    controller_call = EA.index("AxManageHedgingSignalExitTickets(g_lastScore,isNewBarThisTick")
    tick = EA.rfind("if(multiPositionLifecycleActive)", EA.index("g_lastScore = score;"), controller_call)
    block = EA[tick:controller_call+500]
    assert "if(hedgingCloseAttempted)" in block
    assert "return;" in block
    assert "g_engineState=AX_ENGINE_PAUSED;" in block


def test_account_shutdown_routes_through_exact_ticket_closes_for_multi_leg_campaigns():
    start = EA.index("bool AxCloseOneHedgingPositionForRiskShutdown(")
    end = EA.index("// Manage break-even independently", start)
    shutdown = EA[start:end]
    assert "g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber)" in shutdown
    assert "g_hedgingPositionManager.GetAt(0,live)" in shutdown
    assert "AxCloseHedgingPositionByTicket(live)" in shutdown
    kill = EA[EA.index('if(g_risk.IsKilled())'):EA.index("//--- RISK SHUTDOWN")]
    assert "multiPositionLifecycleActive && InpCloseAllOnKill" in kill
    daily = EA[EA.index("if(g_risk.DailyLossLimitBreached())"):EA.index("// Multi-leg signal exits run")]
    assert "if(multiPositionLifecycleActive)" in daily
    assert "AxCloseOneHedgingPositionForRiskShutdown()" in daily
