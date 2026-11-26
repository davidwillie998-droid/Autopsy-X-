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
    assert round(one_bar["directional_mfe_pct"], 6) == round((108 / 102 - 1) * 100, 6)
    assert round(one_bar["directional_mae_pct"], 6) == round((101 / 102 - 1) * 100, 6)
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



def test_bearish_excursions_reverse_high_low_roles(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    write_csv(journal, [{
        "bar_time": "2026.01.01 00:00", "symbol": "TEST",
        "timeframe": "PERIOD_M5", "prior_impulse_direction": "-1",
    }], ["bar_time", "symbol", "timeframe", "prior_impulse_direction"])
    write_csv(ohlc, [
        {"timestamp": "2026.01.01 00:00", "symbol": "TEST", "timeframe": "PERIOD_M5",
         "open": "100", "high": "101", "low": "99", "close": "100"},
        {"timestamp": "2026.01.01 00:05", "symbol": "TEST", "timeframe": "PERIOD_M5",
         "open": "100", "high": "103", "low": "95", "close": "97"},
    ], ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])

    observations, _ = EVALUATOR.evaluate(journal, ohlc, [1])
    assert round(observations[0]["directional_mfe_pct"], 6) == round((100 / 95 - 1) * 100, 6)
    assert round(observations[0]["directional_mae_pct"], 6) == round((100 / 103 - 1) * 100, 6)


def test_chronological_splits_purge_forward_windows_and_deduplicate(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    rows = []
    for i in range(10):
        stamp = f"2026.01.01 00:{i:02d}"
        rows.append({
            "timestamp": stamp, "symbol": "TEST", "timeframe": "PERIOD_M1",
            "open": str(100 + i), "high": str(102 + i),
            "low": str(99 + i), "close": str(101 + i),
        })
    write_csv(ohlc, rows, ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])
    observations = [
        {"bar_time": "2026.01.01 00:05", "symbol": "TEST", "timeframe": "PERIOD_M1", "prior_impulse_direction": "1"},
        {"bar_time": "2026.01.01 00:05", "symbol": "TEST", "timeframe": "PERIOD_M1", "prior_impulse_direction": "1"},
        {"bar_time": "2026.01.01 00:06", "symbol": "TEST", "timeframe": "PERIOD_M1", "prior_impulse_direction": "1"},
        {"bar_time": "2026.01.01 00:08", "symbol": "TEST", "timeframe": "PERIOD_M1", "prior_impulse_direction": "1"},
    ]
    write_csv(journal, observations, ["bar_time", "symbol", "timeframe", "prior_impulse_direction"])

    evaluated, report = EVALUATOR.evaluate(journal, ohlc, [1])
    assert len(evaluated) == 2
    assert {row["split"] for row in evaluated} == {"validation", "test"}
    assert report["metadata"]["exclusions"]["duplicate_journal_observation"] == 1
    assert report["metadata"]["exclusions"]["forward_window_crosses_split_boundary"] == 1
    assert "first 60% train" in report["metadata"]["split_policy"]


def test_duplicate_ohlc_timestamps_are_rejected(tmp_path):
    ohlc = tmp_path / "ohlc.csv"
    row = {"timestamp": "2026.01.01 00:00", "symbol": "TEST", "timeframe": "M1",
           "open": "100", "high": "101", "low": "99", "close": "100"}
    write_csv(ohlc, [row, row], ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])
    try:
        EVALUATOR.load_bars(ohlc)
    except ValueError as error:
        assert "Duplicate OHLC timestamps" in str(error)
    else:
        raise AssertionError("Duplicate OHLC timestamps must be rejected")



def test_feature_buckets_use_fixed_predeclared_boundaries():
    assert EVALUATOR.fixed_bucket("-0.01", [0.0, 0.25, 0.5, 0.75],
                                  ["NEGATIVE", "0_TO_025", "025_TO_050", "050_TO_075", "GE_075"]) == "NEGATIVE"
    assert EVALUATOR.fixed_bucket("0.25", [0.0, 0.25, 0.5, 0.75],
                                  ["NEGATIVE", "0_TO_025", "025_TO_050", "050_TO_075", "GE_075"]) == "025_TO_050"
    assert EVALUATOR.fixed_bucket("", [0.25, 0.5], ["LOW", "MID", "HIGH"]) == "UNAVAILABLE"


def test_inference_is_suppressed_below_thirty_directional_observations(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    journal_rows = []
    bars = []
    for i in range(40):
        stamp = f"2026.01.01 00:{i:02d}"
        bars.append({
            "timestamp": stamp, "symbol": "TEST", "timeframe": "PERIOD_M1",
            "open": str(100 + i), "high": str(102 + i),
            "low": str(99 + i), "close": str(101 + i),
        })
        if i < 20:
            journal_rows.append({
                "bar_time": stamp, "symbol": "TEST", "timeframe": "PERIOD_M1",
                "prior_impulse_direction": "1", "candle_state": "BULL_BODY",
                "body_ratio": "0.7", "close_location": "0.8", "pullback_depth": "0.1",
            })
    fields = ["bar_time", "symbol", "timeframe", "prior_impulse_direction",
              "candle_state", "body_ratio", "close_location", "pullback_depth"]
    write_csv(journal, journal_rows, fields)
    write_csv(ohlc, bars, ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])

    _, report = EVALUATOR.evaluate(journal, ohlc, [1])
    baseline = next(group for group in report["groups"] if group["feature"] == "BASELINE")
    assert baseline["directional_observations"] < 30
    assert baseline["newey_west_p_value"] is None
    assert baseline["inference_status"].startswith("DESCRIPTIVE_ONLY")


