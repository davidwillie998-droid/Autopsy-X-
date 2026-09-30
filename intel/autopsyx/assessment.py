"""The structured output of the per-token pipeline. Every stage's result is a
field here; nothing is recomputed downstream and nothing is hidden."""
from __future__ import annotations

from dataclasses import dataclass, field

from .core.failure import FailureMode
from .core.models import Bar, TokenMeta
from .core.values import Obs, missing
from .detection.move import MoveAssessment
from .detection.move_quality import MoveQuality
from .features.liquidity import LiquidityState
from .features.market import MarketState
from .features.participation import Participation
from .manipulation.detectors import ManipulationReport
from .news.catalyst import CatalystAssessment
from .onchain.clusters import ClusterReport
from .quality.checks import QualityReport
from .regime.classifier import RegimeAssessment
from .signals.exhaustion import ExhaustionAssessment
from .social.attention import AttentionState


@dataclass
class Assessment:
    token: TokenMeta
    as_of: int
    quality: QualityReport
    bars: list[Bar]
    market: MarketState
    move: MoveAssessment
    participation: Participation
    liquidity: LiquidityState
    clusters: ClusterReport
    manipulation: ManipulationReport
    catalyst: CatalystAssessment
    social: AttentionState
    regime: RegimeAssessment
    exhaustion: ExhaustionAssessment
    narratives: list[str] = field(default_factory=list)
    narrative_breadth: Obs = field(default_factory=lambda: missing("narrative stage not run"))
    narrative_phases: dict[str, str] = field(default_factory=dict)
    cross_venue: Obs = field(default_factory=lambda: missing("single venue observed"))
    role: str = "ISOLATED_MOVE"
    move_quality: MoveQuality | None = None

    @property
    def key(self) -> str:
        return self.token.ref.key

    @property
    def failures(self) -> set[FailureMode]:
        return self.quality.failures

    def to_dict(self) -> dict:
        return {
            "token": {"key": self.key, "symbol": self.token.symbol, "name": self.token.name},
            "as_of": self.as_of,
            "quality": self.quality.to_dict(),
            "move": self.move.to_dict(),
            "market": {n: w.to_dict() for n, w in self.market.windows.items()},
            "participation": self.participation.to_dict(),
            "liquidity": self.liquidity.to_dict(),
            "clusters": self.clusters.to_dict(),
            "manipulation": self.manipulation.to_dict(),
            "catalyst": self.catalyst.to_dict(),
            "social": self.social.to_dict(),
            "regime": self.regime.to_dict(),
            "exhaustion": self.exhaustion.to_dict(),
            "narratives": self.narratives,
            "narrative_phases": self.narrative_phases,
            "narrative_breadth": self.narrative_breadth.to_dict(),
            "cross_venue": self.cross_venue.to_dict(),
            "role": self.role,
            "move_quality": self.move_quality.to_dict() if self.move_quality else None,
        }
