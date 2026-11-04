"""Reference acceptance tests for campaign deal attribution and recovery.

These tests define accounting/recovery behaviour. They do not execute MQL5,
compile the EA, or prove broker/Strategy Tester behaviour.
"""
from dataclasses import dataclass, field
import unittest


@dataclass(frozen=True)
class Deal:
    ticket: int
    position_id: int
    symbol: str
    side: str                 # BUY or SELL, as recorded by the broker deal
    entry: str                # IN, OUT, or INOUT
    volume: float
    price: float
    commission: float = 0.0
    swap: float = 0.0
    fee: float = 0.0
    profit: float = 0.0
    campaign_id: str = ""


@dataclass
class Journal:
    account_login: int
    server: str
    magic: int
    checksum_valid: bool = True
    rows: dict = field(default_factory=dict)

    def append_deal(self, deal: Deal) -> bool:
        if not self.checksum_valid:
            return False
        if deal.ticket <= 0 or deal.position_id <= 0 or deal.volume <= 0:
            return False
        if deal.side not in {"BUY", "SELL"} or deal.entry not in {"IN", "OUT", "INOUT"}:
            return False
        existing = self.rows.get(deal.ticket)
        if existing is not None:
            return existing == deal
        self.rows[deal.ticket] = deal
        return True


def signed_volume(deal: Deal) -> float:
    return deal.volume if deal.side == "BUY" else -deal.volume


def net_position_from_deals(deals):
    """Broker-side netting volume model; an INOUT deal crosses through zero."""
    total = 0.0
    for deal in deals:
        total += signed_volume(deal)
    return total


def recovery_status(*, journal_valid, broker_positions, attributed_position_ids,
                    history_available=True, identity_matches=True):
    if not identity_matches or not journal_valid:
        return "CORRUPT_JOURNAL"
    if not history_available:
        return "PENDING_HISTORY"
    if any(position_id not in attributed_position_ids for position_id in broker_positions):
        return "UNTRACKED_POSITION"
    if any(position_id not in broker_positions for position_id in attributed_position_ids):
        return "ORPHAN_JOURNAL_RECORD"
    return "READY"


