"""Phase 6 verification: automated, re-runnable static-analysis tests over
the MQL5 SOURCE TREE itself (not simulated/reimplemented logic - reads the
real .mq5/.mqh files). This is the executable form of the Phase 6
architecture audit (docs/PHASE6_VERIFICATION_REPORT.md): every finding in
that report that can be expressed as a grep/parse over the source is
encoded here as a permanent regression test, so a future change that
accidentally violates one of these invariants (wires a dormant module into
the live EA, adds a second CTrade instance, removes a risk clamp) fails a
test immediately instead of requiring a fresh manual audit.

No MQL5 compiler is available in this environment (confirmed: no
metaeditor/metaeditor64 binary, no wine, Linux-only host - see the Phase 6
report's own Compilation Status section). These tests do NOT substitute
for compilation - they verify structural/textual invariants only, and are
explicitly labeled as such. They complement, not replace, the manual code
trace in the Phase 6 report.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
INCLUDE_DIR = REPO_ROOT / "MQL5" / "Include" / "AutopsyX"
EA_FILE = REPO_ROOT / "MQL5" / "Experts" / "AutopsyX" / "AutopsyX_FlipDemon_Extreme.mq5"

# The exact, frozen set of modules the live EA #includes directly (Layer 1).
# Any change to this set is a Layer-1 wiring change and must be a deliberate,
# reviewed decision - never an accidental side effect of adding a dormant module.
EXPECTED_LIVE_INCLUDES = {
    "Defs", "MarketData", "Momentum", "Microstructure", "Liquidity", "Regime",
    "SignalScore", "FlipEngine", "AntiChop", "RiskEngine", "EntryEngine",
    "ExecutionEngine", "ExitEngine", "SniperEngine", "OrderFlow", "VolumeProfile",
    "Footprint", "Pulse", "Heatmap", "TradeAutopsy", "Statistics",
    "AdaptiveFlipEngine", "VWAPEngine", "EmergencyControls", "Dashboard",
}

EXECUTION_AUTHORITY_PATTERN = re.compile(
    r"\bOrderSend\b|\bOrderSendAsync\b|\.Buy\(|\.Sell\(|\.PositionOpen\(|"
    r"\.PositionClose\(|\.PositionClosePartial\(|\.PositionModify\(|"
    r"\.BuyStop\(|\.SellStop\(|\.BuyLimit\(|\.SellLimit\("
)


def _all_mqh_files() -> list[Path]:
    return sorted(INCLUDE_DIR.glob("*.mqh"))


def _direct_includes(path: Path) -> set[str]:
    text = path.read_text(errors="replace")
    names = re.findall(r'#include\s+[<"]AutopsyX/([A-Za-z0-9_]+)\.mqh[>"]', text)
    # the live EA's own includes use <AutopsyX/X.mqh>; internal .mqh-to-.mqh includes use "X.mqh"
    names += re.findall(r'#include\s+"([A-Za-z0-9_]+)\.mqh"', text)
    return set(names)


def _transitive_includes(start: Path) -> set[str]:
    seen: set[str] = set()
    frontier = [start]
    while frontier:
        f = frontier.pop()
        for name in _direct_includes(f):
            if name in seen:
                continue
            seen.add(name)
            candidate = INCLUDE_DIR / f"{name}.mqh"
            if candidate.exists():
                frontier.append(candidate)
    return seen


@pytest.mark.skipif(not EA_FILE.exists(), reason="live EA file not found")
def test_live_ea_include_set_is_exactly_the_documented_layer_1():
    included = _direct_includes(EA_FILE)
    assert included == EXPECTED_LIVE_INCLUDES, (
        f"Live EA #include set changed. Added: {included - EXPECTED_LIVE_INCLUDES}, "
        f"removed: {EXPECTED_LIVE_INCLUDES - included}. If this is a deliberate wiring "
        f"change, update EXPECTED_LIVE_INCLUDES here AND docs/EA_DESCRIPTION.md together."
    )


@pytest.mark.skipif(not EA_FILE.exists(), reason="live EA file not found")
def test_no_dormant_module_reachable_transitively_from_the_live_ea():
    """Even a module not directly #include'd could sneak in if one of the
    LIVE files itself pulled it in - this walks the full transitive closure,
    not just the EA's own top-level list."""
    reachable = _transitive_includes(EA_FILE)
    reachable.discard("Defs")  # trivially included by nearly everything, expected
    all_modules = {p.stem for p in _all_mqh_files()}
    dormant = all_modules - EXPECTED_LIVE_INCLUDES
    leaked = reachable & dormant
    assert not leaked, f"Dormant module(s) reachable from the live EA: {leaked}"


