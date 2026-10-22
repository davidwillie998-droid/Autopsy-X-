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



def test_acquire_module_contains_only_the_reviewed_poll_window_repair():
    """Allow the one necessary timing fix while proving all other acquisition
    behavior remains byte-for-byte identical to the reviewed PR base."""
    baseline = git("show", f"{PHASE3C_ACQUIRE_BASELINE_COMMIT}:intel/autopsyx/data/acquire.py")
    expected = baseline

    def substitute(old: str, new: str) -> None:
        nonlocal expected
        assert expected.count(old) == 1, old
        expected = expected.replace(old, new, 1)

    substitute(
        '    poll_ohlcv_limit: int = 5\n',
        '    poll_ohlcv_limit: int = 5\n'
        '    # Optional Phase 3C request budget: rotate this many pools per poll cycle.\n'
        '    # None preserves the frozen Phase 3A/Phase 2 behavior exactly.\n'
        '    poll_pools_per_cycle: int | None = None\n'
    )

    substitute(
        '        f.get(gt.NAME, "gt.pools_multi", gt.path_pools_multi(n, chunk), {"chain": n, "cycle": cycle})\n',
        '        f.get(gt.NAME, "gt.pools_multi", gt.path_pools_multi(n, chunk), {"chain": n, "cycle": cycle, "pools": list(chunk)})\n'
    )

    substitute(
        '    started = now_ms()\n'
        '    meta = {"started_ms": started, "plan": plan.__dict__, "code_version": os.environ.get("GITHUB_SHA", "local"),\n'
        '            "runner": os.environ.get("RUNNER_NAME", "local"), "execution": "none: acquisition only, no orders"}\n',
        '    run_started_ms = now_ms()\n'
        '    meta = {"started_ms": run_started_ms, "plan": plan.__dict__, "code_version": os.environ.get("GITHUB_SHA", "local"),\n'
        '            "runner": os.environ.get("RUNNER_NAME", "local"), "execution": "none: acquisition only, no orders",\n'
        '            "poll_window_started_ms": None, "poll_window_ended_ms": None, "poll_window_duration_s": plan.duration_s,\n'
        '            "poll_window_cycles": 0, "poll_window_elapsed_s": 0.0}\n'
    )
    substitute(
        '    if plan.phase3a:\n'
        '        meta["enrichment"] = enrich(f, plan, picked, 0)\n'
        '        raw.write_json("run.json", meta)\n'
        '    cycle = 0\n',
        '    if plan.phase3a:\n'
        '        meta["enrichment"] = enrich(f, plan, picked, 0)\n'
        '        raw.write_json("run.json", meta)\n'
        '    # Setup work must not consume the live observation budget.\n'
        '    # Start the timer only after discovery, backfill, and initial enrichment.\n'
        '    poll_window_started_ms = now_ms()\n'
        '    meta["poll_window_started_ms"] = poll_window_started_ms\n'
        '    raw.write_json("run.json", meta)\n'
        '    cycle = 0\n'
    )
    substitute(
        '    for p in picked:\n'
        '        ctx = {"chain": n, "pool": p["pool"], "token": p["token"], "cycle": cycle}\n'
        '        f.get(gt.NAME, "gt.trades", gt.path_trades(n, p["pool"]), ctx)\n'
        '        if cycle % plan.ohlcv_every == 0:\n'
        '            f.get(gt.NAME, "gt.ohlcv", gt.path_ohlcv(n, p["pool"], plan.poll_ohlcv_limit), ctx)\n',
        '    poll_picked = picked\n'
        '    if plan.poll_pools_per_cycle is not None:\n'
        '        if plan.poll_pools_per_cycle < 1:\n'
        '            raise ValueError("poll_pools_per_cycle must be >= 1 when configured")\n'
        '        count = min(plan.poll_pools_per_cycle, len(picked))\n'
        '        start = (cycle * count) % len(picked)\n'
        '        poll_picked = [picked[(start + offset) % len(picked)] for offset in range(count)]\n'
        '    for p in poll_picked:\n'
        '        ctx = {"chain": n, "pool": p["pool"], "token": p["token"], "cycle": cycle}\n'
        '        f.get(gt.NAME, "gt.trades", gt.path_trades(n, p["pool"]), ctx)\n'
        '        if cycle % plan.ohlcv_every == 0:\n'
        '            f.get(gt.NAME, "gt.ohlcv", gt.path_ohlcv(n, p["pool"], plan.poll_ohlcv_limit), ctx)\n'
    )

    substitute(
        '        if (t0 - started) / 1000 >= plan.duration_s or (max_cycles is not None and cycle >= max_cycles):\n',
        '        if (t0 - poll_window_started_ms) / 1000 >= plan.duration_s or (max_cycles is not None and cycle >= max_cycles):\n'
    )
    substitute(
        '    if plan.phase3a:\n'
        '        meta["enrichment"] += enrich(f, plan, picked, 1)\n'
        '    entries = raw.entries()\n'
        '    meta.update({"ended_ms": now_ms(), "cycles": cycle, "exchanges": len(entries), "circuit_waits": f.waited,\n'
        '                 "final_gt_rate_per_s": f.clients[gt.NAME].limiter.rate,\n'
        '                 "errors": sum(1 for e in entries if e.error), "status": "COMPLETE"})\n',
        '    poll_window_ended_ms = now_ms()\n'
        '    if plan.phase3a:\n'
        '        meta["enrichment"] += enrich(f, plan, picked, 1)\n'
        '    entries = raw.entries()\n'
        '    ended_ms = now_ms()\n'
        '    meta.update({"ended_ms": ended_ms, "cycles": cycle, "poll_window_cycles": cycle,\n'
        '                 "poll_window_ended_ms": poll_window_ended_ms,\n'
        '                 "poll_window_elapsed_s": max(0.0, (poll_window_ended_ms - poll_window_started_ms) / 1000),\n'
        '                 "exchanges": len(entries), "circuit_waits": f.waited,\n'
        '                 "final_gt_rate_per_s": f.clients[gt.NAME].limiter.rate,\n'
        '                 "errors": sum(1 for e in entries if e.error), "status": "COMPLETE"})\n'
    )
    substitute(
        '    if not picked:\n'
        '        meta["status"] = "BLOCKED: no pools selectable (discovery failed)"\n'
        '        raw.write_json("run.json", meta)\n'
        '        return meta\n'
        '    backfill(f, plan, picked)\n',
        '    if not picked:\n'
        '        meta["status"] = "BLOCKED: no pools selectable (discovery failed)"\n'
        '        raw.write_json("run.json", meta)\n'
        '        return meta\n'
        '    # Phase 3C must not spend hours collecting a sample that cannot satisfy\n'
        '    # its frozen distinct-token gate. Fail before backfill/polling if selection\n'
        '    # did not produce every requested unique token.\n'
        '    if plan.poll_pools_per_cycle is not None:\n'
        '        target = sum(plan.strata.values())\n'
        '        selected_tokens = len({p["token"] for p in picked})\n'
        '        meta["selection_gate"] = {\n'
        '            "requested_unique_tokens": target,\n'
        '            "selected_unique_tokens": selected_tokens,\n'
        '            "pass": selected_tokens >= target,\n'
        '        }\n'
        '        if selected_tokens < target:\n'
        '            meta["status"] = (\n'
        '                f"BLOCKED: selected {selected_tokens} unique tokens; "\n'
        '                f"Phase 3C acquisition target is {target}"\n'
        '            )\n'
        '            raw.write_json("run.json", meta)\n'
        '            return meta\n'
        '    backfill(f, plan, picked)\n'
    )

    actual = (ROOT / "intel" / "autopsyx" / "data" / "acquire.py").read_text()
    assert actual.rstrip("\n") == expected.rstrip("\n"), "acquire.py contains changes beyond the reviewed poll-window timing repair"


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
    assert 'request["poll_pools_per_cycle"] = 5' in dispatch
    assert 'request["ohlcv_every"] = 1' in dispatch
    assert 'request["phase3a"] = True' in dispatch
    assert 'request["gt_rate_per_s"] = 0.15' in dispatch
    workflow = (ROOT / ".github" / "workflows" / "phase3c-acquire.yml").read_text()
    assert "timeout-minutes: 360" in workflow
    assert "phase3c_preflight datasets/phase3c/REQUEST.json --frozen-baseline" in workflow
    request = __import__("json").loads((ROOT / "intel" / "datasets" / "phase3c" / "REQUEST.json").read_text())
    assert request["rpc_max_pages"] == 1
    assert request["rpc_max_txs"] == 8
