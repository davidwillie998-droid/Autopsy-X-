"""Full-position holding policy source-contract tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")


class FullPositionHoldingTests(unittest.TestCase):
    def test_partial_take_profit_is_opt_in_and_bounded(self):
        self.assertIn("InpEnablePartialTP        = false", EA)
        start = EA.index("bool AxManageHedgingPartialCloseTickets(void)")
        end = EA.index("bool AxManageHedgingBreakEvenTickets(void)", start)
        manager = EA[start:end]
        self.assertIn("if(!InpEnablePartialTP) return(true);", manager)
        self.assertIn("achievedRR<InpPartialTriggerRR", manager)
        self.assertIn("g_virtualExitRegistry.BeginPartialCloseAction", manager)
        self.assertIn("g_exec.ClosePartial(live.symbol,live.ticket,live.positionIdentifier", manager)
        self.assertIn("saved.partialCloseCount>0", manager)

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
