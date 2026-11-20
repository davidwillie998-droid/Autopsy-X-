from __future__ import annotations

import csv

import pytest

from autopsyx.mt5_snapshot import audit_snapshot


FIELDS = [
    "sequence", "symbol", "magic", "time_msc",
    "bid", "ask", "spread_points", "dropped_before",
]


def write_snapshot(path, rows):
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def row(sequence, time_msc, *, bid="1.10000", ask="1.10010", dropped="0"):
    return {
        "sequence": str(sequence),
        "symbol": "EURUSD",
        "magic": "1500015",
        "time_msc": str(time_msc),
        "bid": bid,
        "ask": ask,
        "spread_points": "10",
        "dropped_before": dropped,
    }


def test_valid_snapshot_is_accepted_for_replay_import(tmp_path):
    path = tmp_path / "snapshot.csv"
    write_snapshot(path, [row(0, 1000), row(1, 1001), row(2, 1002)])

    audit = audit_snapshot(path)

    assert audit.valid_for_replay_import
    assert audit.rows == 3
    assert audit.symbol == "EURUSD"
    assert audit.first_time_msc == 1000
    assert audit.last_time_msc == 1002


def test_equal_millisecond_timestamps_are_reported_but_not_rejected(tmp_path):
    path = tmp_path / "snapshot.csv"
    write_snapshot(path, [row(0, 1000), row(1, 1000), row(2, 1001)])

    audit = audit_snapshot(path)

    assert audit.duplicate_timestamps == 1
    assert audit.timestamp_regressions == 0
    assert audit.valid_for_replay_import


def test_timestamp_regression_blocks_replay_import(tmp_path):
    path = tmp_path / "snapshot.csv"
    write_snapshot(path, [row(0, 1001), row(1, 1000)])

    audit = audit_snapshot(path)

    assert audit.timestamp_regressions == 1
    assert not audit.valid_for_replay_import


def test_dropped_snapshot_rows_are_reported_and_block_import(tmp_path):
    path = tmp_path / "snapshot.csv"
    write_snapshot(path, [row(0, 1000), row(1, 1001, dropped="3")])

    audit = audit_snapshot(path)

    assert audit.reported_dropped_rows == 3
    assert not audit.valid_for_replay_import


def test_invalid_quote_blocks_replay_import(tmp_path):
    path = tmp_path / "snapshot.csv"
    write_snapshot(path, [row(0, 1000, bid="1.2", ask="1.1")])

    audit = audit_snapshot(path)

    assert audit.invalid_quotes == 1
    assert not audit.valid_for_replay_import


def test_missing_schema_column_is_rejected(tmp_path):
    path = tmp_path / "snapshot.csv"
    path.write_text("sequence,symbol\n0,EURUSD\n", encoding="utf-8")

    with pytest.raises(ValueError, match="missing required columns"):
        audit_snapshot(path)
