"""Static contract tests for ticket ownership in PositionStateRegistry.

These tests inspect source invariants. They do not execute MQL5 or broker actions.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = (ROOT / "MQL5/Include/AutopsyX/PositionStateRegistry.mqh").read_text(
    encoding="utf-8-sig"
)


class PositionStateRegistryContractTests(unittest.TestCase):
    def test_stable_position_identifier_is_primary_key(self):
        self.assertIn("FindIndex(const ulong id)", REGISTRY)
        self.assertIn("m_records[i].positionIdentifier==id", REGISTRY)

    def test_broker_ticket_cannot_be_owned_by_two_position_identifiers(self):
        self.assertIn("FindTicketIndex(const ulong ticket)", REGISTRY)
        self.assertIn("int ticketIndex=FindTicketIndex(ticket);", REGISTRY)
        self.assertIn("ticketIndex>=0 && ticketIndex!=index", REGISTRY)
        self.assertIn('BROKER_TICKET_OWNERSHIP_CONFLICT', REGISTRY)

    def test_ticket_refresh_for_same_identifier_remains_supported(self):
        self.assertIn("m_records[index].ticket=ticket;", REGISTRY)
        self.assertIn("m_records[index].state=state;", REGISTRY)

    def test_identity_ownership_conflict_still_fails_closed(self):
        self.assertIn('POSITION_IDENTITY_OWNERSHIP_CONFLICT', REGISTRY)
        self.assertIn('INVALID_POSITION_STATE_RECORD', REGISTRY)


if __name__ == "__main__":
    unittest.main(verbosity=2)
