"""Phase 3C-only raw-manifest integrity seal."""
from __future__ import annotations
import hashlib
import json
import sys
from pathlib import Path


def _snapshot(directory: Path) -> dict:
    path = directory / "manifest.jsonl"
    if not path.is_file():
        raise ValueError(f"manifest missing: {path}")
    raw = path.read_bytes()
    entries = []
    for line_no, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid manifest JSON at line {line_no}: {exc}") from exc
        expected = len(entries) + 1
        if not isinstance(entry, dict) or entry.get("seq") != expected:
            got = entry.get("seq") if isinstance(entry, dict) else type(entry).__name__
            raise ValueError(f"manifest sequence mismatch at line {line_no}: expected {expected}, got {got}")
        entries.append(entry)
    return {"manifest_sha256": hashlib.sha256(raw).hexdigest(),
            "manifest_exchanges": len(entries),
            "first_seq": entries[0]["seq"] if entries else None,
            "last_seq": entries[-1]["seq"] if entries else None}


def seal(run_dir: str) -> dict:
    directory = Path(run_dir)
    meta_path = directory / "run.json"
    if not meta_path.is_file():
        raise ValueError("run.json missing")
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    if meta.get("status") != "COMPLETE":
        raise ValueError(f"acquisition status is not COMPLETE: {meta.get('status')!r}")
    prov = meta.get("provenance")
    if not isinstance(prov, dict) or not prov.get("runner_dataset_hash"):
        raise ValueError("canonical provenance seal missing")
    if not (directory / "canonical" / "phase2_records.jsonl.gz").is_file():
        raise ValueError("canonical Phase 2 snapshot missing")
    snap = _snapshot(directory)
    expected = prov.get("record_counts", {}).get("manifest_exchanges")
    if expected != snap["manifest_exchanges"]:
        raise ValueError(f"manifest changed during canonical sealing: runner={expected}, current={snap['manifest_exchanges']}")
    meta["phase3c_manifest_integrity"] = {"version": 1, **snap}
    meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return meta["phase3c_manifest_integrity"]


def verify(run_dir: str) -> dict:
    directory = Path(run_dir)
    meta_path = directory / "run.json"
    if not meta_path.is_file():
        return {"verified": False, "reason": "run_metadata_missing"}
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    seal = meta.get("phase3c_manifest_integrity")
    try:
        current = _snapshot(directory)
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        return {"verified": False, "reason": "manifest_invalid", "error": str(exc)}
    runner_count = meta.get("provenance", {}).get("record_counts", {}).get("manifest_exchanges")
    result = {"verified": False, "reason": None, "run_id": directory.name,
              "manifest_sha256_current": current["manifest_sha256"],
              "manifest_exchanges_current": current["manifest_exchanges"],
              "manifest_exchanges_runner": runner_count,
              "manifest_count_matches_runner": runner_count == current["manifest_exchanges"],
              "seal_present": isinstance(seal, dict)}
    if not isinstance(seal, dict):
        result["reason"] = "manifest_seal_missing"
        return result
    result["manifest_sha256_sealed"] = seal.get("manifest_sha256")
    result["manifest_exchanges_sealed"] = seal.get("manifest_exchanges")
    result["manifest_hash_matches_seal"] = seal.get("manifest_sha256") == current["manifest_sha256"]
    result["manifest_count_matches_seal"] = seal.get("manifest_exchanges") == current["manifest_exchanges"]
    result["verified"] = bool(result["manifest_hash_matches_seal"] and result["manifest_count_matches_seal"]
                              and result["manifest_count_matches_runner"] and meta.get("status") == "COMPLETE")
    if not result["verified"]:
        result["reason"] = "manifest_drift_or_incomplete_acquisition"
    return result


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 2 or args[0] not in {"seal", "verify"}:
        print("usage: phase3c_manifest_integrity.py {seal|verify} RUN_DIR", file=sys.stderr)
        return 2
    try:
        result = seal(args[1]) if args[0] == "seal" else verify(args[1])
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(json.dumps({"verified": False, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0 if args[0] == "seal" or result.get("verified") else 1


if __name__ == "__main__":
    raise SystemExit(main())
