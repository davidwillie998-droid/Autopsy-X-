# Adaptive HVN and LVN detection

The Volume Profile engine now classifies local high-volume and low-volume nodes from its existing rolling bar-volume histogram.

- High-volume nodes require at least 1.5 times the profile's mean bin volume and must be a local maximum.
- Low-volume nodes require positive volume no greater than 0.5 times the profile mean and must be a local minimum with occupied adjacent bins on both sides.
- Node comparisons only treat occupied bins as neighbors when their price separation is within 1.5 profile bins. Sparse gaps are not treated as continuous price structure.
- New read-only APIs return the nearest qualifying node and its distance in profile bins.
- Thresholds are relative to the current profile, not fixed futures contract counts or raw broker volume.

## Data interpretation

The existing profile spreads each bar's MT5 tick volume evenly over bins spanning that bar's high-low range. These are estimated price-volume nodes, not true traded-volume-at-price measurements. On OTC FX and many CFD/synthetic feeds, tick volume is broker-specific. The node labels must therefore be treated as context, not proof of institutional accumulation or executable liquidity.

This change does not yet add node proximity to the trade score or entry gate. That should follow only after symbol-specific validation and a defined interaction policy. The current POC/value-area scoring remains unchanged.

## Validation required

- MetaEditor compile.
- Deterministic fixtures for a single local maximum, multiple nodes, flat distributions, sparse bins and edge bins.
- Strategy Tester comparison across XAUUSD, FX and synthetic symbols, with broker-specific volume behavior recorded.
- Out-of-sample review before any node-derived score or order permission is introduced.
