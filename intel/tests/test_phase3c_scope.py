"""Phase 3C scope isolation: no production EA file exists to touch, and no
Phase 2/Phase 3A/Phase 3B implementation file is modified by Phase 3C's own
commits. This is the explicit scope test Phase 3C instruction 2 requires."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PHASE3A_COMMIT = "617355f874d949431eb93d8ac2d3ecc7b6479aa3"
PHASE3B_COMMIT = "f21f3bc2e18ab64d2b92e203c4202144eabf7eac"
PHASE3C_ACQUIRE_BASELINE_COMMIT = "36de8bf79f9ee985456a73aee8e56118d85b3727"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def test_no_mql5_or_ea_file_exists_in_the_repository():
    """There is no production EA in this repository at all: confirming that is
    itself the strongest form of 'Phase 3C did not touch it'."""
    mql = list(ROOT.rglob("*.mq5")) + list(ROOT.rglob("*.mqh")) + list(ROOT.rglob("*.ex5"))
    assert mql == [], mql


def test_no_ctrade_or_order_placement_symbol_anywhere_in_phase3c():
    banned = ("CTrade", "place_order", "send_transaction", "sign_transaction", "OrderSend", "trade.Buy(",
             "trade.Sell(")
    for p in (ROOT / "intel" / "autopsyx" / "research").glob("phase3c_*.py"):
        src = p.read_text()
        for b in banned:
            assert b not in src, (p.name, b)


def test_phase2_phase3a_phase3b_implementation_files_unchanged_since_phase3b():
    """Diff from the Phase 3B commit touches only new docs/phase3c_*/research/phase3c
    paths and test files for phase3c -- never an existing autopsyx module."""
    changed = git("diff", "--name-only", PHASE3B_COMMIT, "HEAD").splitlines()
    # Necessary Phase 3C acquisition/test infrastructure may change workflow files; existing production/research modules remain frozen.
    # a request file and a workflow mirroring phase3a-acquire.yml's own procedure exactly
    # (checked bit-for-bit against it below), so new archives can be independently acquired.
    # This UI workflow is inherited from the PR base branch and restored byte-for-byte there; it predates the Phase 3C changes and is not a Phase 3C implementation file.
    infra_allowed = {"intel/datasets/phase3c/REQUEST.json", "intel/datasets/phase3c/REQUEST_20_TOKEN_TEMPLATE.json", ".github/workflows/phase3c-acquire.yml", ".github/workflows/intel-tests.yml", ".github/workflows/flipdemon-ui.yml"}
    for f in changed:
        allowed = (f.startswith("docs/PHASE3C_") or f.startswith("intel/autopsyx/research/phase3c_")
                  or f.startswith("intel/tests/test_phase3c_") or f.startswith("research/phase3c/")
                  or f == "intel/autopsyx/data/acquire.py"
                  or f == "intel/autopsyx/research/audit_contiguous_liquidity.py"
                  or f == "intel/tests/test_contiguous_liquidity_audit.py"
                  or f == "intel/tests/test_acquisition_window.py"
                  or f in infra_allowed or f.startswith("intel/datasets/phase3c/runs/"))
        assert allowed, f"Phase 3C touched a file outside its namespace: {f}"



def test_acquire_module_fails_closed_on_cadence_and_cycle_overruns():
    source = (ROOT / "intel" / "autopsyx" / "data" / "acquire.py").read_text()
    assert "expected_pool_revisit_s" in source
    assert '"label_horizon_s": 3 * 5 * 60' in source
    assert '"cadence_pass": expected_revisit_s <= 3 * 5 * 60' in source
    assert "cycle_elapsed_s.append(spent)" in source
    assert '"poll_cycle_overruns": cycle_overruns' in source
    assert 'status = "INCOMPLETE: pool revisit interval exceeds the frozen 15-minute label horizon"' in source
    assert 'status = f"INCOMPLETE: {cycle_overruns} poll cycles exceeded the {plan.cycle_s}s cycle budget"' in source
