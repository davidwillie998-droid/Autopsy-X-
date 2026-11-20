"""Persistent, point-in-time outcome measurement for AUTOPSY X shock events.

Research-only. No trade instructions, entry scoring, or execution dependencies.

Return convention:
  underlying_return_pct = (exit / entry - 1) * 100
  directional_return_pct = direction * underlying_return_pct
This is simple notional P&L for a unit long/short position, before costs,
financing, spread, slippage, and contract-specific valuation.
"""
from __future__ import annotations

import csv
import hashlib
import json
import math
import sqlite3
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable


@dataclass(frozen=True)
class ShockOutcome:
    event_id: str
    symbol: str
    timeframe: str
    event_timestamp: int
    observation_timestamp: int
    direction: int
    horizon_bars: int
    entry_close: float
    exit_close: float
    underlying_return_pct: float
    directional_return_pct: float
    max_favourable_excursion_pct: float
    max_adverse_excursion_pct: float
    shock_state_at_observation: str
    event_magnitude_at_observation_atr: float
    onset_magnitude_atr: float
    onset_confidence: float
    onset_regime: str | None
    onset_regime_strength: float
    transmission_available_at_onset: bool
    transmission_state_at_onset: str | None
    cross_asset_confirmation_at_onset: bool | None

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class _TrackedEvent:
    event_id: str
    symbol: str
    timeframe: str
    timestamp: int
    entry_close: float
    direction: int
    onset_magnitude_atr: float
    onset_confidence: float
    regime: str | None
    regime_strength: float
    transmission_available: bool
    cross_asset_confirmation: bool | None
    transmission_state: str | None = None
    elapsed_bars: int = 0
    max_favourable_pct: float = 0.0
    max_adverse_pct: float = 0.0
    emitted_horizons: set[int] = field(default_factory=set)


class ShockSnapshotAdapter:
    """Normalize the Python and MQL5 ShockDNA snapshot contracts.

    MQL5 fields crossAssetConfirmationAvailable/crossAssetConfirmation map to
    Python's Optional[bool]. MQL5 enum values 0..8 follow ShockDNAEngine.mqh.
    """

    _MQL_STATES = {
        0: "UNKNOWN", 1: "INSUFFICIENT_DATA", 2: "NONE", 3: "ONSET",
        4: "IMPULSE", 5: "FOLLOW_THROUGH", 6: "ABSORPTION",
        7: "REVERSAL", 8: "NORMALIZING",
    }
    _MQL_REGIMES = {
        0: "UNAVAILABLE", 1: "R1_PERSISTENT_BULLISH_TREND",
        2: "R2_BULLISH_UNSTABLE", 3: "R3_RANGE_CHOP",
        4: "R4_BEARISH_TRANSITION", 5: "R5_PERSISTENT_BEARISH_TREND",
        6: "R6_VOLATILITY_SHOCK", 7: "R7_INFORMATION_CONFLICT",
        8: "R8_STRUCTURAL_BREAK",
    }
    _MQL_TRANSMISSION = {
        0: "UNKNOWN", 1: "INSUFFICIENT_DATA", 2: "INACTIVE",
        3: "LEADER", 4: "CONFIRMING", 5: "WEAKENING",
        6: "DIVERGING", 7: "INVERTED",
    }

    @classmethod
    def from_mql5(cls, payload: dict[str, Any]) -> dict[str, Any]:
        state = payload.get("shockState", "UNKNOWN")
        if isinstance(state, int):
            state = cls._MQL_STATES.get(state, "UNKNOWN")
        else:
            state = str(state).upper().replace(" ", "_")
        regime = payload.get("regime")
        if isinstance(regime, int):
            regime = cls._MQL_REGIMES.get(regime, "UNAVAILABLE")
        transmission_state = payload.get("transmissionState")
        if isinstance(transmission_state, int):
            transmission_state = cls._MQL_TRANSMISSION.get(transmission_state, "UNKNOWN")
        confirmation_available = bool(payload.get("crossAssetConfirmationAvailable", False))
        confirmation = (
            bool(payload.get("crossAssetConfirmation", False))
            if confirmation_available else None
        )
        return {
            "timestamp": payload.get("timestamp"),
            "valid": bool(payload.get("valid", False)),
            "data_quality_ok": bool(payload.get("dataQualityOk", False)),
            "data_quality_reason": str(payload.get("dataQualityReason", "")),
            "shock_detected": bool(payload.get("shockDetected", False)),
            "shock_state": state,
            "direction": int(payload.get("direction", 0)),
            "persistence_bars": int(payload.get("persistenceBars", -1)),
            "normalized_magnitude": float(payload.get("normalizedMagnitude", 0.0)),
            "event_magnitude_atr": float(payload.get("eventMagnitudeAtr", 0.0)),
            "confidence": float(payload.get("confidence", 0.0)),
            "regime": str(regime) if regime is not None else None,
            "regime_strength": float(payload.get("regimeStrength", 0.0)),
            "information_transmission_state": (
                str(transmission_state) if transmission_state is not None else None
            ),
            "transmission_available": bool(payload.get("transmissionAvailable", False)),
            "cross_asset_confirmation": confirmation,
        }


