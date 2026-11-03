# Risk Invariant Audit (Section A)

**Applies to commit:** bfd079e0 (post-fix)
**Audited invariant:** the account can never be exposed to more risk than
`CRiskEngine`'s own configured, hard-clamped risk-per-trade percent
(0.05%-2.0%) implies, regardless of what any downstream engine
(`CAdaptiveFlipEngine`, impact-cost sizing, VWAP alignment bonus) does to
the lot size afterward.

This audit traced the invariant end-to-end through real code, worst-case
per path, not from architecture description alone.

---

## The clamp

`RiskEngine.mqh`, `Configure()`:

```cpp
m_riskPercent = AxClampD(riskPercent,0.05,2.0);   // hard ceiling: never >2% (spec section 2)
```

Written exactly once, in `Configure()`. Read exactly once, in
`CalculateLotSize()`. No other write path exists (confirmed by grep across
`RiskEngine.mqh` for `m_riskPercent`).

## The four questions traced

| # | Question | Finding | Verdict |
|---|---|---|---|
| Q1 | Is the lot `CalculateLotSize()` returns re-clamped to `SYMBOL_VOLUME_MIN`/`MAX`/step? | Yes, via `CMarketData::NormalizeVolume()`, which reads `SYMBOL_VOLUME_MIN`/`MAX`/`STEP` live from the broker. **Originally only applied BEFORE the `m_maxExposureLots` clamp, not after** - see Finding 1 below. | PASS (after fix) |
| Q2 | Is `CAdaptiveFlipEngine::Evaluate()`'s `riskMultiplierOut` applied as a multiplier to the LOT SIZE, or to the risk PERCENT, or as a divisor? | Multiplier to lot size: `scaledLots = lots*afeRiskMultiplier;` (`AutopsyX_FlipDemon_Extreme.mq5`). Never applied to `m_riskPercent`. No reciprocal/divisor form exists anywhere `afeRiskMultiplier` or `riskMultiplierOut` is used. | PASS |
| Q3 | Is the final lot re-clamped to broker limits after the AFE multiplier is applied? | Yes: `lots = (scaledLots < volMin) ? 0.0 : g_md.NormalizeVolume(scaledLots);` | PASS |
| Q4 | Does any path compute `1/afeRiskMultiplier` or an equivalent reciprocal? | None found (grepped `AutopsyX_FlipDemon_Extreme.mq5`, `RiskEngine.mqh`, `AdaptiveFlipEngine.mqh`). | PASS |

## The AFE bound itself

`CAdaptiveFlipEngine::Evaluate()`'s continuous scaler is bounded `<=1.0` by
four independent mechanisms, not one:

1. `stateMult` is either `1.0`, `m_cautionMultiplier`, or `m_defensiveMultiplier`
   - the latter two clamped to `[0,1]` in `Configure()`.
2. `exq` (execution-quality scaler) is one of `{1.0, 0.70, 0.40}` by construction.
3. The VWAP alignment claw-back (`baseMult = MathMin(1.0,baseMult*m_vwapAlignmentBonus)`)
   is itself wrapped in `MathMin(1.0,...)` and only reachable when `baseMult<1.0`.
4. The function's last line re-clamps regardless: `m_lastRiskMultiplier = AxClampD(baseMult,0.0,1.0);`

`m_vwapAlignmentBonus` (the one input that could theoretically push the
claw-back above 1.0 pre-clamp) is itself floored at `1.0` in `Configure()`:
`m_vwapAlignmentBonus = MathMax(1.0,vwapAlignmentBonus);` - so it can only
ever partially undo a de-risking multiplier, never invert it into a bonus
beyond what `CRiskEngine` already sized.

## Finding 1 (fixed in bfd079e)

`CalculateLotSize()` originally called `NormalizeVolume()` **before** the
`m_maxExposureLots` clamp, not after:

```cpp
lots = md.NormalizeVolume(lots);        // clamps to [volMin,volMax], floors to step
lots = MathMin(lots,m_maxExposureLots); // then clamps again - NOT re-stepped
return(lots);
```

`m_maxExposureLots` is a user-configured `Configure()` input with no
guarantee of being volume-step-aligned for a given broker. The default
(`1.0`) is step-aligned for virtually every broker's `SYMBOL_VOLUME_STEP`,
so this was **latent, not live** under default configuration - but a
configured value such as `0.375` lots on a `0.01`-step broker would have
been returned exactly as-is instead of floored to a broker-valid size,
risking an order-send rejection or terminal-side rounding outside this
code's control.

**Fix applied:** re-normalize after the exposure clamp as well, so the
return value is broker-valid regardless of what `Configure()` was called
with, never contingent on the config itself being well-behaved:

```cpp
lots = md.NormalizeVolume(lots);
lots = MathMin(lots,m_maxExposureLots);
lots = md.NormalizeVolume(lots);   // re-normalize after the exposure clamp too
return(lots);
```

## Verdict

**PASS.** The risk-per-trade invariant (0.05%-2.0% of equity, hard-clamped
at config time, never scaled up by any downstream engine) holds
end-to-end through every code path traced. One finding (Finding 1) was a
latent broker-compatibility gap, not a risk-invariant violation - fixed
in a discrete commit (`bfd079e`) before this audit was written up.

## Scope note

This audit covers the single-symbol path this EA trades (`_Symbol` only,
confirmed one call site of `CalculateLotSize()` in the entire `.mq5`
file). It does not re-verify `CRiskEngine`'s other hard gates (daily/weekly
loss limits, consecutive-loss/execution-failure breakers, margin checks) -
those are independent boolean gates in `PreTradeAllowed()`, not part of
the sizing-multiplier chain this audit traced, and were not in scope for
"does risk-per-trade ever exceed what `Configure()` allowed."
