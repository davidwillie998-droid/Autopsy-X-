# Phase 3C System Status

Living status of the Phase 3C evidence-expansion and replication exercise, generated from `research/phase3c/evidence.json`. Phase 3A is frozen and finalized (`617355f874d949431eb93d8ac2d3ecc7b6479aa3`, VERIFIED WITH LIMITATIONS); Phase 3B is frozen (`f21f3bc2e18ab64d2b92e203c4202144eabf7eac`, INSUFFICIENT EVIDENCE).

## Phase 3C classification: INSUFFICIENT EVIDENCE

* Archives included: gt-sol-20260930a, gt-sol-20260930b, gt-sol-20260930c, p3a-sol-20261001d2, p3c-sol-20261004e, p3c-sol-20261004f
* Contamination-free: False
* MIN_SAMPLE (frozen): 85
* Hypotheses tested: 6
* By classification: {"INSUFFICIENT EVIDENCE": 6}

## What runs

* Acquisition (read-only, keyless), identical procedure to Phase 3A, new independent archives only.
* The frozen Phase 3B statistical contract and toolkit, unmodified.
* Token-level sample-size gate, block permutation, BH-FDR, winsorizing, temporal-stability split,
  archive-identity and step-index adversarial checks, walk-forward OOS (where MIN_SAMPLE is reached).
* No order placement, no wallets, no strategy logic, no production EA (none exists in this repository).

## Phase 3D

NOT STARTED.
