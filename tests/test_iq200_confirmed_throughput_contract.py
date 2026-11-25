from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()
TELEMETRY = (ROOT / "MQL5/Include/AutopsyX/IQ200Telemetry.mqh").read_text()


def test_throughput_counts_only_unique_broker_confirmed_entry_deal_slices():
    assert "RecordConfirmedEntryDeal(" in EA
    assert "DEAL_TIME_MSC" in EA
    assert "DEAL_VOLUME" in EA
    assert "if(!MarkDealTicketSeen(dealTicket)) return(false);" in TELEMETRY
    assert "m_confirmedEntryDealCount++;" in TELEMETRY
    assert "m_confirmedEntryVolume+=dealVolume;" in TELEMETRY


def test_throughput_is_not_order_request_rate_or_completed_order_count():
    method = TELEMETRY[
        TELEMETRY.index("bool RecordConfirmedEntryDeal("):
        TELEMETRY.index("ulong ConfirmedEntryDealCount", TELEMETRY.index("bool RecordConfirmedEntryDeal("))
    ]
    assert "broker-confirmed ENTRY deal slices" in TELEMETRY
    assert "dealTicket" in method
    assert "dealTimeMsc" in method
    assert "dealVolume" in method
    assert "ORDER_SUBMITTED" not in method
    assert "AX_IQ200_DEAL_FILLED" not in method


def test_throughput_uses_broker_second_buckets_and_handles_delayed_callbacks():
    assert "#define AX_IQ200_THROUGHPUT_BUCKETS 120" in TELEMETRY
    assert "long second=dealTimeMsc/1000;" in TELEMETRY
    assert "m_throughputSecond[slot]==second" in TELEMETRY
    assert "m_throughputSecond[slot]<second" in TELEMETRY
    assert "older callback colliding with a newer bucket" in TELEMETRY
    assert "m_peakConfirmedEntryDealsPerSecond" in TELEMETRY


def test_deal_deduplication_capacity_and_reinitialization_cover_all_slots():
    assert "#define AX_IQ200_DEAL_DEDUPE_CAPACITY 65536" in TELEMETRY
    assert "m_seenDealNext=(m_seenDealNext+1)%AX_IQ200_DEAL_DEDUPE_CAPACITY;" in TELEMETRY
    assert TELEMETRY.count("for(int i=0;i<AX_IQ200_DEAL_DEDUPE_CAPACITY;i++) m_seenDealTickets[i]=0;") >= 2
    assert "m_confirmedEntryDealCount=0;" in TELEMETRY
    assert "m_peakConfirmedEntryDealsPerSecond=0;" in TELEMETRY
