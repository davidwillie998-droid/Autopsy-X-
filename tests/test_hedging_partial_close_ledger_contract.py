"""Static contracts for the durable per-position partial-close ledger."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LEDGER = (ROOT / "MQL5/Include/AutopsyX/HedgingPartialCloseLedger.mqh").read_text(
    encoding="utf-8-sig"
)
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)


class HedgingPartialCloseLedgerTests(unittest.TestCase):
    def test_ledger_identity_is_position_and_deal_scoped(self):
        self.assertIn("FindIndex(const ulong positionIdentifier,const ulong dealTicket)", LEDGER)
        self.assertIn("m_records[i].positionIdentifier==positionIdentifier", LEDGER)
        self.assertIn("m_records[i].dealTicket==dealTicket", LEDGER)

    def test_ledger_persists_broker_confirmed_entry_and_exit_facts(self):
        for field in (
            "positionIdentifier", "dealTicket", "symbol", "magic", "direction",
            "entryTime", "entryPrice", "entryVolume", "closeTime", "closePrice",
            "closedVolume", "grossProfit", "commission", "swap",
        ):
            self.assertIn(field, LEDGER)
        self.assertIn("closedVolume>=r.entryVolume", LEDGER)

    def test_ledger_rejects_invalid_numeric_values(self):
        self.assertIn("MathIsValidNumber(r.entryPrice)", LEDGER)
        self.assertIn("MathIsValidNumber(r.entryVolume)", LEDGER)
        self.assertIn("MathIsValidNumber(r.closePrice)", LEDGER)
        self.assertIn("MathIsValidNumber(r.closedVolume)", LEDGER)
        self.assertIn("MathIsValidNumber(r.grossProfit)", LEDGER)
        self.assertIn("MathIsValidNumber(r.commission)", LEDGER)
        self.assertIn("MathIsValidNumber(r.swap)", LEDGER)

    def test_duplicate_replay_requires_identical_payload(self):
        record = LEDGER[LEDGER.index("bool Record("):LEDGER.index("bool Find(", LEDGER.index("bool Record("))]
        self.assertIn("if(index>=0)", record)
        self.assertIn("MathAbs(old.grossProfit-record.grossProfit)", record)
        self.assertIn("MathAbs(old.closedVolume-record.closedVolume)", record)

    def test_persistence_uses_staged_atomic_replacement(self):
        self.assertIn('string tempName=m_fileName+".tmp"', LEDGER)
        self.assertIn("FileFlush(handle)", LEDGER)
        self.assertIn("FileMove(tempName,0,m_fileName,FILE_REWRITE)", LEDGER)

    def test_ledger_file_is_scoped_to_account_symbol_and_magic(self):
        self.assertIn("AccountInfoInteger(ACCOUNT_LOGIN)", LEDGER)
        self.assertIn("%I64d_%I64u_HedgingPartialCloses_v1.csv", LEDGER)

    def test_no_single_position_global_state_dependency(self):
        self.assertNotIn("g_posState", LEDGER)
        self.assertNotIn("g_positionIdentifier", LEDGER)

    def test_ea_initializes_independent_ledger_and_stays_fail_closed(self):
        self.assertIn('#include <AutopsyX/HedgingPartialCloseLedger.mqh>', EA)
        self.assertIn("g_hedgingPartialCloseLedger.Init(", EA)
        self.assertIn("g_hedgingPartialLedgerReady=false", EA)
        self.assertIn("multi-position partial-close lifecycle remains quarantined", EA)

    def test_per_position_adapter_uses_saved_entry_facts_not_global_position_state(self):
        start = EA.index("bool AxRecordHedgingPartialCloseLedger(")
        end = EA.index("bool AxFetchCloseFinancials(", start)
        adapter = EA[start:end]
        self.assertIn("saved.positionIdentifier", adapter)
        self.assertIn("saved.entryPrice", adapter)
        self.assertIn("saved.entryVolume", adapter)
        self.assertIn("g_hedgingPartialCloseLedger.Record(record)", adapter)
        self.assertNotIn("g_posState", adapter)
        self.assertNotIn("g_positionIdentifier", adapter)

    def test_partial_slice_cannot_be_misclassified_as_full_position_exit(self):
        self.assertIn("closedVolume>=saved.entryVolume", EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
