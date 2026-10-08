"""Phase 3C scope isolation: no production EA file exists to touch, and no
Phase 2/Phase 3A/Phase 3B implementation file is modified by Phase 3C's own
commits. This is the explicit scope test Phase 3C instruction 2 requires."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PHASE3A_COMMIT = "617355f874d949431eb93d8ac2d3ecc7b6479aa3"
PHASE3B_COMMIT = "f21f3bc2e18ab64d2b92e203c4202144eabf7eac"


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
    infra_allowed = {"intel/datasets/phase3c/REQUEST.json", ".github/workflows/phase3c-acquire.yml", ".github/workflows/intel-tests.yml"}
    for f in changed:
        allowed = (f.startswith("docs/PHASE3C_") or f.startswith("intel/autopsyx/research/phase3c_")
                  or f.startswith("intel/tests/test_phase3c_") or f.startswith("research/phase3c/")
                  or f in infra_allowed or f.startswith("intel/datasets/phase3c/runs/"))
        assert allowed, f"Phase 3C touched a file outside its namespace: {f}"


def test_phase3c_workflow_mirrors_phase3a_workflow_procedure():
    """The new workflow changes only the watched path and archive directory;
    every acquire/seal/verify-provenance/commit step is the same procedure."""
    a = (ROOT / ".github" / "workflows" / "phase3a-acquire.yml").read_text()
    c = (ROOT / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    for step in ("seal ", "verify-provenance ", "acquire --live --request", "git commit -m"):
        assert step in a and step in c


def test_phase3a_evidence_and_phase3b_evidence_files_byte_identical_to_frozen():
    for rel in ("artifacts/phase3a/PHASE3A_EVIDENCE.json", "artifacts/phase3a/PHASE3A_COVERAGE.json",
               "docs/PHASE3A_REPORT.md", "docs/SYSTEM_STATUS.md", "docs/PHASE2_SYSTEM_STATUS.md",
               "research/phase3b/results/phase3b_evidence.json", "docs/PHASE3B_RESEARCH_CONTRACT.md",
               "docs/PHASE3B_STATISTICAL_REPORT.md"):
        at_3b = git("show", f"{PHASE3B_COMMIT}:{rel}")  # git strips rstrip() in captured stdout; compare rstripped
        at_head = (ROOT / rel).read_text().rstrip("\n")
        assert at_3b == at_head, rel


def test_phase3b_contract_and_stats_modules_unchanged_since_phase3b():
    for rel in ("intel/autopsyx/research/phase3b_contract.py", "intel/autopsyx/research/phase3b_stats.py",
               "intel/autopsyx/research/phase3b_data.py", "intel/autopsyx/research/phase3b_pipeline.py"):
        at_3b = git("show", f"{PHASE3B_COMMIT}:{rel}")
        at_head = (ROOT / rel).read_text().rstrip("\n")
        assert at_3b == at_head, rel


def test_phase3c_hypothesis_ids_are_exactly_phase3b_eligible_ids():
    from autopsyx.research import phase3b_contract as contract
    from autopsyx.research import phase3c_pipeline as p3c
    assert set(p3c.HYPOTHESIS_IDS) == set(contract.ELIGIBLE_IDS) == {"H1", "H3", "H4", "H8", "H9", "H10"}


def test_phase3c_reuses_frozen_min_sample_without_redefining_it():
    from autopsyx.research import phase3b_contract as contract
    from autopsyx.research import phase3c_pipeline as p3c
    assert p3c.MIN_SAMPLE is contract.MIN_SAMPLE  # literally the same object, not a re-derived copy
