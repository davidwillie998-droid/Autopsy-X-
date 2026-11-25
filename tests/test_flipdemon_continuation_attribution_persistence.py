"""Source-contract tests for durable continuation strategy attribution.

These tests verify source wiring and schema compatibility. They do not compile
MQL5 or establish trading performance.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFS = (ROOT / "MQL5/Include/AutopsyX/Defs.mqh").read_text(encoding="utf-8-sig")
JOURNAL = (ROOT / "MQL5/Include/AutopsyX/TradeAutopsy.mqh").read_text(encoding="utf-8-sig")
RECOVERY = (ROOT / "MQL5/Include/AutopsyX/RestartRecovery.mqh").read_text(encoding="utf-8-sig")
EA = (ROOT / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text(encoding="utf-8-sig")

FIELDS = (
    "vwapPullbackBullBonus", "vwapPullbackBearBonus",
    "overnightBiasBullBonus", "overnightBiasBearBonus",
    "twinContinuationBullBonus", "twinContinuationBearBonus",
)


class ContinuationAttributionPersistenceTests(unittest.TestCase):
    def test_position_and_trade_records_carry_all_six_fields(self):
        for field in FIELDS:
            with self.subTest(field=field):
                self.assertIn(field, DEFS)
                self.assertIn(f"g_posState.{field}", EA)
                self.assertIn(f"rec.{field}", EA)

    def test_trade_journal_writes_and_reads_v5_attribution_columns(self):
        self.assertIn("TradeAutopsy_v5.csv", JOURNAL)
        self.assertIn('"VWAPPullbackBullBonus"', JOURNAL)
        self.assertIn('"TwinContinuationBearBonus"', JOURNAL)
        self.assertIn("DoubleToString(rec.vwapPullbackBullBonus,3)", JOURNAL)
        self.assertIn("fieldCount!=44 && fieldCount!=50", JOURNAL)
        self.assertIn("fields[49]", JOURNAL)

    def test_v3_and_v4_journals_remain_in_recovery_path(self):
        self.assertIn("TradeAutopsy_v3.csv", JOURNAL)
        self.assertIn("TradeAutopsy_v4.csv", JOURNAL)
        self.assertIn("LoadTradeRecordsFile(m_legacyFileName,true", JOURNAL)
        self.assertIn("LoadTradeRecordsFile(m_v4FileName,false", JOURNAL)
        self.assertIn("ReadRiskHistoryFile(m_v4FileName,false)", JOURNAL)

    def test_journal_rejects_nonfinite_or_out_of_range_attribution(self):
        self.assertIn("!MathIsValidNumber(rec.vwapPullbackBullBonus)", JOURNAL)
        self.assertIn("rec.overnightBiasBullBonus>5.0", JOURNAL)
        self.assertIn("rec.twinContinuationBearBonus>8.0", JOURNAL)

    def test_recovery_registry_upgrades_six_field_rows_without_losing_compatibility(self):
        self.assertIn("#define AX_RECOVERY_FIELD_COUNT 12", RECOVERY)
        self.assertIn("if(n!=6 && n!=AX_RECOVERY_FIELD_COUNT)", RECOVERY)
        self.assertIn("StringToDouble(fields[11])", RECOVERY)
        self.assertIn("m_records[i].twinContinuationBearBonus", RECOVERY)

    def test_confirmed_fill_persists_attribution_in_recovery_registry(self):
        self.assertIn("g_restartRecovery.RecordOpenSetup(newTicket", EA)
        self.assertIn("g_posState.vwapPullbackBullBonus,g_posState.vwapPullbackBearBonus", EA)
        self.assertIn("g_posState.twinContinuationBullBonus,g_posState.twinContinuationBearBonus", EA)

    def test_restart_restores_attribution_for_live_positions(self):
        self.assertIn("FindByPositionIdentifier(g_positionIdentifier,recoveredSetup)", EA)
        self.assertIn("g_posState.overnightBiasBullBonus=recoveredSetup.overnightBiasBullBonus", EA)

    def test_offline_close_recovery_preserves_attribution(self):
        self.assertIn("rec.vwapPullbackBullBonus=haveSetup ? setup.vwapPullbackBullBonus", EA)
        self.assertIn("rec.twinContinuationBearBonus=haveSetup ? setup.twinContinuationBearBonus", EA)

    def test_attribution_is_not_reconstructed_when_registry_is_missing(self):
        self.assertIn("haveSetup ? setup.vwapPullbackBullBonus : 0.0", EA)
        self.assertIn("haveSetup ? setup.twinContinuationBullBonus : 0.0", EA)


if __name__ == "__main__":
    unittest.main(verbosity=2)