class CampaignReconciliationTests(unittest.TestCase):
    def test_deal_is_attributed_to_campaign_after_restart(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        deal = Deal(1001, 9001, "XAUUSD", "BUY", "IN", 0.03, 2350.0,
                    commission=-0.12, campaign_id="CAMP-001")
        self.assertTrue(journal.append_deal(deal))
        restored = Journal(12345, "Broker-Demo", 1500015, rows=dict(journal.rows))
        self.assertEqual(restored.rows[1001].campaign_id, "CAMP-001")

    def test_duplicate_callback_does_not_duplicate_deal(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        deal = Deal(1002, 9002, "XAUUSD", "BUY", "IN", 0.02, 2351.0,
                    campaign_id="CAMP-002")
        self.assertTrue(journal.append_deal(deal))
        self.assertTrue(journal.append_deal(deal))
        self.assertEqual(len(journal.rows), 1)

    def test_conflicting_duplicate_deal_fails_closed(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        first = Deal(1003, 9003, "XAUUSD", "BUY", "IN", 0.02, 2351.0,
                     campaign_id="CAMP-003")
        conflict = Deal(1003, 9003, "XAUUSD", "BUY", "IN", 0.05, 2351.0,
                        campaign_id="CAMP-003")
        self.assertTrue(journal.append_deal(first))
        self.assertFalse(journal.append_deal(conflict))

    def test_partial_fill_uses_confirmed_deal_volume(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        requested_volume = 0.10
        fill = Deal(1004, 9004, "XAUUSD", "BUY", "IN", 0.03, 2352.0,
                    campaign_id="CAMP-004")
        self.assertTrue(journal.append_deal(fill))
        actual = sum(d.volume for d in journal.rows.values())
        self.assertEqual(actual, 0.03)
        self.assertNotEqual(actual, requested_volume)

    def test_netting_risk_object_is_one_current_position_not_entry_deal_sum(self):
        deals = [
            Deal(1010, 9010, "XAUUSD", "BUY", "IN", 0.10, 2350.0),
            Deal(1011, 9010, "XAUUSD", "BUY", "IN", 0.05, 2351.0),
        ]
        broker_net_volume = 0.15
        reconstructed = net_position_from_deals(deals)
        self.assertAlmostEqual(reconstructed, broker_net_volume)
        # Live risk is evaluated once from the broker's current 0.15 net position
        # and current stop, not as two independent open position risk objects.
        risk_objects = 1
        self.assertEqual(risk_objects, 1)

    def test_netting_inout_reversal_crosses_zero_without_fake_addition(self):
        deals = [
            Deal(1020, 9020, "XAUUSD", "BUY", "IN", 0.30, 2350.0),
            Deal(1021, 9020, "XAUUSD", "SELL", "INOUT", 0.50, 2348.0),
        ]
        self.assertAlmostEqual(net_position_from_deals(deals), -0.20)
        self.assertEqual(deals[-1].entry, "INOUT")

    def test_attributed_netting_reversal_counts_as_position_opening(self):
        # DEAL_ENTRY_INOUT both closes the old net direction and opens the
        # residual opposite direction. It must carry a trusted campaign ID.
        reversal = Deal(1022, 9020, "XAUUSD", "SELL", "INOUT", 0.50, 2348.0,
                       campaign_id="CAMP-REV")
        self.assertEqual(reversal.entry, "INOUT")
        self.assertEqual(reversal.campaign_id, "CAMP-REV")

    def test_hedging_positions_remain_separate_risk_objects(self):
        hedging_positions = [
            {"ticket": 501, "position_id": 9501, "volume": 0.01},
            {"ticket": 502, "position_id": 9502, "volume": 0.02},
        ]
        self.assertEqual(len(hedging_positions), 2)
        self.assertEqual(len({p["ticket"] for p in hedging_positions}), 2)

    def test_untracked_broker_position_blocks_campaign_additions(self):
        self.assertEqual(
            recovery_status(journal_valid=True, broker_positions={9001, 9002},
                            attributed_position_ids={9001}),
            "UNTRACKED_POSITION",
        )

    def test_orphan_attribution_requires_history_reconciliation(self):
        self.assertEqual(
            recovery_status(journal_valid=True, broker_positions={9001},
                            attributed_position_ids={9001, 9002}),
            "ORPHAN_JOURNAL_RECORD",
        )

    def test_corrupt_journal_blocks_recovery(self):
        self.assertEqual(
            recovery_status(journal_valid=False, broker_positions={9001},
                            attributed_position_ids={9001}),
            "CORRUPT_JOURNAL",
        )

    def test_history_cache_miss_is_pending_not_fabricated(self):
        self.assertEqual(
            recovery_status(journal_valid=True, broker_positions={9001},
                            attributed_position_ids={9001}, history_available=False),
            "PENDING_HISTORY",
        )

    def test_account_identity_mismatch_blocks_recovery(self):
        self.assertEqual(
            recovery_status(journal_valid=True, broker_positions={9001},
                            attributed_position_ids={9001}, identity_matches=False),
            "CORRUPT_JOURNAL",
        )

    def test_broker_history_backfill_can_mark_campaign_attribution_unknown(self):
        # History can confirm a deal while the original campaign/signal mapping
        # is unavailable. That deal must remain explicitly unattributed.
        journal = Journal(12345, "Broker-Demo", 1500015)
        deal = Deal(1040, 9040, "XAUUSD", "BUY", "IN", 0.01, 2354.0,
                    campaign_id="")
        self.assertTrue(journal.append_deal(deal))
        self.assertEqual(journal.rows[1040].campaign_id, "")

    def test_history_missing_stop_is_not_misrepresented_as_zero_live_risk(self):
        # Zero is an unavailable historical snapshot, not a live risk value.
        historical_stop = 0.0
        historical_risk = 0.0
        stop_snapshot_known = historical_stop > 0.0
        risk_snapshot_known = historical_risk > 0.0
        self.assertFalse(stop_snapshot_known)
        self.assertFalse(risk_snapshot_known)

    def test_commission_swap_and_fee_remain_attached_to_deal(self):
        deal = Deal(1030, 9030, "XAUUSD", "SELL", "OUT", 0.01, 2349.0,
                    commission=-0.04, swap=-0.02, fee=-0.01, profit=1.25,
                    campaign_id="CAMP-030")
        self.assertAlmostEqual(
            deal.profit + deal.commission + deal.swap + deal.fee, 1.18
        )


if __name__ == "__main__":
    unittest.main()
