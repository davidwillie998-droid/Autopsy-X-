"""Phase 5 chronological data split - dates fixed BEFORE any result was
examined (§8/§9/§24: "do not choose the split after examining performance").

A plain 60/20/20 chronological split of the real joint dataset (3,997 rows,
2011-06-01 to 2026-09-25 - see docs/PHASE5_DATA_PROVENANCE.md). No random
shuffling anywhere (financial time series - shuffling would destroy the
temporal structure every downstream test depends on).

FIXED BOUNDARIES (computed once from the row count, never adjusted):
  DEVELOPMENT : 2011-06-01 .. 2020-08-10   (2,398 rows, 60%)
  VALIDATION  : 2020-08-11 .. 2023-09-01   (  799 rows, 20%)
  OUT-OF-SAMPLE: 2023-09-04 .. 2026-09-25  (  800 rows, 20%)

Any model coefficient is fit ONLY on DEVELOPMENT. VALIDATION is used to
compare models/select among the pre-registered feature sets (§9's own
"incremental value" comparison). OUT-OF-SAMPLE is touched exactly once,
after every modeling decision is frozen, and its result is reported as-is,
never used to go back and reselect a feature set or threshold (§26 - a
threshold "discovered" by looking at OOS is contaminated and must be
labeled so, never silently reused as final evidence).
"""
from __future__ import annotations

import pandas as pd

DEV_FRAC = 0.6
VAL_FRAC = 0.2  # remainder (0.2) is OOS


def chronological_split(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    df = df.sort_values("date").reset_index(drop=True)
    n = len(df)
    dev_end = int(n * DEV_FRAC)
    val_end = int(n * (DEV_FRAC + VAL_FRAC))
    dev = df.iloc[:dev_end].copy()
    val = df.iloc[dev_end:val_end].copy()
    oos = df.iloc[val_end:].copy()
    return dev, val, oos