class ShockEventLedger:
    """SQLite persistence for active events and matured horizon observations."""

    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(self.path)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.executescript("""
            CREATE TABLE IF NOT EXISTS active_events (
                event_id TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS stream_watermarks (
                symbol TEXT NOT NULL,
                timeframe TEXT NOT NULL,
                last_timestamp INTEGER NOT NULL,
                PRIMARY KEY(symbol,timeframe)
            );
            CREATE TABLE IF NOT EXISTS seen_events (
                event_id TEXT PRIMARY KEY,
                created_timestamp INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS outcomes (
                event_id TEXT NOT NULL,
                horizon_bars INTEGER NOT NULL,
                event_timestamp INTEGER NOT NULL,
                observation_timestamp INTEGER NOT NULL,
                symbol TEXT NOT NULL,
                timeframe TEXT NOT NULL,
                direction INTEGER NOT NULL,
                payload TEXT NOT NULL,
                PRIMARY KEY(event_id, horizon_bars)
            );
            CREATE INDEX IF NOT EXISTS idx_outcomes_symbol_tf
                ON outcomes(symbol, timeframe, horizon_bars);
        """)
        self.connection.commit()

    @contextmanager
    def transaction(self):
        """Commit one complete bar update atomically, including its watermark."""
        self.connection.execute("BEGIN IMMEDIATE")
        try:
            yield
        except Exception:
            self.connection.rollback()
            raise
        else:
            self.connection.commit()

    def load_watermarks(self) -> dict[tuple[str, str], int]:
        rows = self.connection.execute(
            "SELECT symbol,timeframe,last_timestamp FROM stream_watermarks"
        ).fetchall()
        return {(r["symbol"], r["timeframe"]): int(r["last_timestamp"]) for r in rows}

    def save_watermark(self, symbol: str, timeframe: str, timestamp: int) -> None:
        self.connection.execute(
            "INSERT INTO stream_watermarks(symbol,timeframe,last_timestamp) VALUES(?,?,?) "
            "ON CONFLICT(symbol,timeframe) DO UPDATE SET last_timestamp=MAX(last_timestamp,excluded.last_timestamp)",
            (symbol.upper(), timeframe.upper(), int(timestamp)),
        )
        if not self.connection.in_transaction:
            self.connection.commit()

    def register_event_once(self, event_id: str, timestamp: int) -> bool:
        cursor = self.connection.execute(
            "INSERT OR IGNORE INTO seen_events(event_id,created_timestamp) VALUES(?,?)",
            (event_id, int(timestamp)),
        )
        if not self.connection.in_transaction:
            self.connection.commit()
        return cursor.rowcount == 1

    def save_active(self, event: _TrackedEvent) -> None:
        payload = asdict(event)
        payload["emitted_horizons"] = sorted(event.emitted_horizons)
        self.connection.execute(
            "INSERT INTO active_events(event_id,payload) VALUES(?,?) "
            "ON CONFLICT(event_id) DO UPDATE SET payload=excluded.payload",
            (event.event_id, json.dumps(payload, sort_keys=True)),
        )
        if not self.connection.in_transaction:
            self.connection.commit()

    def delete_active(self, event_id: str) -> None:
        self.connection.execute("DELETE FROM active_events WHERE event_id=?", (event_id,))
        self.connection.commit()

    def load_active(self) -> list[_TrackedEvent]:
        rows = self.connection.execute("SELECT payload FROM active_events").fetchall()
        events = []
        for row in rows:
            payload = json.loads(row["payload"])
            payload["emitted_horizons"] = set(payload.get("emitted_horizons", []))
            events.append(_TrackedEvent(**payload))
        return events

    def save_outcome(self, outcome: ShockOutcome) -> None:
        payload = json.dumps(outcome.as_dict(), sort_keys=True)
        self.connection.execute(
            "INSERT OR IGNORE INTO outcomes "
            "(event_id,horizon_bars,event_timestamp,observation_timestamp,symbol,timeframe,direction,payload) "
            "VALUES(?,?,?,?,?,?,?,?)",
            (outcome.event_id, outcome.horizon_bars, outcome.event_timestamp,
             outcome.observation_timestamp, outcome.symbol, outcome.timeframe,
             outcome.direction, payload),
        )
        if not self.connection.in_transaction:
            self.connection.commit()

    def export_csv(self, destination: str | Path) -> int:
        rows = self.connection.execute(
            "SELECT payload FROM outcomes ORDER BY event_timestamp,event_id,horizon_bars"
        ).fetchall()
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not rows:
            destination.write_text("", encoding="utf-8")
            return 0
        records = [json.loads(row["payload"]) for row in rows]
        with destination.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(records[0].keys()))
            writer.writeheader()
            writer.writerows(records)
        return len(records)

    def close(self) -> None:
        self.connection.close()


