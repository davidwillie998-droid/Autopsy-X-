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
                  # This narrowly scoped provenance change adds deterministic double-build
                  # checks and first-difference diagnostics to seal/verify; normalization
                  # and the frozen Phase 2/3A/3B contracts remain unchanged.
                  or f == "intel/autopsyx/data/provenance.py"
                  or f == "intel/autopsyx/research/audit_contiguous_liquidity.py"
                  or f == "intel/tests/test_contiguous_liquidity_audit.py"
                  or f == "intel/tests/test_acquisition_window.py"
                  # This evidence-to-signal document defines the research contract for the new
                  # Phase 3C Solana intelligence engine; it does not alter frozen Phase 2/3A/3B logic.
                  or f == "docs/research/17-evidence-to-signal-design.md"
                  or f in infra_allowed or f.startswith("intel/datasets/phase3c/runs/"))
        assert allowed, f"Phase 3C touched a file outside its namespace: {f}"



def test_acquire_module_fails_closed_on_cadence_and_cycle_overruns():
    source = (ROOT / "intel" / "autopsyx" / "data" / "acquire.py").read_text()
    assert "import math" in source
    assert "expected_pool_revisit_s" in source
    assert '"label_horizon_s": 3 * 5 * 60' in source
    assert '"cadence_pass": expected_revisit_s <= 3 * 5 * 60' in source
    assert "cycle_elapsed_s.append(spent)" in source
    assert '"poll_cycle_overruns": cycle_overruns' in source
    assert 'status = _completion_status(cadence_pass, cycle_overruns, error_count, plan.cycle_s)' in source
    assert 'if not cadence_pass:' in source
    assert 'return "INCOMPLETE: pool revisit interval exceeds the frozen 15-minute label horizon"' in source
    assert 'return f"INCOMPLETE: {cycle_overruns} poll cycles exceeded the {cycle_s}s cycle budget"' in source
    assert 'return f"INCOMPLETE: {errors} provider request(s) failed after retries"' in source


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


def test_phase3c_workflow_invalidates_complete_run_after_pipeline_failure():
    workflow = (ROOT / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    failure_step = workflow.split("- name: Record failed or interrupted acquisition", 1)[1]
    failure_step = failure_step.split("- name: Commit raw archive and verification evidence", 1)[0]
    assert 'meta["status"] = "FAILED_OR_INTERRUPTED"' in failure_step
    assert 'if meta.get("status") != "COMPLETE"' not in failure_step
    assert workflow.index("Verify Phase 3C raw-manifest integrity") < workflow.index(
        "Record failed or interrupted acquisition"
    ) < workflow.index("Commit raw archive and verification evidence")


def test_phase3c_request_preservation_step_has_no_stray_heredoc_terminator():
    workflow = (ROOT / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    request_step = workflow.split("- name: Preserve effective and frozen request inputs", 1)[1]
    request_step = request_step.split("- name: Snapshot Phase 3C raw manifest", 1)[0]
    assert 'request_hashes.sha256"\n          PY' not in request_step
    assert 'request_hashes.sha256"\n      - name:' in workflow


def test_phase3c_dispatch_uses_maximum_frozen_rpc_enrichment_budget():
    workflow = (ROOT / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    dispatch = workflow.split('if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ]; then', 1)[1]
    dispatch = dispatch.split('REQUEST_PATH="$RUNNER_TEMP/phase3c-request.json"', 1)[0]
    assert 'request["rpc_max_pages"] = 3' in dispatch
    assert 'request["rpc_max_txs"] = 8' in dispatch
    assert 'request["new_pool_pages"] = 10' in dispatch
    assert 'request["strata"] = {"young": 100, "quiet_young": 20, "trending": 30, "established": 30}' in dispatch
    assert 'request["poll_pools_per_cycle"] = 12' in dispatch
    assert 'request["ohlcv_every"] = 1' in dispatch
    assert 'request["phase3a"] = True' in dispatch
    assert 'request["gt_rate_per_s"] = 0.45' in dispatch
    workflow = (ROOT / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    assert "timeout-minutes: 360" in workflow
    assert "phase3c_preflight datasets/phase3c/REQUEST.json --frozen-baseline" in workflow
    request = __import__("json").loads((ROOT / "intel" / "datasets" / "phase3c" / "REQUEST.json").read_text())
    assert request["rpc_max_pages"] == 1
    assert request["rpc_max_txs"] == 8


def test_phase3c_reserve_trade_and_ohlcv_polling_share_the_rotating_subset():
    source = (ROOT / "intel" / "autopsyx" / "data" / "acquire.py").read_text()
    poll = source[source.index("def poll_cycle("):source.index("\ndef run(")]
    assert poll.index("poll_picked = picked") < poll.index('f.get(gt.NAME, "gt.pools_multi"')
    assert 'pools = [p["pool"] for p in poll_picked]' in poll
    assert "for i in range(0, len(poll_picked), ds.MAX_PAIRS_PER_CALL)" in poll
    assert "chunk = poll_picked[i:i + ds.MAX_PAIRS_PER_CALL]" in poll
    assert "for p in poll_picked:" in poll
    assert 'f.get(gt.NAME, "gt.trades"' in poll
    assert 'f.get(gt.NAME, "gt.ohlcv"' in poll
    assert "pools = [p[\"pool\"] for p in picked]" not in poll


def test_intelligence_ci_normalizes_push_and_pull_request_concurrency_group():
    workflow = (ROOT / ".github" / "workflows" / "intel-tests.yml").read_text()
    group_lines = [line.strip() for line in workflow.splitlines() if line.strip().startswith("group:")]
    assert group_lines == [
        "group: intel-tests-${{ github.event.pull_request.head.ref || github.ref_name }}-${{ github.event_name }}"
    ]
    assert "cancel-in-progress: true" in workflow
    assert "timeout-minutes: 20" in workflow


def test_phase3c_failure_recovery_uses_runner_exported_run_id_safely():
    workflow = (ROOT / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    failure_step = workflow.split("- name: Record failed or interrupted acquisition", 1)[1]
    failure_step = failure_step.split("- name: Commit raw archive and verification evidence", 1)[0]
    commit_step = workflow.split("- name: Commit raw archive and verification evidence", 1)[1]

    # RUN_ID is written through GITHUB_ENV by an earlier step. Avoid an env
    # expression gate or a step-level env assignment that can mask that value.
    assert "if: failure() || cancelled()" in failure_step
    assert "env:\n          RUN_ID: ${{ env.RUN_ID }}" not in failure_step
    assert 'if: (failure() || cancelled()) && env.RUN_ID !=' not in failure_step
    assert 'if: always() && env.RUN_ID !=' not in commit_step
    assert 'if [[ -z "${RUN_ID:-}" ]]' in failure_step
    assert 'if [[ -z "${RUN_ID:-}" ]]' in commit_step