def test_every_dormant_module_has_zero_execution_authority():
    """Static grep for CTrade-method-style execution calls in every module
    NOT in the live include set. A hit here does not by itself prove a real
    order would be sent (it could be inside a comment, a docstring-style
    header, or a class named similarly) - see the Phase 6 report's own
    manual review of each match - but zero hits is the expected, verified
    baseline and any new hit must be investigated before being accepted."""
    all_modules = {p.stem: p for p in _all_mqh_files()}
    dormant = {name: path for name, path in all_modules.items() if name not in EXPECTED_LIVE_INCLUDES}
    assert len(dormant) >= 30, "sanity check: expected a large dormant module set"

    offenders = {}
    for name, path in dormant.items():
        text = path.read_text(errors="replace")
        # strip //-style comments and /* */ blocks before matching, so a comment
        # that merely DISCUSSES execution calls (e.g. "never calls CTrade") doesn't
        # trip this check - only real, uncommented code matters here.
        code_only = re.sub(r"//.*", "", text)
        code_only = re.sub(r"/\*.*?\*/", "", code_only, flags=re.DOTALL)
        hits = EXECUTION_AUTHORITY_PATTERN.findall(code_only)
        if hits:
            offenders[name] = hits
    assert not offenders, f"Execution-authority calls found in dormant modules: {offenders}"


def test_exactly_one_ctrade_instance_in_the_entire_include_tree():
    """CTrade m_trade (or equivalent) must be declared exactly once, inside
    CExecutionEngine - duplicate risk/sizing/execution authority (Phase 6
    hard-stop condition) would show up here as a second declaration."""
    declarations = []
    for path in _all_mqh_files():
        text = path.read_text(errors="replace")
        code_only = re.sub(r"//.*", "", text)
        for m in re.finditer(r"\bCTrade\s+\w+\s*;", code_only):
            declarations.append((path.stem, m.group(0)))
    assert len(declarations) == 1, f"Expected exactly one CTrade member declaration, found: {declarations}"
    assert declarations[0][0] == "ExecutionEngine"


def test_risk_percent_is_clamped_at_its_only_write_site():
    """m_riskPercent may ALSO be assigned a hardcoded literal in the
    constructor (a sane default before Configure() ever runs, the same
    pattern every engine in this codebase uses) - that write is not a bypass
    since it takes no external input. The invariant this test actually
    checks: exactly one write derives from a caller-supplied parameter
    (`riskPercent`), and that write is clamped to [0.05, 2.0]."""
    risk_file = INCLUDE_DIR / "RiskEngine.mqh"
    text = risk_file.read_text(errors="replace")
    writes = re.findall(r"m_riskPercent\s*=\s*[^;]+;", text)
    assert writes, "No write to m_riskPercent found at all"
    configurable_writes = [w for w in writes if "riskPercent" in w and "AxClampD" in w]
    literal_default_writes = [w for w in writes if re.fullmatch(r"m_riskPercent\s*=\s*[\d.]+\s*;", w)]
    assert len(writes) == len(configurable_writes) + len(literal_default_writes), (
        f"Found a write to m_riskPercent that is neither a clamped configurable "
        f"assignment nor a hardcoded literal default: {writes}"
    )
    assert len(configurable_writes) == 1, (
        f"Expected exactly one clamped, caller-driven write to m_riskPercent, found "
        f"{len(configurable_writes)}: {configurable_writes}"
    )
    assert "0.05" in configurable_writes[0] and "2.0" in configurable_writes[0], (
        f"Clamp bounds changed unexpectedly: {configurable_writes[0]}"
    )


def test_adaptive_flip_engine_multiplier_is_bounded_to_unity():
    afe_file = INCLUDE_DIR / "AdaptiveFlipEngine.mqh"
    text = afe_file.read_text(errors="replace")
    writes = re.findall(r"m_lastRiskMultiplier\s*=\s*[^;]+;", text)
    # one write is the constructor default (=1.0); at least one other must be the clamped
    # runtime assignment
    clamped = [w for w in writes if "AxClampD" in w and "0.0" in w and "1.0" in w]
    assert clamped, f"No clamped write to m_lastRiskMultiplier found among: {writes}"


def test_pretrade_allowed_checks_every_required_hard_gate():
    risk_file = INCLUDE_DIR / "RiskEngine.mqh"
    text = risk_file.read_text(errors="replace")
    m = re.search(r"bool\s+PreTradeAllowed\([^)]*\)\s*\{.*?\n\s*\}", text, re.DOTALL)
    assert m, "PreTradeAllowed() method body not found"
    body = m.group(0)
    required_checks = [
        "m_killed", "DailyLossLimitBreached", "WeeklyLossLimitBreached",
        "ConsecutiveLossLimitBreached", "ExecutionFailureLimitBreached",
        "m_maxOpenPositions", "m_maxExposureLots", "m_maxSpreadPts",
        "MarginUsageAcceptable",
    ]
    missing = [c for c in required_checks if c not in body]
    assert not missing, f"PreTradeAllowed() is missing expected gate(s): {missing}"


