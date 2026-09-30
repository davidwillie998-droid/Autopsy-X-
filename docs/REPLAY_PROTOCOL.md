# Replay Protocol

How a real-data replay is produced, what makes it reproducible, and what its output may and may not be used for.

## Steps

1. **Acquire.** `python -m autopsyx acquire --live --request REQUEST.json --out RUN_DIR`. Runs universe selection (seeded, stratified), OHLCV backfill, then real-time polling for `duration_s`. In this phase it runs on a GitHub Actions runner via `.github/workflows/phase2-acquire.yml`, because the build container cannot reach vendor hosts. The raw archive is committed to the branch.
2. **Normalize.** `python -m autopsyx normalize RUN_DIR` produces `normalized.jsonl` and `normalization_report.json`. It is deterministic: the workflow also normalizes on the runner and writes the `dataset_sha256` into `normalize_stdout.json`, so a second machine can confirm it gets the same hash.
3. **Replay.** `python -m autopsyx replay-run RUN_DIR --step-min 5 --expect-config <hash>`:
   * replay window = first live poll response → last response. Before the first poll, availability times were not observed live, so the replay never starts earlier
   * at each step `t`: `store.view(t)` → `scan` → signal → risk (fill-time price and liquidity from `view(t + 60 s)`) → hypothetical position → exit decision
   * capabilities are fixed to what the archive can supply: no funding transfers, no LP events, no news, no social (`PHASE2_CAPABILITIES`)
   * output: `replay_<config hash>/journal.jsonl` (one hash-chained record per step and token) and `summary.json`

## Record contents

Every journal record carries: `token`, `chain`, `as_of`, `configuration_hash`, `code_version`, `dataset_id` (run id + dataset sha prefix), `signal`, `blocked_by`, per-condition pass/fail/unknown, `risk`, `entry`, `exit`, `reason`, `outcome`, `data_quality` (failure modes), move class, regime, exhaustion, lifecycle, token age, role, manipulation score and flags, unavailable detectors, Move Quality score and coverage, and the rankings the token appeared in.

## Determinism

The same archive, code and configuration give a byte-identical journal and summary. What guarantees it:

* no wall-clock reads anywhere in normalization, scan or replay; every time comes from the data or the replay grid
* archive iteration in manifest sequence order; store ordering by `seen_ts` with stable insertion
* no randomness in the engines; the only RNG (universe selection) is seeded and runs at acquisition time
* the journal hashes each record with sorted keys and chains the hashes

Tested by `test_replay_is_deterministic_to_the_byte` and `test_replay_of_acquired_archive_is_deterministic`.

## Configuration immutability

* `--expect-config HASH` makes the replay refuse to run under any other configuration (`ConfigMismatch`).
* A replay directory belongs to one configuration. Replaying with a different configuration into an existing journal is refused; re-running the same configuration rebuilds the journal from scratch.
* The output directory name includes the hash: a new hash is a new experiment.

## What replay output is for

It measures how the unchanged Phase 1 engines behave on real data: how often data quality blocks them, which inputs are missing, how many assessments are UNCLASSIFIED, which detectors fire and which cannot run.

It is **not** evidence of strategy quality. Hypothetical entries and exits exist so the exit and risk engines are exercised end to end. Their outcomes come from one short window, a dozen tokens, and no fill-model validation. They must not be reported as returns, and no threshold may be tuned against them (Phase 2 scope rule 17).
