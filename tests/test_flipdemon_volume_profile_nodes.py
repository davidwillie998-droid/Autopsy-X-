"""Deterministic regression fixtures for Volume Profile HVN/LVN classification.

The pure-Python fixtures validate the documented classification contract. The
source-contract checks bind the fixture assumptions to VolumeProfile.mqh, but
this is not execution of MQL5 and does not replace MetaEditor compilation.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "MQL5/Include/AutopsyX/VolumeProfile.mqh"


def classify_nodes(bins, bin_size=1.0):
    """Reference implementation of the MQL5 node rules.

    bins is a sequence of (price, volume) pairs. Only occupied bins within
    1.5 bin widths count as neighbors.
    """
    ordered = sorted(bins)
    if not ordered:
        return [], []
    mean_volume = sum(volume for _, volume in ordered) / len(ordered)
    high_threshold = mean_volume * 1.50
    low_threshold = mean_volume * 0.50
    hvn, lvn = [], []

    for index, (price, volume) in enumerate(ordered):
        has_below = (
            index > 0
            and abs(price - ordered[index - 1][0]) <= bin_size * 1.5
        )
        has_above = (
            index < len(ordered) - 1
            and abs(price - ordered[index + 1][0]) <= bin_size * 1.5
        )
        below = ordered[index - 1][1] if has_below else 0.0
        above = ordered[index + 1][1] if has_above else 0.0

        local_high = (
            volume >= high_threshold
            and (not has_below or volume >= below)
            and (not has_above or volume >= above)
            and ((has_below and volume > below) or
                 (has_above and volume > above))
        )
        local_low = (
            has_below and has_above
            and volume > 0
            and volume <= low_threshold
            and volume <= below
            and volume <= above
            and (volume < below or volume < above)
        )
        if local_high:
            hvn.append(price)
        if local_low:
            lvn.append(price)
    return hvn, lvn


class VolumeProfileNodeFixtureTests(unittest.TestCase):
    def test_single_interior_high_volume_node(self):
        hvn, lvn = classify_nodes(
            [(0, 1), (1, 1), (2, 10), (3, 1), (4, 1)]
        )
        self.assertEqual(hvn, [2])
        self.assertEqual(lvn, [])

    def test_single_interior_low_volume_node(self):
        hvn, lvn = classify_nodes(
            [(0, 10), (1, 10), (2, 1), (3, 10), (4, 10)]
        )
        self.assertEqual(hvn, [])
        self.assertEqual(lvn, [2])

    def test_flat_distribution_has_no_nodes(self):
        self.assertEqual(
            classify_nodes([(0, 5), (1, 5), (2, 5), (3, 5), (4, 5)]),
            ([], []),
        )

    def test_sparse_gap_does_not_create_false_low_nodes(self):
        hvn, lvn = classify_nodes(
            [(0, 10), (1, 1), (10, 1), (11, 10)]
        )
        self.assertEqual(hvn, [0, 11])
        self.assertEqual(lvn, [])

    def test_edge_peak_can_be_hvn_but_edge_cannot_be_lvn(self):
        hvn, lvn = classify_nodes([(0, 10), (1, 1)])
        self.assertEqual(hvn, [0])
        self.assertEqual(lvn, [])

    def test_empty_and_single_bin_profiles_have_no_nodes(self):
        self.assertEqual(classify_nodes([]), ([], []))
        self.assertEqual(classify_nodes([(10, 100)]), ([], []))

    def test_source_implements_the_fixture_contract(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("double highThreshold=meanVolume*1.50;", source)
        self.assertIn("double lowThreshold=meanVolume*0.50;", source)
        self.assertIn("<=m_binSize*1.5", source)
        self.assertIn("bool localLow=(hasBelow && hasAbove", source)
        self.assertIn("NearestHighVolumeNode", source)
        self.assertIn("NearestLowVolumeNode", source)


if __name__ == "__main__":
    unittest.main()
