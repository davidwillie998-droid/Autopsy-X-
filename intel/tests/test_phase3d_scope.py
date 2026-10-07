"""Phase 3D scope and safety gates."""

from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]

PHASE3C1_COMMIT = "796426ef21181612e763b12d272b542024e08706"
FORBIDDEN = ("CTrade", "OrderSend", "place_order", "sign_transaction", "wallet", "trade.Buy(", "trade.Sell(")


def test_phase3d_request_is_frozen_and_validation_only():
    req = json.loads((ROOT / "intel" / "datasets" / "phase3d" / "REQUEST.json").read_text())
    assert req["hypothesis_ids"] == ["H10"]
    assert req["min_distinct_tokens"] == 85
    assert req["required_independent_windows"] >= 2
    assert req["horizon_steps"] == 3
    assert req["production_integration"] is False
    assert req["wallet_signing"] is False
    assert req["order_placement"] is False


def test_phase3d_protocol_contains_hard_validation_gates():
    src = (ROOT / "docs" / "PHASE3D_VALIDATION_PROTOCOL.md").read_text()
    for phrase in (
        "85 distinct tokens",
        "At least two independent acquisition windows",
        "chronological out-of-sample",
        "no token overlap",
        "Production Boundary",
    ):
        assert phrase in src


def test_phase3d_has_no_execution_surface():
    for p in (ROOT / "intel" / "autopsyx").rglob("phase3d*.py"):
        src = p.read_text()
        for banned in FORBIDDEN:
            assert banned.lower() not in src.lower(), (p, banned)


def test_phase3d_does_not_modify_frozen_phase3c1_implementation():
    import subprocess
    changed = subprocess.run(
        ["git", "diff", "--name-only", PHASE3C1_COMMIT, "HEAD"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    for f in changed:
        allowed = (
            f.startswith("docs/PHASE3D_")
            or f.startswith("intel/datasets/phase3d/")
            or f.startswith("intel/tests/test_phase3d_")
            or f.startswith(".github/workflows/phase3d-")
            or f == ".github/workflows/intel-tests.yml"
            or f == "intel/tests/test_phase3c_scope.py"
        )
        assert allowed, f"Phase 3D touched an unexpected path: {f}"
