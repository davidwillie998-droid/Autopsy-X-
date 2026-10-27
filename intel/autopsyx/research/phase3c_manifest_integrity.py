"""Phase 3C-only raw-manifest snapshot and integrity seal."""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

SNAPSHOT_FILE = "phase3c_manifest_snapshot.json"


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
    return {
        "manifest_sha256": hashlib.sha256(raw).hexdigest(),
        "manifest_exchanges": len(entries),
        "first_seq": entries[0]["seq"] if entries else None,
        "last_seq": entries[-1]["seq"] if entries else None,
    }


def _read_meta(directory: Path) -> tuple[Path, dict]:
    path = directory / "run.json"
    if not path.is_file():
        raise ValueError("run.json missing")
    meta = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(meta, dict):
        raise ValueError("run.json must contain an object")
    if meta.get("status") != "COMPLETE":
        raise ValueError(f"acquisition status is not COMPLETE: {meta.get('status')!r}")
    return path, meta


def snapshot(run_dir: str) -> dict:
    """Capture the immutable manifest fingerprint before canonical normalization."""
    directory = Path(run_dir)
    _, meta = _read_meta(directory)
    path = directory / SNAPSHOT_FILE
    if path.exists():
        raise ValueError(f"refusing to overwrite immutable Phase 3C manifest snapshot: {path}")
    snap = {"version": 1, **_snapshot(directory)}
    # The acquisition runner records the manifest length before returning.
    # Reject drift before normalization can consume a different raw dataset.
    runner_count = meta.get("exchanges")
    if type(runner_count) is not int or runner_count != snap["manifest_exchanges"]:
        raise ValueError(
            "manifest exchange count differs from completed acquisition metadata: "
            f"runner={runner_count!r}, current={snap['manifest_exchanges']}"
        )
    (directory / SNAPSHOT_FILE).write_text(json.dumps(snap, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return snap


def seal(run_dir: str) -> dict:
    """Bind the post-normalization archive to the pre-normalization manifest snapshot."""
    directory = Path(run_dir)
    meta_path, meta = _read_meta(directory)
    prov = meta.get("provenance")
    if not isinstance(prov, dict) or not prov.get("runner_dataset_hash"):
        raise ValueError("canonical provenance seal missing")
    if not (directory / "canonical" / "phase2_records.jsonl.gz").is_file():
        raise ValueError("canonical Phase 2 snapshot missing")

    snapshot_path = directory / SNAPSHOT_FILE
    if not snapshot_path.is_file():
        raise ValueError("pre-canonical manifest snapshot missing; refusing to seal unbound archive")
    recorded_snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    current = {"version": 1, **_snapshot(directory)}
    if recorded_snapshot != current:
        raise ValueError(
            "manifest changed between acquisition snapshot and canonical sealing: "
            f"snapshot={recorded_snapshot}, current={current}"
        )
    runner_count = prov.get("record_counts", {}).get("manifest_exchanges")
    if runner_count != current["manifest_exchanges"]:
        raise ValueError(
            f"manifest count differs from canonical runner snapshot: runner={runner_count}, "
            f"current={current['manifest_exchanges']}"
        )
    meta["phase3c_manifest_integrity"] = current
    meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return current


def verify(run_dir: str) -> dict:
    directory = Path(run_dir)
    meta_path = directory / "run.json"
    if not meta_path.is_file():
        return {"verified": False, "reason": "run_metadata_missing"}
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    seal_record = meta.get("phase3c_manifest_integrity")
    runner_count = meta.get("provenance", {}).get("record_counts", {}).get("manifest_exchanges")
    try:
        current = _snapshot(directory)
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        return {"verified": False, "reason": "manifest_invalid", "error": str(exc)}

    snapshot_path = directory / SNAPSHOT_FILE
    recorded_snapshot = None
    if snapshot_path.is_file():
        try:
            recorded_snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            return {"verified": False, "reason": "manifest_snapshot_invalid", "error": str(exc)}

    result = {
        "verified": False,
        "reason": None,
        "run_id": directory.name,
        "manifest_sha256_current": current["manifest_sha256"],
        "manifest_exchanges_current": current["manifest_exchanges"],
        "manifest_exchanges_runner": runner_count,
        "manifest_count_matches_runner": runner_count == current["manifest_exchanges"],
        "snapshot_present": isinstance(recorded_snapshot, dict),
        "seal_present": isinstance(seal_record, dict),
    }
    if not isinstance(seal_record, dict):
        result["reason"] = "manifest_seal_missing"
        return result
    if not isinstance(recorded_snapshot, dict):
        result["reason"] = "manifest_snapshot_missing"
        return result

    result["manifest_sha256_snapshot"] = recorded_snapshot.get("manifest_sha256")
    result["manifest_sha256_sealed"] = seal_record.get("manifest_sha256")
    result["manifest_exchanges_snapshot"] = recorded_snapshot.get("manifest_exchanges")
    result["manifest_exchanges_sealed"] = seal_record.get("manifest_exchanges")
    result["manifest_hash_matches_snapshot"] = recorded_snapshot.get("manifest_sha256") == current["manifest_sha256"]
    result["manifest_count_matches_snapshot"] = recorded_snapshot.get("manifest_exchanges") == current["manifest_exchanges"]
    result["manifest_hash_matches_seal"] = seal_record.get("manifest_sha256") == current["manifest_sha256"]
    result["manifest_count_matches_seal"] = seal_record.get("manifest_exchanges") == current["manifest_exchanges"]
    result["snapshot_matches_seal"] = (
        recorded_snapshot.get("manifest_sha256") == seal_record.get("manifest_sha256")
        and recorded_snapshot.get("manifest_exchanges") == seal_record.get("manifest_exchanges")
        and recorded_snapshot.get("first_seq") == seal_record.get("first_seq")
        and recorded_snapshot.get("last_seq") == seal_record.get("last_seq")
    )
    result["verified"] = bool(
        result["manifest_hash_matches_snapshot"]
        and result["manifest_count_matches_snapshot"]
        and result["manifest_hash_matches_seal"]
        and result["manifest_count_matches_seal"]
        and result["snapshot_matches_seal"]
        and result["manifest_count_matches_runner"]
        and meta.get("status") == "COMPLETE"
    )
    if not result["verified"]:
        result["reason"] = "manifest_drift_or_incomplete_acquisition"
    return result


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 2 or args[0] not in {"snapshot", "seal", "verify"}:
        print("usage: phase3c_manifest_integrity.py {snapshot|seal|verify} RUN_DIR", file=sys.stderr)
        return 2
    try:
        if args[0] == "snapshot":
            result = snapshot(args[1])
        elif args[0] == "seal":
            result = seal(args[1])
        else:
            result = verify(args[1])
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(json.dumps({"verified": False, "error": str(exc)}, sort_keys=True), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0 if args[0] in {"snapshot", "seal"} or result.get("verified") else 1


if __name__ == "__main__":
    raise SystemExit(main())
