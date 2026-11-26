import csv
import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/pure_price_action_evaluator.py"
SPEC = importlib.util.spec_from_file_location("pure_price_action_evaluator", SCRIPT)
EVALUATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVALUATOR)


def write_csv(path, rows, fields):
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def test_forward_outcomes_use_only_bars_after_observation(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    write_csv(journal, [{
        "bar_time": "2026.01.01 00:00",
        "symbol": "TEST",
        "timeframe": "PERIOD_M5",
        "prior_impulse_direction": "1",
        "candle_state": "BULL_BODY",
        "body_ratio": "0.7",
        "close_location": "0.8",
        "pullback_depth": "0.1",
    }], ["bar_time", "symbol", "timeframe", "prior_impulse_direction",
         "candle_state", "body_ratio", "close_location", "pullback_depth"])
    write_csv(ohlc, [
        {"timestamp": "2026.01.01 00:00", "symbol": "TEST", "timeframe": "PERIOD_M5",
         "open": "100", "high": "105", "low": "99", "close": "102"},
        {"timestamp": "2026.01.01 00:05", "symbol": "TEST", "timeframe": "PERIOD_M5",
         "open": "102", "high": "108", "low": "101", "close": "106"},
        {"timestamp": "2026.01.01 00:10", "symbol": "TEST", "timeframe": "PERIOD_M5",
         "open": "106", "high": "109", "low": "104", "close": "107"},
    ], ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])

    observations, report = EVALUATOR.evaluate(journal, ohlc, [1, 2])
    assert len(observations) == 2
    one_bar = next(row for row in observations if row["horizon_bars"] == 1)
    assert round(one_bar["raw_forward_return_pct"], 6) == round((106 / 102 - 1) * 100, 6)
    assert round(one_bar["mfe_pct"], 6) == round((108 / 102 - 1) * 100, 6)
    assert one_bar["directional_hit"] == 1
    assert report["metadata"]["journal_rows"] == 1


def test_missing_ohlc_alignment_is_excluded_not_guessed(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    write_csv(journal, [{
        "bar_time": "2026.01.01 00:00", "symbol": "TEST",
        "timeframe": "PERIOD_M5", "prior_impulse_direction": "-1",
    }], ["bar_time", "symbol", "timeframe", "prior_impulse_direction"])
    write_csv(ohlc, [{
        "timestamp": "2026.01.01 00:05", "symbol": "TEST", "timeframe": "PERIOD_M5",
        "open": "100", "high": "101", "low": "99", "close": "100",
    }], ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])

    observations, report = EVALUATOR.evaluate(journal, ohlc, [1])
    assert observations == []
    assert report["metadata"]["exclusions"]["journal_bar_not_found_in_ohlc"] == 1


def test_unresolved_impulse_is_not_counted_as_directional_prediction(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    write_csv(journal, [{
        "bar_time": "2026.01.01 00:00", "symbol": "TEST",
        "timeframe": "PERIOD_M5", "prior_impulse_direction": "0",
    }], ["bar_time", "symbol", "timeframe", "prior_impulse_direction"])
    write_csv(ohlc, [
        {"timestamp": "2026.01.01 00:00", "symbol": "TEST", "timeframe": "PERIOD_M5",
         "open": "100", "high": "101", "low": "99", "close": "100"},
        {"timestamp": "2026.01.01 00:05", "symbol": "TEST", "timeframe": "PERIOD_M5",
         "open": "100", "high": "102", "low": "99", "close": "101"},
    ], ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])

    observations, report = EVALUATOR.evaluate(journal, ohlc, [1])
    assert len(observations) == 1
    assert observations[0]["signed_forward_return_pct"] == ""
    assert report["groups"][0]["directional_observations"] == 0


def test_benjamini_hochberg_adjustment_is_monotone():
    adjusted = EVALUATOR.benjamini_hochberg([0.01, 0.04, 0.03])
    assert len(adjusted) == 3
    assert adjusted[0] <= adjusted[2] <= adjusted[1]
    assert all(0 <= value <= 1 for value in adjusted)
