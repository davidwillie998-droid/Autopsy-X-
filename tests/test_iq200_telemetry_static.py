from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
IQ = (ROOT / "MQL5/Include/AutopsyX/IQ200Telemetry.mqh").read_text(encoding="utf-8-sig")
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")
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
    assert "#define AX_IQ200_QUEUE_CAPACITY 2048" in source
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
    flush = _method_body(source, "int Flush(const int maxRows=1024)")
    assert "FileWriteString" not in flush
    assert "WriteBatch(payload)" in flush
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
    assert "g_iq200Telemetry.Flush(1024);" in ea
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
    assert "g_iq200Telemetry.ProcessDueMarkouts(markoutValues,markoutValid);" in ea
    assert ea.index("g_iq200Telemetry.ProcessDueMarkouts(markoutValues,markoutValid);") < ea.index(
        "g_iq200Telemetry.Flush(64);"
    )
    assert "markoutBasis.fillPrice=dealPrice;" in ea
    assert "markoutBasis.confirmedVolume=dealVolume;" in ea
    assert "g_iq200Telemetry.ScheduleMarkouts(markoutBasis);" in ea
    assert "telemetryEvent.pointSize=SymbolInfoDouble(symbol,SYMBOL_POINT);" in ea



def test_iq200_only_entry_deals_create_fill_events_and_markouts():
    ea = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
        encoding="utf-8"
    )
    entry_branch = ea.index("HistoryDealSelect(trans.deal) &&\n              HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_IN &&")
    entry_body_end = ea.index("else if(trans.type==TRADE_TRANSACTION_DEAL_ADD", entry_branch)
    entry_body = ea[entry_branch:entry_body_end]
    assert "g_iq200Telemetry.ScheduleMarkouts(markoutBasis);" in entry_body
    assert "DEAL_ENTRY_OUT" not in entry_body
    assert "DEAL_ENTRY_OUT_BY" not in entry_body


def test_iq200_position_closed_event_requires_confirmed_flat_position():
    ea = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
        encoding="utf-8"
    )
    close_condition = ea.index("HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_OUT")
    close_branch = ea.index("AX_IQ200_POSITION_CLOSED", close_condition)
    close_body = ea[close_condition:close_branch+1400]
    assert "DEAL_ENTRY_OUT" in close_body
    assert "DEAL_ENTRY_OUT_BY" in close_body
    assert "DEAL_ENTRY_OUT_BY" in close_body
    assert "trans.position>0 && !PositionSelectByTicket(trans.position)" in close_body
    assert "g_iq200Telemetry.MarkDealTicketSeen(trans.deal)" in close_body
    assert "telemetryEvent.positionIdentifier=positionId;" in close_body

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


def test_iq200_uses_bounded_high_throughput_batch_persistence():
    assert "#define AX_IQ200_QUEUE_CAPACITY 2048" in IQ
    assert "bool WriteBatch(const string payload)" in IQ
    flush = IQ[IQ.index("int Flush(const int maxRows=1024)"):IQ.index("// Bind broker order identifiers", IQ.index("int Flush(const int maxRows=1024)"))]
    assert "payload+=Serialize(m_queue[slot]);" in flush
    assert "if(!WriteBatch(payload))" in flush
    assert "m_head=(m_head+batchRows)%AX_IQ200_QUEUE_CAPACITY;" in flush
    assert "m_count-=batchRows;" in flush
    assert "g_iq200Telemetry.Flush(1024);" in EA
