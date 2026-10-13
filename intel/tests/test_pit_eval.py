import pytest

from autopsyx.research.pit_eval import (
    FeatureAvailability,
    PointInTimeViolation,
    validate_feature_set,
)


def test_feature_is_legal_when_all_inputs_and_computation_precede_decision():
    FeatureAvailability("buy_imbalance", (100, 110, 115), 120).validate_at(120)


@pytest.mark.parametrize(
    "feature,decision",
    [
        (FeatureAvailability("late_input", (100, 131), 132), 130),
        (FeatureAvailability("late_compute", (100, 110), 131), 130),
        (FeatureAvailability("impossible_compute", (100, 120), 110), 130),
    ],
)
def test_rejects_information_not_ready_at_decision(feature, decision):
    with pytest.raises(PointInTimeViolation):
        feature.validate_at(decision)


def test_missing_source_timing_is_not_silently_treated_as_zero():
    with pytest.raises(PointInTimeViolation, match="must not be empty"):
        FeatureAvailability("wallet_flow", (), 100).validate_at(110)


@pytest.mark.parametrize("bad_ts", [-1, True, 1.5, "100"])
def test_rejects_invalid_timestamp_types(bad_ts):
    with pytest.raises(PointInTimeViolation):
        FeatureAvailability("price", (bad_ts,), 10).validate_at(11)


def test_feature_set_rejects_duplicate_names():
    feature = FeatureAvailability("price_return_5", (100,), 101)
    with pytest.raises(PointInTimeViolation, match="duplicate"):
        validate_feature_set([feature, feature], 110)


def test_feature_set_validates_all_features():
    features = [
        FeatureAvailability("price_return_5", (100,), 101),
        FeatureAvailability("wallet_flow", (105, 107), 108),
    ]
    validate_feature_set(features, 110)
