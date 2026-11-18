from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "MQL5/Include/AutopsyX/IQ200Telemetry.mqh"


def _source() -> str:
    return SOURCE.read_text(encoding="utf-8")


def _method_body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"Unclosed method: {signature}")


def test_iq200_queue_is_fixed_capacity_and_versioned():
    source = _source()
    assert "#define AX_IQ200_SCHEMA_VERSION 1" in source
    assert "#define AX_IQ200_QUEUE_CAPACITY 256" in source
    assert "SAxIQ200Event m_queue[AX_IQ200_QUEUE_CAPACITY]" in source


def test_iq200_captures_complete_order_lifecycle_event_vocabulary():
    source = _source()
    required = (
        "AX_IQ200_DECISION",
        "AX_IQ200_ROUTE_PLAN",
        "AX_IQ200_ORDER_SUBMITTED",
        "AX_IQ200_BROKER_ACK",
        "AX_IQ200_DEAL_PARTIAL",
        "AX_IQ200_DEAL_FILLED",
        "AX_IQ200_ORDER_CANCEL_REQUESTED",
        "AX_IQ200_ORDER_CANCELLED",
        "AX_IQ200_ORDER_REJECTED",
        "AX_IQ200_ORDER_EXPIRED",
        "AX_IQ200_ORDER_AMBIGUOUS",
        "AX_IQ200_POSITION_CLOSED",
        "AX_IQ200_MARKOUT",
        "AX_IQ200_QUEUE_OVERFLOW",
    )
    for event_name in required:
        assert event_name in source


def test_iq200_flush_is_separate_from_hot_callbacks():
    source = _source()
    flush = _method_body(source, "int Flush(const int maxRows=64)")
    assert "FileWriteString" not in flush
    assert "WriteLine(line)" in flush
    assert "OnTick" not in flush
    assert "OnTradeTransaction" not in flush
    assert "Call only from OnTimer" in source


def test_iq200_telemetry_has_no_trade_or_risk_authority():
    source = _source()
    forbidden = (
        "OrderSend(",
        "OrderSendAsync(",
        "OrderModify(",
        "OrderDelete(",
        "PositionModify(",
        "PositionClose(",
        "PositionOpen(",
        "Buy(",
        "Sell(",
    )
    for token in forbidden:
        assert token not in source


def test_iq200_csv_header_and_serializer_have_matching_field_count():
    source = _source()
    header_match = re.search(r'return\("schema_version,([^"]+)"\);', source)
    assert header_match
    header_count = 1 + len(header_match.group(1).split(","))
    format_match = re.search(r'return\(StringFormat\("([^"]+)"', source)
    assert format_match
    placeholders = re.findall(r"%(?:I64)?(?:u|d|s)|%\.\d+f", format_match.group(1))
    assert len(placeholders) == header_count


def test_iq200_is_flushed_only_from_timer_and_controlled_shutdown():
    ea = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
        encoding="utf-8"
    )
    assert "g_iq200Telemetry.Flush(64);" in ea
    assert "g_iq200Telemetry.Flush(AX_IQ200_QUEUE_CAPACITY);" in ea
    assert "g_iq200Telemetry.Enqueue(telemetryEvent);" in ea
    assert "g_iq200Telemetry.Init(_Symbol,InpMagicNumber)" in ea
    assert "EventSetTimer(1);" in ea


def test_iq200_decision_route_and_submission_events_are_correlated():
    ea = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
        encoding="utf-8"
    )
    execution = (ROOT / "MQL5/Include/AutopsyX/ExecutionEngine.mqh").read_text(
        encoding="utf-8"
    )
    assert "decisionEvent.decisionId=lifecycleSetupId;" in ea
    assert "routeEvent.decisionId=lifecycleSetupId;" in ea
    assert "g_exec.OpenMarket(" in ea
    assert "g_iq200Telemetry,lifecycleSetupId" in ea
    assert "telemetry.NewEvent(submittedEvent,AX_IQ200_ORDER_SUBMITTED" in execution
    assert "telemetry.Enqueue(submittedEvent);" in execution
    assert "telemetry.BindOrderDecision(orderTicket,decisionId);" in execution
    assert "DecisionIdForOrder(result.order)" in ea
    assert "DecisionIdForOrder(dealOrder)" in ea
    assert execution.index("telemetry.Enqueue(submittedEvent);") < execution.index("m_trade.Buy(lots")
    assert execution.index("telemetry.Enqueue(submittedEvent);") < execution.index("m_trade.Sell(lots")


def test_iq200_markout_scheduler_is_bounded_and_uses_three_horizons():
    source = _source()
    assert "SAxIQ200Event m_markoutEvents[128]" in source
    assert "m_markoutDueMs[128]" in source
    assert "horizons[0]=1000" in source
    assert "horizons[1]=5000" in source
    assert "horizons[2]=30000" in source
    assert "GetTickCount64()+(ulong)horizons[h]" in source
    assert "sample.direction>0)?tick.bid:tick.ask" in source
    assert "sample.fillPrice>0.0 && sample.pointSize>0.0" in source
    assert "(double)sample.direction*" in source
    assert "sample.missingMask|=2" in source
    assert "int ProcessDueMarkouts(void)" in source


def test_iq200_markouts_run_from_timer_not_hot_callbacks():
    ea = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
        encoding="utf-8"
    )
    assert "g_iq200Telemetry.ProcessDueMarkouts();" in ea
    assert ea.index("g_iq200Telemetry.ProcessDueMarkouts();") < ea.index(
        "g_iq200Telemetry.Flush(64);"
    )
    assert "markoutBasis.fillPrice=dealPrice;" in ea
    assert "markoutBasis.confirmedVolume=dealVolume;" in ea
    assert "g_iq200Telemetry.ScheduleMarkouts(markoutBasis);" in ea
    assert "telemetryEvent.pointSize=SymbolInfoDouble(symbol,SYMBOL_POINT);" in ea


def test_iq200_deal_events_distinguish_partial_from_cumulative_full_fill():
    ea = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
        encoding="utf-8"
    )
    telemetry = _source()
    assert "MarkDealTicketSeen(trans.deal)" in ea
    assert "cumulativeEntryVolume" in ea
    assert "orderFullyFilled" in ea
    assert "cumulativeEntryPriceValue" in ea
    assert "cumulativeEntryPriceValue/cumulativeEntryVolume" in ea
    assert "AX_IQ200_DEAL_PARTIAL" in ea
    assert "AX_IQ200_DEAL_FILLED" in ea
    assert "bool MarkDealTicketSeen(const ulong dealTicket)" in telemetry
