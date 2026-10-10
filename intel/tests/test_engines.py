"""Stage-level behaviour against scenarios with known ground truth."""
import math

from autopsyx.core.models import NewsEvent, SocialPost
from autopsyx.detection.move import MoveClass, at_least
from autopsyx.narrative import leadlag
from autopsyx.news import catalyst
from autopsyx.news.taxonomy import EventType, classify_headline
from autopsyx.onchain.clusters import ClusterLabel
from autopsyx.onchain.wallet_skill import ClosedTrade, score_wallets, wilson_lower
from autopsyx.sim import generator
from autopsyx.social import attention

from conftest import key

ORGANIC, WASH, RUG, QUIET, FOLLOWER = (key(a) for a in ("PEPEaddr", "FROGaddr", "HAMSaddr", "CATZaddr", "DOGEaddr"))


def test_big_moves_classified_relative_to_own_history(result):
    a = result.assessments
    assert at_least(a[ORGANIC].move.move_class, MoveClass.SIGNIFICANT) and a[ORGANIC].move.direction == 1
    assert a[QUIET].move.move_class in (MoveClass.NORMAL, MoveClass.WATCH)


def test_onset_located_near_true_start(result):
    onset_bar = generator.DEFAULT_SCENARIOS[0].onset_bar
    onset = result.assessments[ORGANIC].move.onset_ts
    true = generator.T0 + onset_bar * generator.MIN
    assert abs(onset - true) <= 10 * generator.MIN


def test_every_window_reports_status_not_zero(result):
    for w in result.assessments[QUIET].market.windows.values():
        for obs in (w.z, w.volume_z, w.ret):
            assert obs.value is not None or obs.status.value != "OK"


def test_wash_cluster_detected_and_organic_independent(result):
    a = result.assessments
    assert a[WASH].clusters.label == ClusterLabel.SUSPICIOUS_PATTERN
    assert a[ORGANIC].clusters.label == ClusterLabel.INDEPENDENT
    assert a[WASH].participation.independence_ratio.value < a[ORGANIC].participation.independence_ratio.value


def test_manipulation_flags_carry_full_evidence(result):
    flags = result.assessments[WASH].manipulation.flags
    kinds = {f.kind for f in flags}
    assert {"wash_trading", "coordinated_cluster"} <= kinds
    for f in flags:
        assert f.evidence and f.methodology and f.alternative_explanation
        assert 0 <= f.confidence <= 1


def test_organic_move_not_flagged(result):
    assert result.assessments[ORGANIC].manipulation.score < 0.3


def test_creator_distribution_on_rug(result):
    kinds = {f.kind for f in result.assessments[RUG].manipulation.flags}
    assert "creator_distribution" in kinds


def test_news_first_classification(result):
    c = result.assessments[ORGANIC].catalyst
    assert c.timing == catalyst.CatalystTiming.NEWS_FIRST and c.confirmed and c.direction_consistent


def _news(ts, tier, source, etype="LISTING", story="s"):
    return NewsEvent(f"{source}{ts}", ts, ts + 1000, source, tier, "h", tokens=("solana:t",),
                     event_type=etype, story_id=story)


def test_news_timing_classes(cfg):
    nc = cfg.section("news")
    onset = 10_000_000
    assert catalyst.assess("solana:t", onset, 1, [], nc).timing == catalyst.CatalystTiming.NO_IDENTIFIED_CATALYST
    late = catalyst.assess("solana:t", onset, 1, [_news(onset + 300_000, 1, "ex")], nc)
    assert late.timing == catalyst.CatalystTiming.MOVE_FIRST
    same = catalyst.assess("solana:t", onset, 1, [_news(onset + 10_000, 1, "ex")], nc)
    assert same.timing == catalyst.CatalystTiming.SIMULTANEOUS
    both = catalyst.assess("solana:t", onset, 1, [_news(onset - 60_000, 1, "ex", "LISTING", "a"),
                                                  _news(onset - 50_000, 1, "ex2", "EXPLOIT", "b")], nc)
    assert both.timing == catalyst.CatalystTiming.CONFLICTING_INFORMATION


def test_unverified_social_post_is_not_confirmed_news(cfg):
    nc = cfg.section("news")
    one = catalyst.assess("solana:t", 10_000_000, 1, [_news(9_000_000, 4, "anon")], nc)
    assert not one.confirmed and one.credibility <= 0.3
    many_t4 = [_news(9_000_000 + i, 4, f"anon{i}") for i in range(10)]
    assert not catalyst.assess("solana:t", 10_000_000, 1, many_t4, nc).confirmed
    two_t3 = [_news(9_000_000, 3, "agg1"), _news(9_000_100, 3, "agg2")]
    assert catalyst.assess("solana:t", 10_000_000, 1, two_t3, nc).confirmed


def test_headline_classifier():
    assert classify_headline("Binance will list FOO") == EventType.LISTING
    assert classify_headline("Protocol drained in exploit") == EventType.EXPLOIT


def test_artificial_attention_higher_for_bot_posts(result):
    a = result.assessments
    assert a[WASH].social.artificial_attention_score.value > a[ORGANIC].social.artificial_attention_score.value
    # 20 posts per minute from 6 accounts should collapse to very few effective authors
    assert a[WASH].social.effective_authors.value < 0.1 * a[WASH].social.mentions.value


def test_duplicate_posts_collapse(cfg):
    posts = [SocialPost(str(i), "x", i, i, f"a{i % 2}", 0, 10, "buy FOO now to the moon", ("t",)) for i in range(50)]
    groups = attention.content_clusters(posts, 0.8)
    assert len(groups) == 1


def test_leader_follower(result):
    assert result.assessments[ORGANIC].role == leadlag.Role.LEADER.value
    assert result.assessments[FOLLOWER].role == leadlag.Role.FOLLOWER.value
    link = next(l for l in result.lead_lag if l.follower == FOLLOWER)
    assert link.leader == ORGANIC and link.lag_bars == 3


def test_leadlag_ignores_shared_trend():
    base = [0.01 if i > 60 else 0.0 for i in range(120)]
    a = [x + 0.001 * math.sin(i) for i, x in enumerate(base)]
    b = [x + 0.001 * math.cos(i * 1.7) for i, x in enumerate(base)]
    roles, links = leadlag.analyze({"a": a, "b": b}, set(), 10, 0.3)
    assert not links


def test_narrative_breadth(result):
    n = result.narratives["animal"]
    assert n.members == 5 and n.breadth >= 0.6


def test_wallet_skill_requires_evidence():
    one_lucky = [ClosedTrade("w", "t1", 0, 1, 1000, 100)]
    assert score_wallets(one_lucky, base_rate=0.4)["w"].label == "INSUFFICIENT_EVIDENCE"
    skilled = [ClosedTrade("s", f"t{i}", 0, 1, 50 if i % 10 else -10, 100) for i in range(60)]
    assert score_wallets(skilled, base_rate=0.4)["s"].label == "SKILLED"
    coin = [ClosedTrade("c", f"t{i}", 0, 1, 10 if i % 2 else -10, 100) for i in range(60)]
    assert score_wallets(coin, base_rate=0.45)["c"].label == "UNPROVEN"
    assert wilson_lower(0, 0) == 0.0
