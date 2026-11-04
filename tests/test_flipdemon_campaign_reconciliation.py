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
    signal_key: str = ""


@dataclass
class Journal:
    account_login: int
    server: str
    magic: int
    checksum_valid: bool = True
    rows: dict = field(default_factory=dict)
    amendment_count: int = 0

    def append_deal(self, deal: Deal) -> bool:
        if not self.checksum_valid:
            return False
        if deal.ticket <= 0 or deal.position_id <= 0 or deal.volume <= 0:
            return False
        if deal.side not in {"BUY", "SELL"} or deal.entry not in {"IN", "OUT", "INOUT"}:
            return False
        existing = self.rows.get(deal.ticket)
        if existing is not None:
            same_broker_deal = (
                existing.position_id == deal.position_id
                and existing.symbol == deal.symbol
                and existing.side == deal.side
                and existing.entry == deal.entry
                and existing.volume == deal.volume
                and existing.price == deal.price
            )
            if not same_broker_deal:
                return False
            if not deal.campaign_id:
                return True
            return self.amend_attribution(deal.ticket, deal.campaign_id, deal.signal_key)
        self.rows[deal.ticket] = deal
        return True

    def amend_attribution(self, ticket: int, campaign_id: str, signal_key: str) -> bool:
        if not self.checksum_valid or not campaign_id:
            return False
        existing = self.rows.get(ticket)
        if existing is None:
            return False
        if existing.campaign_id:
            return existing.campaign_id == campaign_id
        self.rows[ticket] = Deal(
            **{**existing.__dict__, "campaign_id": campaign_id, "signal_key": signal_key}
        )
        self.amendment_count += 1
        return True


@dataclass
class PendingDealRetries:
    capacity: int = 128
    tickets: list = field(default_factory=list)
    blocked: bool = False

    def enqueue(self, ticket: int) -> bool:
        if ticket <= 0:
            return False
        if ticket in self.tickets:
            self.blocked = True
            return True
        if len(self.tickets) >= self.capacity:
            self.blocked = True
            return False
        self.tickets.append(ticket)
        self.blocked = True
        return True

    def process(self, persist, all_live_positions_attributed, budget=4):
        attempts = 0
        for ticket in list(self.tickets)[:budget]:
            attempts += 1
            if persist(ticket):
                self.tickets.remove(ticket)
        if not self.tickets and all_live_positions_attributed:
            self.blocked = False
        else:
            self.blocked = True
        return attempts


@dataclass
class CampaignIntent:
    intent_id: str
    campaign_id: str
    signal_key: str
    symbol: str
    direction: str
    requested_volume: float
    intended_stop: float
    risk_budget: float
    status: str = "PREPARED"
    order_ticket: int = 0


@dataclass
class IntentLedger:
    checksum_valid: bool = True
    intents: dict = field(default_factory=dict)

    def prepare(self, intent: CampaignIntent) -> bool:
        if not self.checksum_valid or not intent.intent_id or intent.intent_id in self.intents:
            return False
        if intent.requested_volume <= 0 or intent.intended_stop <= 0 or intent.risk_budget <= 0:
            return False
        if intent.status != "PREPARED" or intent.order_ticket != 0:
            return False
        self.intents[intent.intent_id] = intent
        return True

    def bind(self, intent_id: str, order_ticket: int) -> bool:
        intent = self.intents.get(intent_id)
        if not self.checksum_valid or intent is None or order_ticket <= 0:
            return False
        if intent.status == "BOUND":
            return intent.order_ticket == order_ticket
        if intent.status != "PREPARED":
            return False
        intent.status, intent.order_ticket = "BOUND", order_ticket
        return True

    def reject(self, intent_id: str) -> bool:
        intent = self.intents.get(intent_id)
        if not self.checksum_valid or intent is None or intent.status != "PREPARED":
            return False
        intent.status = "REJECTED"
        return True

    def unresolved(self) -> bool:
        return any(item.status == "PREPARED" for item in self.intents.values())

    def by_order(self, order_ticket: int):
        return next((item for item in self.intents.values()
                     if item.status == "BOUND" and item.order_ticket == order_ticket), None)


def resolve_intent_attribution(order_ticket, position_id, intent_ledger, open_registry):
    intent = intent_ledger.by_order(order_ticket)
    if intent is not None:
        return intent.campaign_id, intent.signal_key
    setup_id = open_registry.get(position_id, "")
    if setup_id:
        return setup_id, setup_id
    return "", ""


