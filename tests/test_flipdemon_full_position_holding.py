"""Full-position holding policy source-contract tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")


class FullPositionHoldingTests(unittest.TestCase):
    def test_user_cannot_enable_discretionary_partial_take_profit(self):
        self.assertNotIn("InpEnablePartialTP", EA)
        self.assertNotIn("InpPartialTriggerRR", EA)
        self.assertNotIn("InpPartialClosePercent", EA)

    def test_live_position_manager_does_not_trigger_scale_out(self):
        self.assertNotIn("g_exit.CheckPartialTakeProfit(", EA)
        self.assertNotIn("AxExecutePartialClose(volToClose)", EA)

    def test_full_exit_and_protective_stop_management_remain(self):
        self.assertIn("if(dec.shouldExit)", EA)
        self.assertIn("AxCloseAndRecord(dec.reason)", EA)
        self.assertIn("g_exit.CheckBreakEven(", EA)
        self.assertIn("g_exit.CheckTrailing(", EA)

    def test_legacy_partial_reconciliation_is_retained_for_restart_safety(self):
        self.assertIn("AxRetryPendingPartialClose();", EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
