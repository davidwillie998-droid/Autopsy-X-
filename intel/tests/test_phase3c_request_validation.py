from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from validate_phase3c_request import validate_request


def request(**overrides):
    data = {
        "run_id": "p3c-sol-test01",
        "network": "solana",
        "phase3a": True,
        "strata": {"young": 8, "quiet_young": 4, "trending": 4, "established": 4},
        "duration_s": 7200,
        "cycle_s": 60,
        "new_pool_pages": 3,
        "backfill_pages": 2,
        "rpc_page_limit": 100,
        "rpc_max_pages": 1,
        "rpc_max_txs": 8,
    }
    data.update(overrides)
    return data


class Phase3CRequestValidationTests(unittest.TestCase):
    def test_valid_request_at_twenty_tokens_passes(self):
        self.assertEqual(validate_request(request()), [])

    def test_under_sized_strata_is_rejected(self):
        errors = validate_request(request(strata={
            "young": 2, "quiet_young": 1, "trending": 1, "established": 1
        }))
        self.assertTrue(any("requires at least 20" in e for e in errors))

    def test_missing_and_extra_strata_are_rejected(self):
        errors = validate_request(request(strata={
            "young": 10, "quiet_young": 5, "trending": 5, "unexpected": 1
        }))
        self.assertTrue(any("missing required keys" in e for e in errors))
        self.assertTrue(any("unknown keys" in e for e in errors))

    def test_boolean_and_negative_targets_are_rejected(self):
        errors = validate_request(request(strata={
            "young": True, "quiet_young": 8, "trending": 8, "established": -1
        }))
        self.assertTrue(any("non-negative integer" in e for e in errors))

    def test_non_solana_or_disabled_enrichment_is_rejected(self):
        self.assertTrue(validate_request(request(network="ethereum")))
        self.assertTrue(validate_request(request(phase3a=False)))

    def test_invalid_run_id_and_zero_budget_are_rejected(self):
        errors = validate_request(request(run_id="../unsafe", duration_s=0))
        self.assertTrue(any("run_id" in e for e in errors))
        self.assertTrue(any("duration_s" in e for e in errors))

    def test_non_object_is_rejected_without_crashing(self):
        self.assertTrue(validate_request(["not", "an", "object"]))


if __name__ == "__main__":
    unittest.main()