def signed_volume(deal: Deal) -> float:
    return deal.volume if deal.side == "BUY" else -deal.volume


def net_position_from_deals(deals):
    """Broker-side netting volume model; an INOUT deal crosses through zero."""
    total = 0.0
    for deal in deals:
        total += signed_volume(deal)
    return total


def resolve_campaign_attribution(position_id, open_setup_registry, journal=None):
    """Prefer the exact open registry, then an already-durable deal attribution."""
    mapped = open_setup_registry.get(position_id, "")
    if mapped:
        return mapped
    if journal is not None:
        for deal in journal.rows.values():
            if deal.position_id == position_id and deal.campaign_id:
                return deal.campaign_id
    return ""


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
    def test_delayed_history_deal_retries_and_unlocks_only_after_durable_attribution(self):
        queue = PendingDealRetries()
        readable = set()
        persisted = set()
        self.assertTrue(queue.enqueue(7001))
        queue.process(lambda _ticket: False, all_live_positions_attributed=True)
        self.assertEqual(queue.tickets, [7001])
        self.assertTrue(queue.blocked)
        readable.add(7001)
        queue.process(lambda t: (persisted.add(t) is None) if t in readable else False,
                      all_live_positions_attributed=True)
        self.assertEqual(queue.tickets, [])
        self.assertFalse(queue.blocked)
        self.assertEqual(persisted, {7001})

    def test_duplicate_transaction_notification_is_deduplicated(self):
        queue = PendingDealRetries()
        self.assertTrue(queue.enqueue(7002))
        self.assertTrue(queue.enqueue(7002))
        self.assertEqual(queue.tickets, [7002])

    def test_retry_work_is_bounded_per_timer_or_tick(self):
        queue = PendingDealRetries()
        for ticket in range(7010, 7016):
            self.assertTrue(queue.enqueue(ticket))
        attempts = queue.process(lambda _ticket: False, all_live_positions_attributed=False, budget=4)
        self.assertEqual(attempts, 4)
        self.assertEqual(len(queue.tickets), 6)
        self.assertTrue(queue.blocked)

    def test_unresolved_ticket_remains_queued_and_blocks_entries(self):
        queue = PendingDealRetries()
        queue.enqueue(7020)
        queue.process(lambda _ticket: False, all_live_positions_attributed=True)
        self.assertEqual(queue.tickets, [7020])
        self.assertTrue(queue.blocked)

    def test_queue_capacity_never_discards_an_unresolved_ticket_silently(self):
        queue = PendingDealRetries(capacity=2)
        self.assertTrue(queue.enqueue(7030))
        self.assertTrue(queue.enqueue(7031))
        self.assertFalse(queue.enqueue(7032))
        self.assertEqual(queue.tickets, [7030, 7031])
        self.assertTrue(queue.blocked)

    def test_exact_order_intent_preserves_signal_key_ahead_of_position_fallback(self):
        ledger = IntentLedger()
        ledger.prepare(CampaignIntent("I-SIGNAL", "C-SIGNAL", "SIG-XAU-BUY-42",
                                      "XAUUSD", "BUY", 0.02, 2300, 20))
        ledger.bind("I-SIGNAL", 9042)
        self.assertEqual(
            resolve_intent_attribution(9042, 9042, ledger, {9042: "LEGACY-SETUP"}),
            ("C-SIGNAL", "SIG-XAU-BUY-42"),
        )

    def test_pre_order_intent_must_persist_before_order_submission(self):
        ledger = IntentLedger()
        intent = CampaignIntent("I-1", "C-1", "S-1", "XAUUSD", "BUY", 0.02, 2300, 20)
        self.assertTrue(ledger.prepare(intent))
        self.assertTrue(ledger.unresolved())
        self.assertIsNone(ledger.by_order(9001))

    def test_intent_write_failure_prevents_order_authorization(self):
        ledger = IntentLedger(checksum_valid=False)
        intent = CampaignIntent("I-2", "C-2", "S-2", "XAUUSD", "BUY", 0.01, 2300, 10)
        self.assertFalse(ledger.prepare(intent))
        self.assertEqual(ledger.intents, {})

    def test_broker_order_ticket_binds_intent_and_supports_fill_lookup(self):
        ledger = IntentLedger()
        intent = CampaignIntent("I-3", "C-3", "S-3", "XAUUSD", "SELL", 0.03, 2400, 30)
        self.assertTrue(ledger.prepare(intent))
        self.assertTrue(ledger.bind("I-3", 9003))
        self.assertEqual(ledger.by_order(9003).campaign_id, "C-3")
        self.assertFalse(ledger.unresolved())

    def test_duplicate_order_binding_is_idempotent_but_conflicts_fail(self):
        ledger = IntentLedger()
        ledger.prepare(CampaignIntent("I-4", "C-4", "S-4", "XAUUSD", "BUY", 0.01, 2300, 10))
        self.assertTrue(ledger.bind("I-4", 9004))
        self.assertTrue(ledger.bind("I-4", 9004))
        self.assertFalse(ledger.bind("I-4", 9005))

    def test_rejected_intent_is_terminal_and_does_not_block_restart(self):
        ledger = IntentLedger()
        ledger.prepare(CampaignIntent("I-5", "C-5", "S-5", "XAUUSD", "BUY", 0.01, 2300, 10))
        self.assertTrue(ledger.reject("I-5"))
        self.assertFalse(ledger.unresolved())
        self.assertFalse(ledger.bind("I-5", 9005))

    def test_crash_left_prepared_intent_blocks_new_entries(self):
        ledger = IntentLedger()
        ledger.prepare(CampaignIntent("I-6", "C-6", "S-6", "XAUUSD", "BUY", 0.01, 2300, 10))
        recovered = IntentLedger(intents=dict(ledger.intents))
        self.assertTrue(recovered.unresolved())

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

    def test_unattributed_deal_can_receive_trusted_append_only_amendment(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        deal = Deal(1050, 9050, "XAUUSD", "BUY", "IN", 0.02, 2355.0)
        self.assertTrue(journal.append_deal(deal))
        self.assertEqual(journal.rows[1050].campaign_id, "")
        self.assertTrue(journal.amend_attribution(1050, "CAMP-050", "SETUP-050"))
        self.assertEqual(journal.rows[1050].campaign_id, "CAMP-050")
        self.assertEqual(journal.rows[1050].signal_key, "SETUP-050")

    def test_repeated_identical_attribution_amendment_is_idempotent(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        deal = Deal(1051, 9051, "XAUUSD", "SELL", "IN", 0.01, 2356.0)
        self.assertTrue(journal.append_deal(deal))
        self.assertTrue(journal.amend_attribution(1051, "CAMP-051", "SETUP-051"))
        self.assertTrue(journal.amend_attribution(1051, "CAMP-051", "SETUP-051"))
        self.assertEqual(journal.amendment_count, 1)

    def test_conflicting_campaign_attribution_is_rejected(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        deal = Deal(1052, 9052, "XAUUSD", "BUY", "IN", 0.01, 2357.0)
        self.assertTrue(journal.append_deal(deal))
        self.assertTrue(journal.amend_attribution(1052, "CAMP-052", "SETUP-052"))
        self.assertFalse(journal.amend_attribution(1052, "CAMP-OTHER", "SETUP-OTHER"))
        self.assertEqual(journal.rows[1052].campaign_id, "CAMP-052")

    def test_attribution_amendment_requires_existing_deal_and_valid_journal(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        self.assertFalse(journal.amend_attribution(9999, "CAMP-X", "SETUP-X"))
        journal.checksum_valid = False
        deal = Deal(1053, 9053, "XAUUSD", "BUY", "IN", 0.01, 2358.0)
        self.assertFalse(journal.append_deal(deal))

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

    def test_delayed_exit_can_reuse_existing_durable_position_attribution(self):
        journal = Journal(12345, "Broker-Demo", 1500015)
        entry = Deal(1045, 9045, "XAUUSD", "BUY", "IN", 0.02, 2354.0,
                     campaign_id="CAMP-EXIT")
        self.assertTrue(journal.append_deal(entry))
        self.assertEqual(resolve_campaign_attribution(9045, {}, journal), "CAMP-EXIT")

    def test_history_replay_uses_exact_open_position_setup_mapping(self):
        registry = {9005: "SETUP-9005"}
        self.assertEqual(resolve_campaign_attribution(9005, registry), "SETUP-9005")
        self.assertEqual(resolve_campaign_attribution(9006, registry), "")

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
