"""Deterministic reference tests for strongest qualified candidate selection.

These tests validate ranking policy and source contracts, not MQL5 runtime behavior.
"""
from dataclasses import dataclass
from pathlib import Path
import math
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "MQL5/Include/AutopsyX/OpportunityScanner.mqh"


@dataclass(frozen=True)
class Candidate:
    symbol: str
    direction: str
    score: float
    confidence: float
    spread: float
    timestamp: int
    qualified: bool = True


def usable(c, now, min_score=60.0, min_confidence=0.0, max_age=10):
    return (
        c.qualified and bool(c.symbol) and c.direction in {"BUY", "SELL"}
        and math.isfinite(c.score) and c.score >= min_score
        and math.isfinite(c.confidence) and c.confidence >= min_confidence
        and math.isfinite(c.spread) and c.spread >= 0
        and 0 <= now - c.timestamp <= max_age
    )


def rank(candidates, now, limit=5):
    accepted = {}
    for c in candidates:
        if not usable(c, now):
            continue
        accepted[c.symbol] = c
    ordered = sorted(
        accepted.values(),
        key=lambda c: (-c.score, -c.confidence, c.spread, c.symbol),
    )
    return ordered[:max(1, min(5, limit))]


class OpportunityScannerReferenceTests(unittest.TestCase):
    def test_selects_one_highest_scoring_qualified_candidate(self):
        candidates = [
            Candidate("XAUUSD", "BUY", 78, 80, 12, 100),
            Candidate("GBPJPY", "SELL", 84, 74, 18, 100),
            Candidate("EURUSD", "BUY", 72, 95, 8, 100),
        ]
        self.assertEqual(rank(candidates, 101)[0].symbol, "GBPJPY")

    def test_unqualified_candidate_never_wins(self):
        candidates = [
            Candidate("XAUUSD", "BUY", 99, 99, 1, 100, qualified=False),
            Candidate("GBPJPY", "SELL", 70, 70, 5, 100),
        ]
        self.assertEqual(rank(candidates, 100)[0].symbol, "GBPJPY")

    def test_stale_and_future_signals_are_rejected(self):
        candidates = [
            Candidate("STALE", "BUY", 99, 99, 1, 80),
            Candidate("FUTURE", "SELL", 99, 99, 1, 102),
            Candidate("FRESH", "BUY", 65, 60, 4, 100),
        ]
        self.assertEqual([c.symbol for c in rank(candidates, 101)], ["FRESH"])

    def test_invalid_numeric_data_is_rejected(self):
        candidates = [
            Candidate("NAN", "BUY", float("nan"), 99, 1, 100),
            Candidate("BADSPREAD", "SELL", 90, 90, -1, 100),
            Candidate("VALID", "SELL", 61, 60, 3, 100),
        ]
        self.assertEqual([c.symbol for c in rank(candidates, 100)], ["VALID"])

    def test_shortlist_never_exceeds_five(self):
        candidates = [
            Candidate(f"SYM{i}", "BUY", 60 + i, 60, 2, 100)
            for i in range(12)
        ]
        selected = rank(candidates, 100, limit=99)
        self.assertEqual(len(selected), 5)
        self.assertEqual(selected[0].symbol, "SYM11")

    def test_ties_are_resolved_deterministically(self):
        candidates = [
            Candidate("ZETA", "BUY", 80, 80, 5, 100),
            Candidate("ALPHA", "SELL", 80, 80, 5, 100),
            Candidate("BETA", "BUY", 80, 80, 4, 100),
        ]
        self.assertEqual(rank(candidates, 100)[0].symbol, "BETA")
        self.assertEqual(rank(candidates, 100)[1].symbol, "ALPHA")

    def test_source_exposes_qualification_and_single_winner_contract(self):
        source = SCANNER.read_text(encoding="utf-8")
        self.assertIn("AX_MAX_OPPORTUNITY_CANDIDATES 5", source)
        self.assertIn("SubmitQualifiedCandidate", source)
        self.assertIn("candidate.qualified", source)
        self.assertIn("IsFresh(candidate,now)", source)
        self.assertIn("SelectStrongest", source)
        self.assertIn("m_candidates[strongest]", source)
        self.assertIn("m_maxCandidates=(int)MathMax(1,MathMin(AX_MAX_OPPORTUNITY_CANDIDATES,maxCandidates))", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
