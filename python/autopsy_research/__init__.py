"""
AUTOPSY X - offline research engine.

Implements the market-microstructure / price-impact methodology described in:
Malhotra, Y. "Guidance to a Goldman Sachs alumnus Hedge Fund with $400B-$500B AUM:
Alpha Trading Strategies Analysis, Maximizing Alpha for Hedge Funds, and High
Frequency Econometrics for Analyzing Price Impact of Trades, Liquidity, and
Market Microstructure." SSRN 3306817 (2018).

HONEST SCOPE: this package reimplements the METHODOLOGY the paper describes in
its bullet-point findings (Lee & Ready 1991 tick/quote trade-direction test,
a Hasbrouck (1991)-style 2-equation VAR of quote changes and net order flow,
orthogonalized impulse-response analysis) - it is NOT a byte-for-byte
reproduction of the paper's own SAS/VARMAX implementation or its underlying
TAQ dataset, neither of which is available here. Every numeric default that
traces to a specific statement in the paper is cited in that function's
docstring; every other default (window sizes not specified by the paper,
significance thresholds, etc.) is labeled an engineering choice.

This package is deliberately separate from the live MQL5 EA (see spec
section 31, "Research vs Live Separation"). It is not imported by, called
from, or a dependency of anything in MQL5/. Its outputs (fitted VAR
parameters, impulse-response summaries) are meant to be read by a human
researcher, and optionally exported as static parameters a live engine
could later be configured with - it never runs inside the MT5 tick loop.
"""

__version__ = "0.1.0"
