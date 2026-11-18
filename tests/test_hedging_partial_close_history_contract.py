"""Static contracts for identifier-scoped partial-close deal reconciliation."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(
    encoding="utf-8-sig"
)


class HedgingPartialCloseHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        start = EA.index("bool AxFetchCloseFinancialsByIdentifier(")
        end = EA.index("bool AxFetchCloseFinancials(", start)
        cls.reader = EA[start:end]

    def test_reader_is_position_identifier_scoped(self):
        self.assertIn("HistorySelectByPosition((long)positionIdentifier)", self.reader)
        self.assertIn("DEAL_POSITION_ID", self.reader)
        self.assertNotIn("g_posState", self.reader)
        self.assertNotIn("g_positionIdentifier", self.reader)

    def test_reader_validates_symbol_magic_and_direction(self):
        self.assertIn("expectedSymbol", self.reader)
        self.assertIn("expectedMagic", self.reader)
        self.assertIn("expectedCloseType", self.reader)
        self.assertIn("DEAL_TYPE", self.reader)

    def test_reader_uses_exclusive_deal_ticket_cursor(self):
        self.assertIn("dealTicket<=sinceTicketExclusive", self.reader)
        self.assertIn("lastDealTicketOut=dealTicket", self.reader)

    def test_reader_rejects_ambiguous_reversal_allocation(self):
        self.assertIn("entryType==DEAL_ENTRY_INOUT", self.reader)
        self.assertIn("return(false)", self.reader)

    def test_reader_aggregates_only_confirmed_exit_deals(self):
        self.assertIn("DEAL_ENTRY_OUT", self.reader)
        self.assertIn("DEAL_ENTRY_OUT_BY", self.reader)
        self.assertIn("weightedCloseValue+=dealPrice*dealVolume", self.reader)
        self.assertIn("closedVolumeOut+=dealVolume", self.reader)

    def test_reader_rejects_invalid_financial_values(self):
        self.assertIn("MathIsValidNumber(dealVolume)", self.reader)
        self.assertIn("MathIsValidNumber(dealProfit)", self.reader)
        self.assertIn("MathIsValidNumber(dealCommission)", self.reader)
        self.assertIn("MathIsValidNumber(dealSwap)", self.reader)


if __name__ == "__main__":
    unittest.main(verbosity=2)
