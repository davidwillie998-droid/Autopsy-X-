"""Static contracts for durable break-even stop monotonicity.

These tests inspect source text only. They do not compile MQL5 or contact a broker.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "MQL5/Include/AutopsyX/VirtualExitRegistry.mqh").read_text(
    encoding="utf-8-sig"
)


class BreakEvenPersistenceContractTests(unittest.TestCase):
    def test_break_even_rejects_invalid_price(self):
        self.assertIn("!MathIsValidNumber(confirmedStop)", SOURCE)

    def test_buy_break_even_cannot_weaken_initial_or_trailing_stop(self):
        self.assertIn("confirmedStop<record.initialSlPrice", SOURCE)
        self.assertIn("confirmedStop<record.trailingStopPrice", SOURCE)

    def test_sell_break_even_cannot_weaken_initial_or_trailing_stop(self):
        self.assertIn("confirmedStop>record.initialSlPrice", SOURCE)
        self.assertIn("confirmedStop>record.trailingStopPrice", SOURCE)

    def test_break_even_state_is_persisted_only_after_validation(self):
        start = SOURCE.index("bool RecordBreakEven(")
        end = SOURCE.index("\n   int Count(void)", start)
        method = SOURCE[start:end]
        self.assertLess(method.index("record.breakEvenDone=true;"),
                        method.index("return(Save(record) && IsPersisting());"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
