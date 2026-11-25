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
        self.assertIn("for(int ticketIndex=0;ticketIndex<m_count;ticketIndex++)", REGISTRY)
        self.assertIn("m_records[ticketIndex].ticket==ticket && ticketIndex!=index", REGISTRY)
        self.assertIn('BROKER_TICKET_OWNERSHIP_CONFLICT', REGISTRY)
        self.assertIn("for(int duplicateIndex=0;duplicateIndex<m_count;duplicateIndex++)", REGISTRY)

    def test_ticket_refresh_for_same_identifier_remains_supported(self):
        self.assertIn("candidate.positionIdentifier=id; candidate.ticket=ticket;", REGISTRY)
        self.assertIn("candidate.symbol=symbol; candidate.magic=magic; candidate.state=state;", REGISTRY)
        self.assertIn("SAxPositionLifecycleRecord previous=m_records[index];", REGISTRY)
        self.assertIn("m_records[index]=candidate;", REGISTRY)
        self.assertIn("m_records[index]=previous;", REGISTRY)

    def test_identity_ownership_conflict_still_fails_closed(self):
        self.assertIn('POSITION_IDENTITY_OWNERSHIP_CONFLICT', REGISTRY)
        self.assertIn('INVALID_POSITION_STATE_RECORD', REGISTRY)


if __name__ == "__main__":
    unittest.main(verbosity=2)