def test_feature_groups_are_reported_separately_by_split_and_horizon(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    journal_rows = []
    bars = []
    for i in range(50):
        stamp = f"2026.01.01 00:{i:02d}"
        bars.append({
            "timestamp": stamp, "symbol": "TEST", "timeframe": "PERIOD_M1",
            "open": str(100 + i), "high": str(102 + i),
            "low": str(99 + i), "close": str(101 + i),
        })
        if i < 45:
            journal_rows.append({
                "bar_time": stamp, "symbol": "TEST", "timeframe": "PERIOD_M1",
                "prior_impulse_direction": "1", "candle_state": "BULL_BODY",
                "body_ratio": "0.7", "close_location": "0.8", "pullback_depth": "0.1",
            })
    write_csv(journal, journal_rows, ["bar_time", "symbol", "timeframe", "prior_impulse_direction",
                                      "candle_state", "body_ratio", "close_location", "pullback_depth"])
    write_csv(ohlc, bars, ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])

    _, report = EVALUATOR.evaluate(journal, ohlc, [1, 3])
    candle_groups = [g for g in report["groups"] if g["feature"] == "candle_state"]
    conditional_groups = [g for g in report["groups"] if g["feature"] == "candle_state_GIVEN_IMPULSE"]
    assert candle_groups
    assert conditional_groups
    assert all("|impulse=BULLISH" in g["feature_value"] for g in conditional_groups)
    assert {g["split"] for g in candle_groups} <= {"train", "validation", "test"}
    assert {g["horizon_bars"] for g in candle_groups} == {1, 3}
    assert all(g["feature_value"] == "BULL_BODY" for g in candle_groups)
    assert report["metadata"]["minimum_directional_observations_for_inference"] == 30
    assert "same broker/server timezone" in report["metadata"]["timestamp_policy"]


def test_invalid_impulse_encoding_is_excluded(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    write_csv(journal, [{
        "bar_time": "2026.01.01 00:00", "symbol": "TEST",
        "timeframe": "PERIOD_M1", "prior_impulse_direction": "2",
    }], ["bar_time", "symbol", "timeframe", "prior_impulse_direction"])
    write_csv(ohlc, [{
        "timestamp": "2026.01.01 00:00", "symbol": "TEST", "timeframe": "PERIOD_M1",
        "open": "100", "high": "101", "low": "99", "close": "100",
    }], ["timestamp", "symbol", "timeframe", "open", "high", "low", "close"])

    observations, report = EVALUATOR.evaluate(journal, ohlc, [1])
    assert observations == []
    assert report["metadata"]["exclusions"]["invalid_journal_row"] == 1



def test_feature_uplift_uses_complementary_categories_within_impulse_direction(tmp_path):
    journal = tmp_path / "journal.csv"
    ohlc = tmp_path / "ohlc.csv"
    bars = []
    closes = [100.0]
    for i in range(39):
        next_close = closes[-1] * (1.01 if i % 2 == 0 else 0.99)
        closes.append(next_close)
    for i, close in enumerate(closes):
        open_price = closes[i - 1] if i else close
        bars.append({
            "timestamp": f"2026.01.01 00:{i:02d}",
            "symbol": "TEST", "timeframe": "PERIOD_M1",
            "open": str(open_price),
            "high": str(max(open_price, close) + 0.1),
            "low": str(min(open_price, close) - 0.1),
            "close": str(close),
        })
    journal_rows = []
    for i in range(23):
        journal_rows.append({
            "bar_time": f"2026.01.01 00:{i:02d}",
            "symbol": "TEST", "timeframe": "PERIOD_M1",
            "prior_impulse_direction": "1",
            "candle_state": "BULL_BODY" if i % 2 == 0 else "BEAR_BODY",
            "body_ratio": "0.7" if i % 2 == 0 else "0.2",
            "close_location": "0.8" if i % 2 == 0 else "0.2",
            "pullback_depth": "0.1" if i % 2 == 0 else "0.6",
        })
    write_csv(journal, journal_rows, ["bar_time", "symbol", "timeframe",
        "prior_impulse_direction", "candle_state", "body_ratio",
        "close_location", "pullback_depth"])
    write_csv(ohlc, bars, ["timestamp", "symbol", "timeframe",
        "open", "high", "low", "close"])

    _, report = EVALUATOR.evaluate(journal, ohlc, [1])
    groups = [g for g in report["groups"]
              if g["feature"] == "candle_state" and g["split"] == "train"]
    bullish = next(g for g in groups if g["feature_value"] == "BULL_BODY")
    bearish = next(g for g in groups if g["feature_value"] == "BEAR_BODY")
    assert bullish["complementary_baseline_observations"] > 0
    assert bullish["mean_signed_return_uplift_vs_complement_pct"] > 0
    assert bearish["mean_signed_return_uplift_vs_complement_pct"] < 0
    assert bullish["directional_hit_rate_uplift_vs_complement_pp"] > 0
