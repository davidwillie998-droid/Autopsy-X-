"""Check that every number in a generated document comes from the evidence.

A numeric token in the Markdown is accepted when it is either
  * fixed prose: it appears as a number inside the renderer's own source
    (rule text, section names like H1..H10, table headers), or
  * derived from the evidence JSON: a JSON number (exact or rounded to 0-4
    decimals), a JSON fraction rendered as a percentage, a minute count of a
    JSON millisecond duration, or a component of a JSON millisecond timestamp
    rendered as UTC date/time.
Anything else is reported as untraceable.
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path

NUM = re.compile(r"(?<![A-Za-z0-9_.])-?\d+(?:\.\d+)?%?(?![A-Za-z0-9_])")


def _walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from _walk(k)
            yield from _walk(v)
    elif isinstance(o, list):
        for v in o:
            yield from _walk(v)
    elif isinstance(o, bool):
        return
    elif isinstance(o, (int, float)):
        yield o
    elif isinstance(o, str):
        for m in NUM.finditer(o):
            yield m.group(0)


def allowed_from_evidence(ev: dict) -> set[str]:
    out: set[str] = set()
    for v in _walk(ev):
        if isinstance(v, str):
            out.add(v)
            continue
        out.add(str(v))
        if isinstance(v, float):
            for d in range(5):
                out.add(f"{v:.{d}f}")
            out.add(f"{v:.1%}")
            out.add(f"{v:.0%}")
        if isinstance(v, int) and not isinstance(v, bool):
            out.add(str(v // 60_000))
            if v > 1_000_000_000_000:  # millisecond timestamp
                dt = datetime.fromtimestamp(v / 1000, tz=timezone.utc)
                out.update(dt.strftime("%Y-%m-%d %H:%M:%S").replace("-", " ").replace(":", " ").split())
    return out


def allowed_from_source(source: str) -> set[str]:
    return {m.group(0) for m in NUM.finditer(source)}


def check(markdown: str, ev: dict, renderer_source: str) -> list[str]:
    ok = allowed_from_evidence(ev) | allowed_from_source(renderer_source)
    bad = []
    for line in markdown.splitlines():
        for m in NUM.finditer(line.replace("-", " ").replace(":", " ") if re.search(r"\d{4}-\d{2}-\d{2}", line) else line):
            tok = m.group(0)
            if tok not in ok and tok.lstrip("-") not in ok:
                bad.append(f"{tok!r} in: {line[:120]}")
    return bad


def check_files(md_path: str, evidence_path: str) -> list[str]:
    src = (Path(__file__).parent / "phase2_verify.py").read_text()
    return check(Path(md_path).read_text(), json.loads(Path(evidence_path).read_text()), src)