def test_no_import_or_webrequest_anywhere_in_mql5():
    """External API / DLL dependency inside execution-critical code is a
    Phase 6 hard-stop condition - checked repo-wide, not just in dormant
    modules, since a WebRequest in a LIVE file would be far worse."""
    offenders = []
    mql5_dir = REPO_ROOT / "MQL5"
    for path in list(mql5_dir.rglob("*.mqh")) + list(mql5_dir.rglob("*.mq5")):
        text = path.read_text(errors="replace")
        if re.search(r"#import\b", text) or re.search(r"\bWebRequest\s*\(", text):
            offenders.append(str(path.relative_to(REPO_ROOT)))
    assert not offenders, f"Found #import/WebRequest in: {offenders}"


def test_no_python_mql5_ipc_bridge():
    """No socket/named-pipe/shared-memory/subprocess bridge anywhere that
    could let the Python research layer influence live execution."""
    offenders = []
    self_path = Path(__file__).resolve()
    for base in ("MQL5", "python", "research"):
        d = REPO_ROOT / base
        if not d.exists():
            continue
        for path in d.rglob("*"):
            if path.suffix not in (".mqh", ".mq5", ".py"):
                continue
            if "__pycache__" in path.parts:
                continue
            if path.resolve() == self_path:
                continue  # this file legitimately contains the pattern strings themselves
            text = path.read_text(errors="replace")
            if re.search(r"\bsocket\.|named.?pipe|DllImport|zmq|subprocess\.|os\.system\(", text, re.IGNORECASE):
                offenders.append(str(path.relative_to(REPO_ROOT)))
    assert not offenders, f"Potential Python<->MQL5 IPC bridge found in: {offenders}"


def test_live_entry_gate_uses_account_wide_exposure_and_blocks_foreign_symbol_positions():
    ea = EA_FILE.read_text(errors="replace")
    assert "AxCountRealPositions(accountPositions,accountExposureLots,realPositionsForSymbol," in ea
    assert "PreTradeAllowed(accountPositions,accountExposureLots" in ea
    assert "if(foreignPositionOnSymbol)" in ea
    assert "PreTradeAllowed(0,0.0" not in ea


def test_live_position_sizing_uses_broker_account_currency_profit_calculation():
    ea = EA_FILE.read_text(errors="replace")
    assert "OrderCalcProfit(orderType,_Symbol,lots,intendedPrice,slPrice,projectedProfitAtStop)" in ea
    assert "if(!riskCalcOk || projectedProfitAtStop>=0.0 || projectedLoss>riskBudget+0.01)" in ea


def test_execution_requires_owned_position_and_confirmed_server_fill():
    execution = (INCLUDE_DIR / "ExecutionEngine.mqh").read_text(errors="replace")
    assert "PositionGetInteger(POSITION_MAGIC)!=m_magic" in execution
    assert "Existing position on symbol; refusing to merge or take ownership" in execution
    assert "retcode==TRADE_RETCODE_DONE || retcode==TRADE_RETCODE_DONE_PARTIAL" in execution


def test_partial_close_accounting_uses_actual_reduced_volume():
    ea = EA_FILE.read_text(errors="replace")
    execution = (INCLUDE_DIR / "ExecutionEngine.mqh").read_text(errors="replace")
    assert "double &actualVolumeClosed" in execution
    assert "actualVolumeClosed=reduced;" in execution
    assert "AxRecordPartialClose(actualVolumeClosed," in ea
    assert "AxRecordPartialClose(volumeToClose," not in ea


def test_execution_never_mutates_foreign_positions_or_retries_ambiguous_entries():
    execution = (INCLUDE_DIR / "ExecutionEngine.mqh").read_text(errors="replace")
    assert "Refusing to close a position not owned by this EA" in execution
    assert "Refusing to partially close a position not owned by this EA" in execution
    assert "Refusing to modify stops on a position not owned by this EA" in execution
    assert "Ambiguous order result, not retried" in execution
    assert "retcode==TRADE_RETCODE_TIMEOUT || retcode==TRADE_RETCODE_CONNECTION" in execution


def test_stop_update_failures_do_not_force_exit_while_protective_stop_remains():
    ea = EA_FILE.read_text(errors="replace")
    execution = (INCLUDE_DIR / "ExecutionEngine.mqh").read_text(errors="replace")
    assert "TRADE_RETCODE_NO_CHANGES" in execution
    assert "broker protective SL remains active; retaining position" in ea
