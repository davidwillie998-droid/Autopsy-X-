"""Reference tests for the first campaign-continuation policy component.

These tests validate the policy contract, not MQL5 compilation, broker execution,
durable recovery, or live multi-position management.
"""
from dataclasses import dataclass


@dataclass
class Campaign:
    campaign_id: str
    symbol: str
    direction: str
    net_profit: float = 0.0
    last_signal_key: str = ""
    additions: int = 0
    active: bool = True
    thesis_valid: bool = True


def can_add(campaign: Campaign, *, symbol: str, direction: str,
            signal_key: str, net_profit: float, structure_valid: bool,
            momentum_resumed: bool, all_legs_protected: bool) -> bool:
    return bool(
        campaign.active
        and campaign.thesis_valid
        and symbol == campaign.symbol
        and direction == campaign.direction
        and signal_key
        and signal_key != campaign.last_signal_key
        and net_profit > 0.0
        and structure_valid
        and momentum_resumed
        and all_legs_protected
    )


def register_addition(campaign: Campaign, signal_key: str) -> bool:
    if (not campaign.active or not campaign.thesis_valid or not signal_key
            or signal_key == campaign.last_signal_key):
        return False
    campaign.last_signal_key = signal_key
    campaign.additions += 1
    return True


class CampaignContinuationTests(unittest.TestCase):
    def setUp(self):
        self.campaign = Campaign("AX-2026-001", "XAUUSD", "BUY")

    def candidate(self, **overrides):
        values = dict(
            symbol="XAUUSD", direction="BUY", signal_key="M15:2026-11-04T10:15",
            net_profit=12.50, structure_valid=True, momentum_resumed=True,
            all_legs_protected=True,
        )
        values.update(overrides)
        return can_add(self.campaign, **values)

    def test_profitable_fresh_confirmed_continuation_is_eligible(self):
        self.assertTrue(self.candidate())

    def test_losing_or_flat_campaign_cannot_add(self):
        self.assertFalse(self.candidate(net_profit=0.0))
        self.assertFalse(self.candidate(net_profit=-0.01))

    def test_duplicate_signal_cannot_add_twice(self):
        key = "M15:2026-11-04T10:15"
        self.assertTrue(self.candidate(signal_key=key))
        self.assertTrue(register_addition(self.campaign, key))
        self.assertFalse(self.candidate(signal_key=key))
        self.assertFalse(register_addition(self.campaign, key))

    def test_each_new_signal_can_add_without_strategy_count_ceiling(self):
        for index in range(1, 26):
            key = f"M15:continuation:{index}"
            self.assertTrue(self.candidate(signal_key=key))
            self.assertTrue(register_addition(self.campaign, key))
        self.assertEqual(self.campaign.additions, 25)

    def test_wrong_symbol_or_direction_is_rejected(self):
        self.assertFalse(self.candidate(symbol="GBPJPY"))
        self.assertFalse(self.candidate(direction="SELL"))

    def test_invalid_structure_or_momentum_is_rejected(self):
        self.assertFalse(self.candidate(structure_valid=False))
        self.assertFalse(self.candidate(momentum_resumed=False))

    def test_unprotected_leg_blocks_addition(self):
        self.assertFalse(self.candidate(all_legs_protected=False))

    def test_inactive_or_invalidated_campaign_cannot_add(self):
        self.campaign.active = False
        self.assertFalse(self.candidate())
        self.campaign.active = True
        self.campaign.thesis_valid = False
        self.assertFalse(self.candidate())


if __name__ == "__main__":
    unittest.main()
