# Execution-mode audit

## Finding
The EA has two distinct controls that must not be conflated:

- `InpMode` is the aggression/risk mode. The source currently defaults it to `AX_MODE_AGGRESSIVE`, which selects a 1.0% base risk setting for any entry that reaches the sizing path.
- `InpExecutionMode` controls whether real orders may be sent. The source defaults it to `AX_EXEC_ANALYSIS_ONLY`.

The source passes `InpExecutionMode` into `CEmergencyControls::Configure`. `CanEnterDirection` rejects new entries unless the execution mode is explicitly `AX_EXEC_LIVE`. `AX_EXEC_PAPER` is also blocked from real broker orders because a simulated-fill engine is not implemented.

Therefore, the aggressive risk-mode default is not itself proof that live trading is enabled. However, if a user explicitly changes execution mode to LIVE, the aggression mode and risk inputs become materially relevant and must be reviewed.

## Safety conclusion
- Keep `InpExecutionMode = AX_EXEC_ANALYSIS_ONLY` as the source default.
- Do not change it to LIVE as part of scanner or risk-gate integration.
- Keep the account-flat portfolio gate standalone until compiled and tested.
- The portfolio gate added in this branch is not currently wired into the main EA, so its limits do not yet govern existing entry paths.
- This audit is source inspection only. It is not a MetaEditor compile, Strategy Tester result, or broker-demo validation.

## Next required work
1. Add regression tests for the execution-mode default and the rule that only explicit LIVE mode passes the real-entry gate.
2. Run the Python static tests in CI and confirm results for the current branch head.
3. Compile in MetaEditor; resolve any compile errors before integrating `PortfolioRiskGate.mqh`.
4. Test ANALYSIS_ONLY and PAPER behavior in MT5 and verify no real orders are sent.
