"""Reference decision tests for interrupted partial-close recovery.

These fixtures validate the deal-volume/journal-cursor policy. They do not execute
MQL5 or simulate MT5 broker history. Source-contract checks bind the EA to the same
decision boundaries; MetaEditor and Strategy Tester remain separate requirements.
"""
from dataclasses import dataclass
import math
import unittest


@dataclass(frozen=True)
class ExitDeal:
    ticket: int
    volume: float


@dataclass(frozen=True)
class RecoveryDecision:
    state: str
    final_slice_volume: float = 0.0


def reconcile_partial_action(
    baseline: float,
    live_volume: float | None,
    registry_cursor: int,
    journal_cursor: int,
    journal_row_partial: bool | None,
    deals: list[ExitDeal],
    step: float = 0.01,
) -> RecoveryDecision:
    """Mirror the EA's fail-closed volume and deal-ticket classification."""
    values = (baseline, step, *(d.volume for d in deals))
    if (not all(math.isfinite(v) for v in values)
            or baseline <= 0 or step <= 0
            or any(d.ticket <= 0 or d.volume <= 0 for d in deals)):
        return RecoveryDecision("QUARANTINE_INVALID_INPUT")
    if len({d.ticket for d in deals}) != len(deals):
        return RecoveryDecision("QUARANTINE_DUPLICATE_DEAL")
    if [d.ticket for d in deals] != sorted(d.ticket for d in deals):
        return RecoveryDecision("QUARANTINE_OUT_OF_ORDER_HISTORY")
    tolerance = max(step * 0.5, 1e-7)
    if registry_cursor > journal_cursor:
        return RecoveryDecision("QUARANTINE_JOURNAL_CURSOR_GAP")

    new_deals = [d for d in deals if d.ticket > registry_cursor]
    journal_advanced = journal_cursor > registry_cursor
    journaled = [d for d in new_deals if d.ticket <= journal_cursor]
    unaccounted = [d for d in new_deals if d.ticket > journal_cursor]
    total_volume = sum(d.volume for d in new_deals)
    journaled_volume = sum(d.volume for d in journaled)
    unaccounted_volume = sum(d.volume for d in unaccounted)
    last_exit_ticket = max((d.ticket for d in new_deals), default=registry_cursor)

    if journal_advanced:
        if (not journaled or journaled[-1].ticket != journal_cursor
                or journal_row_partial is None):
            return RecoveryDecision("QUARANTINE_JOURNAL_HISTORY_MISMATCH")

    if live_volume is None:
        if abs(total_volume - baseline) > tolerance or total_volume <= 0:
            return RecoveryDecision("QUARANTINE_CLOSED_VOLUME_MISMATCH")
        if journal_advanced and journal_row_partial is False:
            if journal_cursor != last_exit_ticket:
                return RecoveryDecision("QUARANTINE_FINAL_CURSOR_MISMATCH")
            return RecoveryDecision("CLEANUP_ALREADY_JOURNALED")
        expected_final = baseline - journaled_volume
        if (unaccounted_volume <= 0
                or abs(unaccounted_volume - expected_final) > tolerance):
            return RecoveryDecision("QUARANTINE_FINAL_SLICE_MISMATCH")
        return RecoveryDecision(
            "RECONSTRUCT_FINAL_SLICE", unaccounted_volume
        )

    if not math.isfinite(live_volume) or live_volume <= 0:
        return RecoveryDecision("QUARANTINE_INVALID_LIVE_VOLUME")
    expected_reduction = baseline - live_volume
    if (expected_reduction <= tolerance
            or abs(expected_reduction - total_volume) > tolerance):
        return RecoveryDecision("QUARANTINE_LIVE_VOLUME_MISMATCH")
    if journal_advanced and journal_row_partial is False:
        return RecoveryDecision("QUARANTINE_FINAL_ROW_WITH_LIVE_POSITION")
    if unaccounted_volume > tolerance:
        return RecoveryDecision("COMMIT_UNACCOUNTED_PARTIAL", unaccounted_volume)
    if journal_advanced and journal_row_partial is True:
        return RecoveryDecision("REPLAY_JOURNAL_FIRST_PARTIAL")
    return RecoveryDecision("COMMIT_UNJOURNALED_PARTIAL", total_volume)


class PartialCloseRecoveryTests(unittest.TestCase):
    def test_unjournaled_partial_with_live_position(self):
        result = reconcile_partial_action(
            1.00, 0.60, 100, 100, None, [ExitDeal(101, 0.40)]
        )
        self.assertEqual(result, RecoveryDecision("COMMIT_UNJOURNALED_PARTIAL", 0.40))

    def test_journal_first_partial_with_live_position(self):
        result = reconcile_partial_action(
            1.00, 0.60, 100, 101, True, [ExitDeal(101, 0.40)]
        )
        self.assertEqual(result, RecoveryDecision("REPLAY_JOURNAL_FIRST_PARTIAL"))

    def test_journal_first_partial_then_final_close_records_only_residual(self):
        result = reconcile_partial_action(
            1.00, None, 100, 101, True,
            [ExitDeal(101, 0.40), ExitDeal(102, 0.60)],
        )
        self.assertEqual(result, RecoveryDecision("RECONSTRUCT_FINAL_SLICE", 0.60))

    def test_unjournaled_full_close_reconstructs_entire_baseline(self):
        result = reconcile_partial_action(
            0.75, None, 200, 200, None, [ExitDeal(201, 0.75)]
        )
        self.assertEqual(result, RecoveryDecision("RECONSTRUCT_FINAL_SLICE", 0.75))

    def test_already_journaled_full_close_only_cleans_stale_state(self):
        result = reconcile_partial_action(
            0.50, None, 300, 301, False, [ExitDeal(301, 0.50)]
        )
        self.assertEqual(result, RecoveryDecision("CLEANUP_ALREADY_JOURNALED"))

    def test_closed_position_with_volume_gap_stays_quarantined(self):
        result = reconcile_partial_action(
            1.00, None, 400, 400, None, [ExitDeal(401, 0.80)]
        )
        self.assertEqual(result.state, "QUARANTINE_CLOSED_VOLUME_MISMATCH")

    def test_registry_cursor_ahead_of_journal_stays_quarantined(self):
        result = reconcile_partial_action(
            1.00, 0.50, 501, 500, None, [ExitDeal(502, 0.50)]
        )
        self.assertEqual(result.state, "QUARANTINE_JOURNAL_CURSOR_GAP")

    def test_unchanged_live_position_does_not_auto_clear_ambiguous_action(self):
        result = reconcile_partial_action(1.00, 1.00, 600, 600, None, [])
        self.assertEqual(result.state, "QUARANTINE_LIVE_VOLUME_MISMATCH")

    def test_out_of_order_history_is_not_replayed(self):
        result = reconcile_partial_action(
            1.00, None, 700, 700, None,
            [ExitDeal(702, 0.50), ExitDeal(701, 0.50)],
        )
        self.assertEqual(result.state, "QUARANTINE_OUT_OF_ORDER_HISTORY")


if __name__ == "__main__":
    unittest.main(verbosity=2)
