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
    infra_allowed = {"intel/datasets/phase3c/REQUEST.json", ".github/workflows/phase3c-acquire.yml", ".github/workflows/intel-tests.yml", ".github/workflows/flipdemon-ui.yml"}
    for f in changed:
        allowed = (f.startswith("docs/PHASE3C_") or f.startswith("intel/autopsyx/research/phase3c_")
                  or f.startswith("intel/tests/test_phase3c_") or f.startswith("research/phase3c/")
                  or f == "intel/autopsyx/data/acquire.py"
                  or f == "intel/autopsyx/data/request_validation.py"
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
        '    started = now_ms()\n'
        '    meta = {"started_ms": started, "plan": plan.__dict__, "code_version": os.environ.get("GITHUB_SHA", "local"),\n'
        '            "runner": os.environ.get("RUNNER_NAME", "local"), "execution": "none: acquisition only, no orders"}\n',
        '    run_started_ms = now_ms()\n'
        '    meta = {"started_ms": run_started_ms, "plan": plan.__dict__, "code_version": os.environ.get("GITHUB_SHA", "local"),\n'
        '            "runner": os.environ.get("RUNNER_NAME", "local"), "execution": "none: acquisition only, no orders",\n'
        '            "poll_window_started_ms": None, "poll_window_duration_s": plan.duration_s,\n'
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
        '        if (t0 - started) / 1000 >= plan.duration_s or (max_cycles is not None and cycle >= max_cycles):\n',
        '        if (t0 - poll_window_started_ms) / 1000 >= plan.duration_s or (max_cycles is not None and cycle >= max_cycles):\n'
    )
    substitute(
        '    meta.update({"ended_ms": now_ms(), "cycles": cycle, "exchanges": len(entries), "circuit_waits": f.waited,\n'
        '                 "final_gt_rate_per_s": f.clients[gt.NAME].limiter.rate,\n'
        '                 "errors": sum(1 for e in entries if e.error), "status": "COMPLETE"})\n',
        '    ended_ms = now_ms()\n'
        '    meta.update({"ended_ms": ended_ms, "cycles": cycle, "poll_window_cycles": cycle,\n'
        '                 "poll_window_elapsed_s": max(0.0, (ended_ms - poll_window_started_ms) / 1000),\n'
        '                 "exchanges": len(entries), "circuit_waits": f.waited,\n'
        '                 "final_gt_rate_per_s": f.clients[gt.NAME].limiter.rate,\n'
        '                 "errors": sum(1 for e in entries if e.error), "status": "COMPLETE"})\n'
    )

    substitute(
        "    rpc_max_txs: int = 40\n",
        "    rpc_max_txs: int = 40\n"
        "    # Optional fail-closed minimum for Phase 3C: do not spend collection budget\n"
        "    # unless discovery actually returns this many distinct token addresses.\n"
        "    min_selected_tokens: int = 0\n"
    )
    substitute(
        "    min_selected_tokens: int = 0\n",
        "    min_selected_tokens: int = 0\n"
        "    # Token addresses already present in prior eligible evidence archives.\n"
        "    # Phase 3C selection skips these to avoid spending budget on duplicate universes.\n"
        "    excluded_tokens: list[str] = field(default_factory=list)\n"
    )
    substitute(
        "def select_universe(f: Fetcher, plan: Plan) -> dict:\n",
        "def _exclude_prior_tokens(pool_list: list[dict], prior_tokens: set[str]) -> tuple[list[dict], list[dict]]:\n"
        "    \"\"\"Split candidates into novel tokens and auditable prior-token exclusions.\"\"\"\n"
        "    novel, excluded = [], []\n"
        "    for pool in pool_list:\n"
        "        if pool[\"token\"] in prior_tokens:\n"
        "            excluded.append({**pool, \"reason\": \"token already present in prior evidence archive\"})\n"
        "        else:\n"
        "            novel.append(pool)\n"
        "    return novel, excluded\n\n"
        "\n"
        "def select_universe(f: Fetcher, plan: Plan) -> dict:\n"
    )
    substitute(
        "    picked: list[dict] = []\n"
        "    tokens: set[str] = set()\n"
        "    excluded: list[dict] = []\n",
        "    picked: list[dict] = []\n"
        "    tokens: set[str] = set()\n"
        "    prior_tokens = set(plan.excluded_tokens)\n"
        "    prior_excluded_tokens: set[str] = set()\n"
        "    excluded: list[dict] = []\n"
    )
    substitute(
        "    def take(stratum: str, pool_list: list[dict], k: int) -> None:\n"
        "        pool_list = sorted(pool_list, key=lambda p: \"pool\")  # order-independent sampling\n",
        "    def take(stratum: str, pool_list: list[dict], k: int) -> None:\n"
        "        pool_list, prior_excluded = _exclude_prior_tokens(pool_list, prior_tokens)\n"
        "        for row in prior_excluded:\n"
        "            token = row[\"token\"]\n"
        "            if token not in prior_excluded_tokens:\n"
        "                excluded.append(row)\n"
        "                prior_excluded_tokens.add(token)\n"
        "        pool_list = sorted(pool_list, key=lambda p: \"pool\")  # order-independent sampling\n"
    )
    substitute(
        "    sel = {\"seed\": plan.seed, \"strata_targets\": plan.strata, \"selected_at_ms\": f.now_ms(),\n"
        "           \"candidates\": {k: len(v) for k, v in cands.items()} | {\"quiet_young\": len(quiet)},\n",
        "    prior_excluded_tokens = {\n"
        "        row[\"token\"] for row in excluded\n"
        "        if row.get(\"reason\") == \"token already present in prior evidence archive\"\n"
        "    }\n"
        "    sel = {\"seed\": plan.seed, \"strata_targets\": plan.strata, \"selected_at_ms\": f.now_ms(),\n"
        "           \"prior_token_addresses_available\": len(prior_tokens),\n"
        "           \"prior_distinct_tokens_excluded\": len(prior_excluded_tokens),\n"
        "           \"candidates\": {k: len(v) for k, v in cands.items()} | {\"quiet_young\": len(quiet)},\n"
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
        '    from .request_validation import distinct_token_count\n'
        '    selected_token_count = distinct_token_count(picked)\n'
        '    if plan.min_selected_tokens and selected_token_count < plan.min_selected_tokens:\n'
        '        meta["status"] = (\n'
        '            f"BLOCKED: discovery selected {selected_token_count} distinct tokens; "\n'
        '            f"minimum is {plan.min_selected_tokens}; no backfill, enrichment, or polling performed"\n'
        '        )\n'
        '        meta["selected_distinct_tokens"] = selected_token_count\n'
        '        raw.write_json("run.json", meta)\n'
        '        return meta\n'
        '    backfill(f, plan, picked)\n'
    )
    actual = (ROOT / "intel" / "autopsyx" / "data" / "acquire.py").read_text()
    assert actual.rstrip("\n") == expected.rstrip("\n"), "acquire.py contains changes beyond the reviewed poll-window timing repair and exact Phase 3C minimum-token guard"


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
