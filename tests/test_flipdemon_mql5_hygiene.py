"""MQL5 source hygiene checks for include resolution and indicator lifecycle.

These checks are static repository checks. They do not replace MetaEditor compilation
or MT5 runtime/Strategy Tester validation.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
MQL_ROOT = ROOT / "MQL5"
INCLUDE_ROOT = MQL_ROOT / "Include"


class Mql5SourceHygieneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = sorted(
            p for p in MQL_ROOT.rglob("*")
            if p.is_file() and p.suffix.lower() in {".mq5", ".mqh"}
        )
        cls.text = {
            path: path.read_text(encoding="utf-8-sig")
            for path in cls.sources
        }

    def test_every_project_header_has_a_matching_include_guard(self):
        headers = [p for p in self.sources if p.suffix.lower() == ".mqh"]
        self.assertGreater(len(headers), 0, "No MQL5 headers discovered")
        macros = {}
        for path in headers:
            source = self.text[path]
            match = re.search(
                r"^\s*#ifndef\s+([A-Za-z_]\w*)\s*$[\s\S]*?"
                r"^\s*#define\s+([A-Za-z_]\w*)\s*$",
                source, re.MULTILINE
            )
            self.assertIsNotNone(match, f"{path.relative_to(ROOT)} has no conventional include guard")
            self.assertEqual(
                match.group(1), match.group(2),
                f"{path.relative_to(ROOT)} guard macro differs between #ifndef and #define"
            )
            macro = match.group(1)
            self.assertNotIn(
                macro, macros,
                f"Duplicate include guard {macro}: {macros.get(macro)} and {path.relative_to(ROOT)}"
            )
            macros[macro] = path.relative_to(ROOT)

    def test_every_include_resolves_using_mql5_search_rules(self):
        include_pattern = re.compile(
            r'^\s*#include\s*([<"])([^>"]+)[>"]', re.MULTILINE
        )
        unresolved = []
        for source_path, source in self.text.items():
            for match in include_pattern.finditer(source):
                delimiter, target = match.groups()
                target_path = Path(target.replace("\\", "/"))
                candidates = (
                    [source_path.parent / target_path, INCLUDE_ROOT / target_path]
                    if delimiter == '"'
                    else [INCLUDE_ROOT / target_path]
                )
                if not any(candidate.is_file() for candidate in candidates):
                    unresolved.append(
                        f"{source_path.relative_to(ROOT)}: {match.group(0).strip()}"
                    )
        self.assertEqual([], unresolved, "Unresolved MQL5 include(s):\n" + "\n".join(unresolved))

    def test_indicator_handle_owners_have_checked_reads_and_release_paths(self):
        indicator_factories = re.compile(r"\b(iMA|iATR|iRSI|iADX|iBands|iMACD|iStochastic)\s*\(")
        failures = []
        owners = 0
        for path, source in self.text.items():
            if not indicator_factories.search(source):
                continue
            owners += 1
            rel = path.relative_to(ROOT)
            if "INVALID_HANDLE" not in source:
                failures.append(f"{rel}: indicator handle is not checked against INVALID_HANDLE")
            if "CopyBuffer(" not in source:
                failures.append(f"{rel}: indicator factory exists without CopyBuffer")
            if "IndicatorRelease(" not in source:
                failures.append(f"{rel}: indicator handle has no IndicatorRelease call")
        self.assertGreater(owners, 0, "No indicator handle owners discovered")
        self.assertEqual([], failures, "Indicator lifecycle issue(s):\n" + "\n".join(failures))

    def test_copybuffer_results_are_checked_for_exact_or_minimum_count(self):
        failures = []
        for path, source in self.text.items():
            if "CopyBuffer(" not in source:
                continue
            # Require the result to participate in a comparison, rather than merely
            # calling CopyBuffer and proceeding with potentially incomplete data.
            checked = re.search(
                r"CopyBuffer\s*\([^;]+\)\s*(?:!=|<|<=|>|>=)\s*[^;]+;",
                source, re.DOTALL
            )
            assigned_and_checked = re.search(
                r"(?:int|const\s+int)\s+\w+\s*=\s*CopyBuffer\s*\([^;]+\);"
                r"[\s\S]{0,240}?\b\w+\s*(?:!=|<|<=|>|>=)\s*[^;]+",
                source
            )
            if not checked and not assigned_and_checked:
                failures.append(str(path.relative_to(ROOT)))
        self.assertEqual(
            [], failures,
            "CopyBuffer return count is not visibly checked in: " + ", ".join(failures)
        )


if __name__ == "__main__":
    unittest.main()
