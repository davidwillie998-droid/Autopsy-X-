"""Static contracts for the durable hedging full-close journal."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LEDGER = (ROOT / "MQL5/Include/AutopsyX/HedgingFullCloseLedger.mqh").read_text(
    encoding="utf-8-sig"
)
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)


class HedgingFullCloseLedgerTests(unittest.TestCase):
    def test_full_close_journal_is_keyed_by_stable_position_identity(self):
        self.assertIn("FindIndex(const ulong positionIdentifier)", LEDGER)
        self.assertIn("m_records[i].positionIdentifier==positionIdentifier", LEDGER)
        self.assertIn("bool Find(const ulong positionIdentifier", LEDGER)

    def test_journal_captures_entry_and_complete_exit_accounting(self):
        for field in (
            "positionIdentifier", "finalDealTicket", "lastExitDealTicket",
            "symbol", "magic", "direction", "entryTime", "entryPrice",
            "entryVolume", "closeTime", "weightedClosePrice",
            "totalClosedVolume", "exitDealCount", "grossProfit",
            "commission", "swap", "fees", "netProfit",
            "partialClosedVolume",
        ):
            self.assertIn(field, LEDGER)

    def test_final_volume_must_account_for_original_position_volume(self):
        self.assertIn("r.totalClosedVolume+0.00000001<r.entryVolume", LEDGER)
        self.assertIn("r.partialClosedVolume>r.totalClosedVolume", LEDGER)

    def test_invalid_numbers_and_missing_deal_identity_are_rejected(self):
        self.assertIn("r.positionIdentifier==0", LEDGER)
        self.assertIn("r.finalDealTicket==0", LEDGER)
        self.assertIn("r.lastExitDealTicket==0", LEDGER)
        for field in (
            "entryPrice", "entryVolume", "weightedClosePrice",
            "totalClosedVolume", "grossProfit", "commission",
            "swap", "fees", "netProfit",
        ):
            self.assertIn(f"MathIsValidNumber(r.{field})", LEDGER)

    def test_one_immutable_record_per_position_and_strict_replay(self):
        self.assertIn("FindIndex(record.positionIdentifier)", LEDGER)
        self.assertIn("return(SameRecord(m_records[index],record))", LEDGER)
        self.assertIn("a.finalDealTicket==b.finalDealTicket", LEDGER)
        self.assertIn("a.netProfit-b.netProfit", LEDGER)

    def test_file_is_account_symbol_and_magic_scoped(self):
        self.assertIn("AccountInfoInteger(ACCOUNT_LOGIN)", LEDGER)
        self.assertIn("%I64d_%I64u_HedgingFullCloses_v1.csv", LEDGER)

    def test_persistence_uses_flush_and_atomic_replacement(self):
        self.assertIn('string tempName=m_fileName+".tmp"', LEDGER)
        self.assertIn("FileFlush(handle)", LEDGER)
        self.assertIn("FileMove(tempName,0,m_fileName,FILE_REWRITE)", LEDGER)

    def test_ea_initializes_independent_full_close_journal_fail_closed(self):
        self.assertIn('#include <AutopsyX/HedgingFullCloseLedger.mqh>', EA)
        self.assertIn("CHedgingFullCloseLedger g_hedgingFullCloseLedger", EA)
        self.assertIn("g_hedgingFullCloseLedger.Init(", EA)
        self.assertIn("g_hedgingFullCloseLedgerReady=false", EA)
        self.assertIn("multi-position full-close lifecycle remains quarantined", EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
