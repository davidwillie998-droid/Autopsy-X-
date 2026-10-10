# 01. Architecture

## The question the system answers

Not "what should I buy." The engine answers: *a statistically unusual move is happening; here is the evidence, what appears to drive it, who is participating, whether the liquidity can carry a position, and what would prove the thesis wrong.* When the evidence is incomplete it answers with silence.

## Pipeline

```
providers ──► point-in-time store ──► view(as_of)
                                          │
  per token ───────────────────────────────┤
    1  data quality gate          quality/checks.py        QualityReport (failure modes)
    2  bars + market state        features/bars, market    MarketState (per-window Obs)
    3  move detection             detection/move.py        MoveAssessment (class, onset)
    4  liquidity                  features/liquidity.py    LiquidityState
    5  wallet clusters            onchain/clusters.py      ClusterReport (graph + evidence)
    6  participation              features/participation   Participation (cluster-collapsed)
    7  social / attention         social/attention.py      AttentionState
    8  manipulation               manipulation/detectors   ManipulationReport (flags)
    9  news-to-move               news/catalyst.py         CatalystAssessment (timing class)
   10  regime                     regime/classifier.py     RegimeAssessment (+ all matches)
   11  exhaustion                 signals/exhaustion.py    ExhaustionAssessment
                                          │
  cross token ─────────────────────────────┤
   12  narrative                  narrative/engine.py      NarrativeState per narrative
   13  leader / follower          narrative/leadlag.py     roles + lag links
   14  move quality               detection/move_quality   MoveQuality (+ coverage)
   15  entry signal               signals/entry.py         Signal (conditions, vetoes)
                                          │
   16  risk                       risk/engine.py           RiskDecision (size or refusal)
   17  exit                       signals/exit.py          ExitDecision
   18  alerts + timeline          alerts/engine.py         Alert, timeline rows
   19  rankings                   ranking.py               ten separate lists
   20  journal                    journal/journal.py       hash-chained records
   21  backtest / event study     backtest/                metrics, abnormal returns
   22  models                     research/models.py       walk-forward baselines
```

`pipeline.py` wires outputs to inputs and contains no scoring logic. Each stage is a pure function of `(view, config)`; its full output lands in `Assessment` and serialises with `to_dict()`, so any number on a dashboard traces back to the stage and inputs that produced it.

## Contracts

**Obs.** Every measured quantity is `Obs(value, status, reason)`. Status is one of `OK, MISSING, STALE, INSUFFICIENT_HISTORY, UNVERIFIED, CONFLICTING`. Arithmetic via `combine()` propagates the worst status. A missing input yields a missing output. Nothing is ever filled with zero.

**Two clocks.** Every record carries `ts` (when it happened) and `seen_ts` (when the system could first know it). `EventStore.view(as_of)` exposes only records with `seen_ts <= as_of`. Backtests, live scans and replays all read through that one door. A swap a vendor reports 40 seconds late did not exist for the system during those 40 seconds.

**Closed bars only.** The still-forming bar is dropped before features are computed.

**Identity.** Tokens are `(chain, address)`. Symbols are display strings and collide constantly; the scan reports collisions so the UI shows addresses whenever a symbol is ambiguous.

**Config.** Thresholds and weights live in TOML. `Config.fingerprint()` hashes the full config; every backtest and journal entry records it.

## Why this shape

| Choice | Reason |
|---|---|
| Stdlib-only core | Deterministic, auditable, trivially reproducible. Heavier libraries (numpy, LightGBM, networkx) enter only where a stage outgrows pure Python, behind the same function signatures |
| Rules before models | Rules are inspectable hypotheses. Models replace a rule only when they beat it out of sample (doc 08) |
| Cross-token stages after per-token stages | Narrative breadth and lead/lag need every token's move state first; keeping them separate avoids hidden ordering dependencies |
| Vetoes separate from score | A token with a perfect Move Quality score and a creator dumping supply is not a "slightly lower score"; it is a refusal |
| Separate rankings | A single blended ranking implies a validated weighting that does not exist |

## Deployment shape (Phases 12 to 14)

```
ingestors (per provider, per chain)  ──►  Postgres/Timescale (doc 09)
                                              │
scan worker (every closed bar)  ◄─────────────┘
   ├─► assessments, signals, alerts tables
   ├─► journal (append-only)
   └─► dashboard API ──► LIVE MARKET RADAR / TOKEN AUTOPSY (index.html successor)
paper-trade worker  ── reads signals, simulates fills with backtest fill model
execution (optional, last) ── disabled by default, separate process, separate keys
```

The existing `index.html` dashboard and `server/` bridge stay as they are. The radar and autopsy views become a client of the scan worker's API once historical validation exists; `python -m autopsyx demo` prints the same radar columns today.
