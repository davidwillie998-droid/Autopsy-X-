# 12. Testing Strategy

Run: `cd intel && python -m pytest -q` (stdlib code, pytest only).

## Layers

| Layer | What it proves | Where |
|---|---|---|
| Unit | Each formula matches its definition; missing inputs propagate as MISSING; thresholds classify as documented | `tests/test_core.py`, `tests/test_engines.py` |
| Scenario | Each engine separates known synthetic ground truth: organic breakout vs wash-traded pump vs creator rug vs quiet token vs lagging follower | `tests/test_engines.py`, `tests/test_signals_risk.py` |
| Leakage | Assessment at t is byte-identical whether or not the store holds records seen after t | `test_no_lookahead_future_records_do_not_change_past_assessment` |
| Replay determinism | Same dataset + same config gives identical signals | `test_replay_is_deterministic` |
| Failure modes | Stale data, missing social source, missing data yield NO_SIGNAL or MISSING, never a fabricated value | `test_stale_data_means_no_signal`, `test_missing_social_does_not_fabricate`, `test_no_data_flag` |
| Risk | Size respects the risk budget and pool share; refusals fire on each limit | `test_risk_*` |
| Transport | Retries on 429/5xx honour Retry-After, 4xx fails fast, circuit breaker opens and half-opens, token bucket waits | `tests/test_transport.py` |
| Audit | Journal hash chain detects tampering | `test_journal_hash_chain` |
| Validation tooling | Purged walk-forward has no train/test overlap; logistic baseline recovers a planted signal | `test_purged_walk_forward_has_no_overlap`, `test_logistic_beats_base_rate_on_informative_feature` |
| Docs sync | Feature dictionary regenerates from the registry | `test_feature_dictionary_*` |

## To add in Phase 2 and 3

| Layer | Content |
|---|---|
| Adapter contract | Per vendor endpoint: captured payload → canonical record, including unknown-as-None mapping and error classification |
| Integration | Ingest a recorded hour of real chain data end to end into the store; completeness against block explorer counts |
| Historical replay | Frozen historical datasets with expected assessments at fixed timestamps (golden files); any diff is reviewed before accepting |
| Property tests | Invariants over random inputs: z-scores shift-invariant in price scale, manipulation score monotone in flag confidence, sizing never exceeds any cap |
| Chaos | Inject API failures, reorgs, duplicate deliveries, out-of-order and late records; engine must degrade to NO_SIGNAL, never crash or signal |
| Performance | Scan latency for 500 tokens per closed bar stays under the bar interval |

## Promotion gates

| From → to | Gate |
|---|---|
| Research → paper trading | Hypothesis supported on untouched test period per doc 08; fill-model backtest positive after costs; max drawdown and failed-exit rate inside risk budget |
| Paper → live monitoring | ≥ 60 days paper; live-fill slippage within 1.5x of modelled; zero unexplained signals in audit sample |
| Live monitoring → execution | Explicit operator decision; separate process and keys; position limits at 10% of research limits for the first 30 days |

## Rules

* A failing test is a bug until proven otherwise; never skip or quarantine to go green.
* Synthetic scenario tests guard behaviour. They are never cited as evidence for a hypothesis.