class ShockOutcomeTracker:
    """Track completed-bar forward returns and persist event lifecycle state."""

    def __init__(
        self,
        horizons: Iterable[int] = (1, 3, 5, 10),
        *,
        ledger: ShockEventLedger | None = None,
    ) -> None:
        normalized = tuple(sorted(set(int(h) for h in horizons)))
        if not normalized or normalized[0] <= 0:
            raise ValueError("horizons must contain positive, unique bar counts")
        self.horizons = normalized
        self.ledger = ledger
        self._active = ledger.load_active() if ledger else []
        self._last_timestamp_by_stream: dict[tuple[str, str], int] = (
            ledger.load_watermarks() if ledger else {}
        )

    @staticmethod
    def _get(snapshot: Any, name: str, default: Any = None) -> Any:
        if isinstance(snapshot, dict):
            return snapshot.get(name, default)
        return getattr(snapshot, name, default)

    @classmethod
    def _state_name(cls, snapshot: Any) -> str:
        state = cls._get(snapshot, "shock_state", "UNKNOWN")
        return str(getattr(state, "value", state)).upper().replace(" ", "_")

    @staticmethod
    def _event_id(symbol: str, timeframe: str, timestamp: int, direction: int) -> str:
        raw = f"{symbol.upper()}|{timeframe.upper()}|{timestamp}|{direction}"
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]

    def _update_one_bar(
        self, *, symbol: str, timeframe: str, timestamp: int,
        open_price: float, high: float, low: float, close: float, snapshot: Any,
    ) -> list[ShockOutcome]:
        if timestamp is None or timestamp <= 0:
            return []
        stream = (symbol.upper(), timeframe.upper())
        last = self._last_timestamp_by_stream.get(stream)
        if last is not None and timestamp <= last:
            return []
        # The watermark advances on every newer timestamp, including rejected
        # observations, so delayed stale data cannot enter later.
        self._last_timestamp_by_stream[stream] = int(timestamp)
        if self.ledger:
            self.ledger.save_watermark(stream[0], stream[1], int(timestamp))

        prices = (open_price, high, low, close)
        try:
            sane = all(math.isfinite(float(p)) and float(p) > 0 for p in prices)
        except (TypeError, ValueError):
            sane = False
        if not sane or high < low or high < max(open_price, close) or low > min(open_price, close):
            return []
        if not bool(self._get(snapshot, "valid", False)) or not bool(
            self._get(snapshot, "data_quality_ok", False)
        ):
            return []
        snapshot_time = self._get(snapshot, "timestamp")
        if snapshot_time not in (None, 0, timestamp):
            return []

        outcomes: list[ShockOutcome] = []
        survivors: list[_TrackedEvent] = []
        for event in self._active:
            if (event.symbol.upper(), event.timeframe.upper()) != stream:
                survivors.append(event)
                continue
            event.elapsed_bars += 1
            underlying_return = (close / event.entry_close - 1.0) * 100.0
            directional_return = event.direction * underlying_return
            if event.direction > 0:
                favourable = max(0.0, (high / event.entry_close - 1.0) * 100.0)
                adverse = max(0.0, (event.entry_close - low) / event.entry_close * 100.0)
            else:
                # Simple notional short P&L convention, not reciprocal return.
                favourable = max(0.0, (event.entry_close - low) / event.entry_close * 100.0)
                adverse = max(0.0, (high / event.entry_close - 1.0) * 100.0)
            event.max_favourable_pct = max(event.max_favourable_pct, favourable)
            event.max_adverse_pct = max(event.max_adverse_pct, adverse)

            if event.elapsed_bars in self.horizons and event.elapsed_bars not in event.emitted_horizons:
                event.emitted_horizons.add(event.elapsed_bars)
                outcome = ShockOutcome(
                    event_id=event.event_id, symbol=event.symbol, timeframe=event.timeframe,
                    event_timestamp=event.timestamp, observation_timestamp=int(timestamp),
                    direction=event.direction, horizon_bars=event.elapsed_bars,
                    entry_close=event.entry_close, exit_close=float(close),
                    underlying_return_pct=underlying_return,
                    directional_return_pct=directional_return,
                    max_favourable_excursion_pct=event.max_favourable_pct,
                    max_adverse_excursion_pct=event.max_adverse_pct,
                    shock_state_at_observation=self._state_name(snapshot),
                    event_magnitude_at_observation_atr=float(self._get(snapshot, "event_magnitude_atr", 0.0)),
                    onset_magnitude_atr=event.onset_magnitude_atr,
                    onset_confidence=event.onset_confidence,
                    onset_regime=event.regime, onset_regime_strength=event.regime_strength,
                    transmission_available_at_onset=event.transmission_available,
                    transmission_state_at_onset=event.transmission_state,
                    cross_asset_confirmation_at_onset=event.cross_asset_confirmation,
                )
                outcomes.append(outcome)
                if self.ledger:
                    self.ledger.save_outcome(outcome)

            if event.elapsed_bars < self.horizons[-1]:
                survivors.append(event)
                if self.ledger:
                    self.ledger.save_active(event)
            elif self.ledger:
                self.ledger.delete_active(event.event_id)

        self._active = survivors
        state = self._state_name(snapshot)
        direction = int(self._get(snapshot, "direction", 0) or 0)
        if (
            bool(self._get(snapshot, "shock_detected", False))
            and direction in (-1, 1)
            and int(self._get(snapshot, "persistence_bars", -1)) == 0
            and state.endswith("ONSET")
        ):
            event_id = self._event_id(symbol, timeframe, int(timestamp), direction)
            # Idempotent event creation protects replay/restart from duplicate onset.
            unseen = self.ledger.register_event_once(event_id, int(timestamp)) if self.ledger else True
            if unseen and not any(e.event_id == event_id for e in self._active):
                event = _TrackedEvent(
                    event_id=event_id, symbol=symbol, timeframe=timeframe,
                    timestamp=int(timestamp), entry_close=float(close), direction=direction,
                    onset_magnitude_atr=float(self._get(snapshot, "normalized_magnitude", 0.0)),
                    onset_confidence=float(self._get(snapshot, "confidence", 0.0)),
                    regime=self._get(snapshot, "regime"),
                    regime_strength=float(self._get(snapshot, "regime_strength", 0.0)),
                    transmission_available=bool(self._get(snapshot, "transmission_available", False)),
                    cross_asset_confirmation=self._get(snapshot, "cross_asset_confirmation"),
                    transmission_state=self._get(snapshot, "information_transmission_state"),
                )
                self._active.append(event)
                if self.ledger:
                    self.ledger.save_active(event)
        return outcomes


    def update(
        self, *, symbol: str, timeframe: str, timestamp: int,
        open_price: float, high: float, low: float, close: float, snapshot: Any,
    ) -> list[ShockOutcome]:
        if self.ledger:
            with self.ledger.transaction():
                return self._update_one_bar(
                    symbol=symbol, timeframe=timeframe, timestamp=timestamp,
                    open_price=open_price, high=high, low=low, close=close,
                    snapshot=snapshot,
                )
        return self._update_one_bar(
            symbol=symbol, timeframe=timeframe, timestamp=timestamp,
            open_price=open_price, high=high, low=low, close=close,
            snapshot=snapshot,
        )

    def update_mql5(
        self, *, symbol: str, timeframe: str, timestamp: int,
        open_price: float, high: float, low: float, close: float,
        snapshot_payload: dict[str, Any],
    ) -> list[ShockOutcome]:
        """Consume the explicitly mapped SAxShockDNASnapshot field contract."""
        snapshot = ShockSnapshotAdapter.from_mql5(snapshot_payload)
        return self.update(
            symbol=symbol, timeframe=timeframe, timestamp=timestamp,
            open_price=open_price, high=high, low=low, close=close,
            snapshot=snapshot,
        )

    @property
    def active_event_count(self) -> int:
        return len(self._active)
