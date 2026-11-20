"""Forward-outcome measurement for ATR-normalized shock events.

This module is research telemetry only. It consumes completed-bar OHLC and
ShockDNASnapshot-like objects, emits fixed-horizon outcomes, and never emits
trade instructions. Run one tracker per symbol/timeframe stream.

Returns and excursions are measured from the event bar close, using only
subsequent completed bars. This avoids crediting pre-entry event-bar highs or
lows to a hypothetical post-close reversal trade.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable


@dataclass(frozen=True)
class ShockOutcome:
    symbol: str
    timeframe: str
    event_timestamp: int
    observation_timestamp: int
    direction: int
    horizon_bars: int
    directional_return_pct: float
    max_favourable_excursion_pct: float
    max_adverse_excursion_pct: float
    shock_state_at_observation: str
    event_magnitude_atr: float
    onset_magnitude_atr: float
    confidence: float
    regime: str | None
    regime_strength: float
    transmission_available: bool
    cross_asset_confirmation: bool | None

    def as_dict(self) -> dict[str, Any]:
        return {
            "symbol": self.symbol,
            "timeframe": self.timeframe,
            "event_timestamp": self.event_timestamp,
            "observation_timestamp": self.observation_timestamp,
            "direction": self.direction,
            "horizon_bars": self.horizon_bars,
            "directional_return_pct": self.directional_return_pct,
            "max_favourable_excursion_pct": self.max_favourable_excursion_pct,
            "max_adverse_excursion_pct": self.max_adverse_excursion_pct,
            "shock_state_at_observation": self.shock_state_at_observation,
            "event_magnitude_atr": self.event_magnitude_atr,
            "onset_magnitude_atr": self.onset_magnitude_atr,
            "confidence": self.confidence,
            "regime": self.regime,
            "regime_strength": self.regime_strength,
            "transmission_available": self.transmission_available,
            "cross_asset_confirmation": self.cross_asset_confirmation,
        }


@dataclass
class _TrackedEvent:
    timestamp: int
    entry_close: float
    direction: int
    onset_magnitude_atr: float
    onset_confidence: float
    regime: str | None
    regime_strength: float
    transmission_available: bool
    cross_asset_confirmation: bool | None
    elapsed_bars: int = 0
    max_favourable_pct: float = 0.0
    max_adverse_pct: float = 0.0
    emitted_horizons: set[int] = field(default_factory=set)


class ShockOutcomeTracker:
    """Measure forward returns and excursions at fixed completed-bar horizons."""

    def __init__(self, horizons: Iterable[int] = (1, 3, 5, 10)) -> None:
        normalized = tuple(sorted(set(int(h) for h in horizons)))
        if not normalized or normalized[0] <= 0:
            raise ValueError("horizons must contain positive, unique bar counts")
        self.horizons = normalized
        self._active: list[_TrackedEvent] = []
        self._last_timestamp: int | None = None

    @staticmethod
    def _state_name(snapshot: Any) -> str:
        state = getattr(snapshot, "shock_state", "UNKNOWN")
        return str(getattr(state, "value", state))

    def update(
        self,
        *,
        symbol: str,
        timeframe: str,
        timestamp: int,
        open_price: float,
        high: float,
        low: float,
        close: float,
        snapshot: Any,
    ) -> list[ShockOutcome]:
        """Consume exactly one completed bar and return newly matured outcomes.

        Invalid snapshots, non-finite prices, duplicate timestamps, and
        out-of-order bars are rejected without advancing active event clocks.
        """
        import math

        if timestamp is None or timestamp <= 0:
            return []
        if self._last_timestamp is not None and timestamp <= self._last_timestamp:
            return []
        prices = (open_price, high, low, close)
        if not all(math.isfinite(float(p)) and float(p) > 0 for p in prices):
            return []
        if high < low or high < max(open_price, close) or low > min(open_price, close):
            return []
        if not bool(getattr(snapshot, "valid", False)) or not bool(
            getattr(snapshot, "data_quality_ok", False)
        ):
            return []

        self._last_timestamp = int(timestamp)
        outcomes: list[ShockOutcome] = []

        # Existing events are marked using this bar, which is strictly after
        # their event close. The event's own bar is never counted as excursion.
        survivors: list[_TrackedEvent] = []
        for event in self._active:
            event.elapsed_bars += 1
            if event.direction > 0:
                favourable = (high / event.entry_close - 1.0) * 100.0
                adverse = (low / event.entry_close - 1.0) * 100.0
                directional_return = (close / event.entry_close - 1.0) * 100.0
            else:
                favourable = (event.entry_close / low - 1.0) * 100.0
                adverse = (event.entry_close / high - 1.0) * 100.0
                directional_return = (event.entry_close / close - 1.0) * 100.0

            event.max_favourable_pct = max(event.max_favourable_pct, favourable)
            event.max_adverse_pct = min(event.max_adverse_pct, adverse)

            for horizon in self.horizons:
                if event.elapsed_bars != horizon or horizon in event.emitted_horizons:
                    continue
                event.emitted_horizons.add(horizon)
                outcomes.append(
                    ShockOutcome(
                        symbol=symbol,
                        timeframe=timeframe,
                        event_timestamp=event.timestamp,
                        observation_timestamp=int(timestamp),
                        direction=event.direction,
                        horizon_bars=horizon,
                        directional_return_pct=directional_return,
                        max_favourable_excursion_pct=event.max_favourable_pct,
                        max_adverse_excursion_pct=event.max_adverse_pct,
                        shock_state_at_observation=self._state_name(snapshot),
                        event_magnitude_atr=float(getattr(snapshot, "event_magnitude_atr", 0.0)),
                        onset_magnitude_atr=event.onset_magnitude_atr,
                        confidence=event.onset_confidence,
                        regime=event.regime,
                        regime_strength=event.regime_strength,
                        transmission_available=event.transmission_available,
                        cross_asset_confirmation=event.cross_asset_confirmation,
                    )
                )

            if event.elapsed_bars < self.horizons[-1]:
                survivors.append(event)

        self._active = survivors

        # A fresh ONSET starts a new independent event after existing events
        # have been updated, so the onset bar cannot count as a forward bar.
        state_name = self._state_name(snapshot).upper()
        if (
            bool(getattr(snapshot, "shock_detected", False))
            and int(getattr(snapshot, "direction", 0)) in (-1, 1)
            and int(getattr(snapshot, "persistence_bars", -1)) == 0
            and state_name.endswith("ONSET")
        ):
            self._active.append(
                _TrackedEvent(
                    timestamp=int(timestamp),
                    entry_close=float(close),
                    direction=int(snapshot.direction),
                    onset_magnitude_atr=float(getattr(snapshot, "normalized_magnitude", 0.0)),
                    onset_confidence=float(getattr(snapshot, "confidence", 0.0)),
                    regime=getattr(snapshot, "regime", None),
                    regime_strength=float(getattr(snapshot, "regime_strength", 0.0)),
                    transmission_available=bool(getattr(snapshot, "transmission_available", False)),
                    cross_asset_confirmation=getattr(snapshot, "cross_asset_confirmation", None),
                )
            )
        return outcomes

    @property
    def active_event_count(self) -> int:
        return len(self._active)
