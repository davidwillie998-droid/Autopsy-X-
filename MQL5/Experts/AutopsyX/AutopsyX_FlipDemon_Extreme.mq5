//+------------------------------------------------------------------+
//|                                  FlipDemon_Extreme_HFT.mq5        |
//|                         FLIPDEMON EXTREME HFT                     |
//|        Ultra-aggressive MT5 HFT flipping & scalping engine        |
//|                                                                    |
//|  SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS     |
//|                                                                    |
//|  No martingale. No averaging down. No unlimited risk, ever.       |
//|  This EA does not promise profitability - see README.md for the   |
//|  required multi-phase validation workflow before risking capital. |
//+------------------------------------------------------------------+
#property copyright "FlipDemon Extreme HFT"
#property link      ""
#property version   "1.00"
#property strict

#include <AutopsyX/Defs.mqh>
#include <AutopsyX/MarketData.mqh>
#include <AutopsyX/MarketSnapshotRecorder.mqh>
#include <AutopsyX/BrokerCompatibility.mqh>
#include <AutopsyX/SpreadCostIntelligence.mqh>
#include <AutopsyX/GapIntelligenceEngine.mqh>
#include <AutopsyX/GapExecutionEngine.mqh>
#include <AutopsyX/GapObservationJournal.mqh>
#include <AutopsyX/GapWindowAnalytics.mqh>
#include <AutopsyX/Momentum.mqh>
#include <AutopsyX/Microstructure.mqh>
#include <AutopsyX/HawkesEventIntensity.mqh>
#include <AutopsyX/Liquidity.mqh>
#include <AutopsyX/Regime.mqh>
#include <AutopsyX/MacroRegime.mqh>
#include <AutopsyX/VolatilityEngine.mqh>
#include <AutopsyX/RegimeIntelligenceEngine.mqh>
#include <AutopsyX/RegimeClassifierEngine.mqh>
#include <AutopsyX/RegimeResearchJournal.mqh>
#include <AutopsyX/StructureEngine.mqh>
#include <AutopsyX/PurePriceAction.mqh>
#include <AutopsyX/W1InstitutionalDirection.mqh>
#include <AutopsyX/D1InstitutionalLevels.mqh>
#include <AutopsyX/PremiumDiscountEngine.mqh>
#include <AutopsyX/FairValueGapEngine.mqh>
#include <AutopsyX/OrderBlockEngine.mqh>
#include <AutopsyX/MarketMakerModelEngine.mqh>
#include <AutopsyX/DailyExtremeProjectionEngine.mqh>
#include <AutopsyX/H4TrendBreakoutEngine.mqh>
#include <AutopsyX/ShadowRiverEngine.mqh>
#include <AutopsyX/AdvancedTrendSuite.mqh>
#include <AutopsyX/CompositeDirection.mqh>
#include <AutopsyX/VPMACD.mqh>
#include <AutopsyX/NewsDefense.mqh>
#include <AutopsyX/SignalScore.mqh>
#include <AutopsyX/EvidenceArbitrationEngine.mqh> // Supervisory evidence contract; observational until explicitly wired
#include <AutopsyX/InstitutionalEvidenceAdapter.mqh>
#include <AutopsyX/FlipEngine.mqh>
#include <AutopsyX/AntiChop.mqh>
#include <AutopsyX/RiskEngine.mqh>
#include <AutopsyX/AccountRiskCalculator.mqh>
#include <AutopsyX/MarginGuard.mqh>
#include <AutopsyX/DistributedRiskCoordinator.mqh>
#include <AutopsyX/EntryEngine.mqh>
#include <AutopsyX/ExecutionEligibility.mqh>
#include <AutopsyX/TradeLifecycle.mqh>
#include <AutopsyX/ExecutionEngine.mqh>
#include <AutopsyX/ExecutionLatencyProfiler.mqh>
#include <AutopsyX/ExecutionQualityJournal.mqh>
#include <AutopsyX/IQ200Telemetry.mqh>
#include <AutopsyX/ExitEngine.mqh>
#include <AutopsyX/SniperEngine.mqh>
#include <AutopsyX/PrecisionEntryEngine.mqh>
#include <AutopsyX/OrderFlow.mqh>
#include <AutopsyX/VolumeProfile.mqh>
#include <AutopsyX/Footprint.mqh>
#include <AutopsyX/Pulse.mqh>
#include <AutopsyX/Heatmap.mqh>
#include <AutopsyX/TradeAutopsy.mqh>
#include <AutopsyX/Statistics.mqh>
#include <AutopsyX/AdaptiveFlipEngine.mqh>
#include <AutopsyX/AccountFlipEngine.mqh>
#include <AutopsyX/VWAPEngine.mqh>
#include <AutopsyX/ContinuationIntelligence.mqh>
#include <AutopsyX/EmergencyControls.mqh>
#include <AutopsyX/TradeReconciliation.mqh>
#include <AutopsyX/RestartRecovery.mqh>
#include <AutopsyX/VirtualExitRegistry.mqh>
#include <AutopsyX/HedgingPartialCloseLedger.mqh>
#include <AutopsyX/HedgingFullCloseLedger.mqh>
#include <AutopsyX/PyramidEngine.mqh>
#include <AutopsyX/PyramidCampaignRegistry.mqh>
#include <AutopsyX/HedgingPositionManager.mqh>
#include <AutopsyX/HedgingCampaignLifecycle.mqh>
#include <AutopsyX/PositionStateRegistry.mqh>
#include <AutopsyX/AdvancedSessionORBEngine.mqh>
#include <AutopsyX/Dashboard.mqh>

//====================================================================
// INPUTS
//====================================================================
input group "=== MODE ===";
input bool          InpEnableMarketSnapshots = true; // Export timestamped market/decision rows for deterministic replay; observational only
input ENUM_AX_MODE   InpMode                    = AX_MODE_AGGRESSIVE; // Strategy aggression and stop-risk sizing mode
input ENUM_AX_MARGIN_PROFILE InpMarginProfile = AX_MARGIN_MEDIUM; // Independent account margin utilisation profile
input double         InpExtremeRiskPercent      = 5.0;                // EXTREME mode stop-risk % per trade
input double         InpMaxAccountStopRiskPercent = 10.0;              // Configurable per-entry and aggregate stop-risk ceiling, independent of margin profile (0.05..100%)

input group "=== ACCOUNT FLIP GROWTH ===";
input bool            InpEnableAccountFlipEngine = true;   // Equity milestones adapt sizing within configured stop-risk and broker limits
input double          InpAccountFlipStartingEquity = 100.0; // Starting account equity, in deposit currency
input double          InpAccountFlipTargetEquity = 10000.0; // Initial target; compounding may continue beyond this level

input group "=== PYRAMID CAMPAIGN (DECISION LAYER) ===";
input bool            InpEnablePyramidDecision    = true;   // Evaluate profitable continuation adds; order execution remains separately gated
input int             InpPyramidMaxTiers          = 0;      // Zero means no EA-imposed tier count ceiling; risk, margin and broker limits still apply
input double          InpPyramidLotMultiplier     = 1.5;    // Each tier must exceed the prior tier; anti-martingale only
input double          InpPyramidAtrGapMultiplier  = 0.75;   // Minimum favorable continuation distance from the last confirmed tier fill
input double          InpPyramidMinProfitMoney    = 0.01;   // Require positive broker-reported floating P/L plus swap before considering an add
input bool            InpEnablePyramidExecution    = false;  // Explicit opt-in; ANALYSIS_ONLY remains the default

input group "=== PURE PRICE ACTION DIAGNOSTICS (SHADOW ONLY) ===";
input bool InpEnablePurePriceActionDiagnostics = true; // OHLC-only candle and impulse diagnostics; never affects entries or scores
input int InpPurePriceActionLookback = 5;
input bool InpEnablePurePriceActionJournal = true; // Append one OHLC-only observation per completed bar to MQL5/Files

input group "=== M15 PRECISION DISPLACEMENT CONFIRMATION ===";
input ENUM_TIMEFRAMES InpPrecisionTimeframe = PERIOD_M15;
input double InpPrecisionMinBodyRatio = 0.45;
input double InpPrecisionMinRangeAtr = 0.35;
input double InpPrecisionCloseLocation = 0.72;

input group "=== SNIPER ENTRY (PRECISION TIMING) ===";
input bool            InpUseSniperEntry           = true; // Wait for a precise pullback-then-resume before entering, instead of firing immediately
input double          InpSniperPullbackPoints     = 15;   // Pullback required from the local extreme to arm the resume-watch, points
input double          InpSniperResumePoints       = 8;    // Resumption required from the pullback point to actually trigger entry, points
input int             InpSniperMaxWaitSeconds     = 8;     // Give up waiting for the retest after this long, seconds
input double          InpSniperMaxChasePoints     = 40;    // Abandon if price runs this far in our favor without ever pulling back
input bool            InpSniperUseStructureStop   = true;  // Prefer a stop just beyond the nearest liquidity level when it's tighter than ATR/fixed
input double          InpSniperStructureBufferPts = 10;    // Buffer placed beyond the structural level, points

input group "=== NEWS DEFENSE / VP-MACD ===";
input int             InpNewsMinutesBefore        = 20;
input int             InpNewsMinutesAfter         = 15;
input int             InpNewsRefreshSeconds       = 30;
input int             InpVPMACDFastPeriod         = 12;
input int             InpVPMACDSlowPeriod         = 26;
input int             InpVPMACDSignalPeriod       = 9;

input group "=== ORDER FLOW / VOLUME PROFILE / FOOTPRINT / HEATMAP / PULSE ===";
input bool            InpUseOrderFlow             = true;  // Blend order-flow/footprint/volume-profile into the score (advisory, not a hard gate)
input bool            InpUseCvdDivergence         = true;  // Include normalized two-window CVD divergence as an advisory order-flow score component
input double          InpOrderFlowScoreWeight     = 15.0;  // Max points each of order flow / footprint / volume profile can add to a side's score
input group "=== PREMIUM / EQUILIBRIUM / DISCOUNT LOCATION ===";
input bool            InpUsePremiumDiscountEngine = true;  // Advisory multi-timeframe dealing-range location; never an independent entry trigger
input double          InpPremiumDiscountScoreWeight = 12.0; // Maximum score contribution from confirmed H4/H1 premium-discount alignment
input group "=== ICT FAIR VALUE GAP RETRACEMENT ===";
input bool InpUseFvgRetestEngine = true; // Closed-bar FVG lifecycle, retest evidence only, never an independent entry trigger
input ENUM_TIMEFRAMES InpFvgTimeframe = PERIOD_M5;
input int InpFvgLookbackBars = 120;
input int InpFvgMaxAgeBars = 36;
input double InpFvgMinGapAtr = 0.05;
input double InpFvgMinDisplacementBodyRatio = 0.55;
input double InpFvgScoreWeight = 6.0; // Bounded score bonus, hard-capped at 8 points
input group "=== ICT ORDER BLOCK AND BREAKER ===";
input bool InpUseOrderBlockEngine = true; // Structure-confirmed OB and breaker lifecycle, advisory only
input int InpOrderBlockLookbackBars = 160;
input int InpOrderBlockMaxAgeBars = 48;
input int InpOrderBlockOriginSearchBars = 8;
input double InpOrderBlockMinDisplacementBodyRatio = 0.55;
input double InpOrderBlockScoreWeight = 6.0; // Bounded score bonus, hard-capped at 8 points

input group "=== ICT MARKET MAKER BUY/SELL MODEL (MMBM / MMSM) ===";
input bool InpEnableMarketMakerModel = true; // H4 origin/curve, H4 premium-discount terminal, M15 reversal; observational model
input ENUM_TIMEFRAMES InpMMXMConfirmationTimeframe = PERIOD_M15;
input int InpMMXMMaxOriginAgeBars = 36; // Maximum age of the original H4 consolidation
input int InpMMXMMinConsolidationBars = 3;
input int InpMMXMMaxConsolidationBars = 8;
input double InpMMXMMaxConsolidationAtr = 1.75; // Origin range width / H4 ATR(14)
input double InpMMXMBreakoutBufferAtr = 0.10; // Closed H4 breakout buffer
input int InpMMXMReversalLookbackBars = 5; // M15 MSS reference window
input double InpMMXMMinDisplacementAtr = 0.75;
input double InpMMXMMinBodyRatio = 0.55;
input double InpMMXMTerminalZonePercent = 61.8; // Premium for MMSM, mirrored discount for MMBM
input double InpMMXMScoreWeight = 0.0; // Keep at zero until chronological replay proves incremental edge; max 8 points

input group "=== DAILY HIGH / LOW PROJECTION (ASIA + CBDR + FLOUT) ===";
input bool InpEnableDailyExtremeProjection = true; // Observational projection zones only, never an independent entry trigger
input int InpDailyExtremeAsiaStartNewYorkHour = 20; // New York local time, prior evening Asia range start
input int InpDailyExtremeAsiaEndNewYorkHour = 0; // New York local time, midnight exclusive end
input int InpDailyExtremeCBDRStartNewYorkHour = 14; // New York local time, CBDR start
input int InpDailyExtremeCBDREndNewYorkHour = 20; // New York local time, CBDR end
input int InpDailyExtremeBrokerUtcOffsetMinutes = 9999; // 9999=auto live broker offset; tester/replay requires explicit server UTC offset in minutes
input double InpDailyExtremeConfluenceToleranceADR = 0.05; // Projection overlap tolerance as fraction of prior 20-day ADR
input int             InpVolumeProfileBars        = 120;   // Rolling lookback for the volume profile, bars
input double          InpVolumeProfileBinPoints   = 5.0;    // Volume profile bin width, points
input double          InpFootprintBinPoints       = 3.0;    // Footprint level width, points (finer than the volume profile)
input double          InpFootprintImbalanceRatio  = 0.70;   // Buy-or-sell share at a level that counts as "imbalanced"
input int             InpFootprintStackedLevels   = 3;      // Consecutive imbalanced levels required to call it "stacked"
input ENUM_TIMEFRAMES InpFootprintTimeframe       = PERIOD_M1; // Bar clock the footprint grid snapshots on
input bool            InpUseHeatmap               = true;   // Attempt to subscribe to broker market depth (silently unavailable if the broker doesn't provide it)
input double          InpHeatmapRangePoints       = 50.0;   // How far from the touch price DOM levels are considered, points
input bool            InpUseImpactCostSizing      = true;   // Cap position size to what the order book can actually absorb within budget (needs broker depth - no-op otherwise)
input double          InpMaxImpactCostPct         = 0.15;   // Max acceptable order-book impact cost for the full position size, %

input group "=== ADAPTIVE FLIP ENGINE (CAPITAL PROTECTION) ===";
input bool            InpUseAdaptiveFlipEngine    = true;   // Enable the AFE capital-protection layer (applies to fresh entries AND flips)
input double          InpAfeCautionDdPct          = 8.0;    // Peak-equity drawdown % that enters CAUTION (risk scaled down)
input double          InpAfeDefensiveDdPct        = 15.0;   // Peak-equity drawdown % that enters DEFENSIVE (risk scaled down further)
input double          InpAfeLockedDdPct           = 25.0;   // Peak-equity drawdown % that enters LOCKED (new entries hard-blocked)
input double          InpAfeCautionMultiplier     = 0.65;   // Risk multiplier applied in CAUTION
input double          InpAfeDefensiveMultiplier   = 0.30;   // Risk multiplier applied in DEFENSIVE
input double          InpAfeMaxRiskOfRuinPct      = 5.0;    // Block entries once estimated risk of ruin exceeds this, %
input double          InpAfeRuinThresholdPct      = 50.0;   // The peak-equity drawdown % that "ruin" means for that estimate
input double          InpAfeMinExpectedValueR     = 0.0;    // Block entries whose expected value, in R-multiples, is below this
input double          InpAfeMinAccountHealth      = 25.0;   // Block entries when the blended 0-100 account-health score is below this
input int             InpAfeMinTradesForStats     = 20;     // Trades required before trailing stats blend into the probability/EV estimate
input double          InpAfeAssumedRewardRisk     = 1.5;    // Cold-start reward:risk assumption before enough trade history exists
input double          InpCommissionPerLot         = 0.0;    // Broker's real commission per lot, round trip, account currency - get this from your broker, never guessed
input double          InpSlippageToleranceBufferPts = 0.0;  // Worst-case slippage buffer folded into the EV cost estimate, points
input double          InpImpactCoefficientK       = 1.0;    // Square-root price-impact model coefficient (Bouchaud et al.) - only used above InpImpactRelevanceThresholdLots
input double          InpImpactRelevanceThresholdLots = 50.0; // Institutional-scale size threshold before price impact is even computed - this EA's own sizing is never expected to reach it

input group "=== VWAP TREND ENGINE (Zarattini & Aziz, SSRN 4631351, 2023) ===";
input ENUM_AX_VWAP_MODE InpVWAPMode          = AX_VWAP_ROLLING; // Rolling trailing window, or anchored to the most recent FX session open
input int             InpVWAPRollingBars     = 240;    // Rolling VWAP window, bars (240 = 4 hours on M1 - adjust proportionally on other timeframes)
input int             InpVWAPSydneyHour      = 22;     // Sydney session open, broker SERVER time hour (0-23) - verify against your broker, not a universal clock
input int             InpVWAPTokyoHour       = 0;      // Tokyo session open, broker server time hour
input int             InpVWAPLondonHour      = 8;      // London session open, broker server time hour
input int             InpVWAPNewYorkHour     = 13;      // New York session open, broker server time hour
input double          InpVWAPDeadbandATRMult = 0.1;    // Deadband around VWAP, as a multiple of ATR, before a trend read is BULLISH/BEARISH rather than NEUTRAL
input bool            InpRequireVWAPDirection = true;   // Paper rule: only enter BUY above VWAP and SELL below VWAP; unavailable/neutral VWAP blocks fresh entries
input bool            InpUseVWAPExit         = true;   // Paper rule: arm the confirmed closed-bar exit when price crosses VWAP against the position
input ENUM_AX_VWAP_EXIT_MODE InpVWAPExitMode  = AX_VWAP_EXIT_CONFIRMED_CROSS; // Only relevant when InpUseVWAPExit is on. CONFIRMED_CROSS is the original/default behavior (closed-bar confirmation) - see ExitEngine.mqh for all four modes
input double          InpVWAPAlignmentBonus  = 1.15;   // Sizing bonus applied ONLY when InpUseVWAPExit is on and this signal agrees with VWAP trend - see AdaptiveFlipEngine.mqh for how this is bounded

input group "=== VWAP / ADX / OVERNIGHT / TWIN CONTINUATION INTELLIGENCE ===";
input bool InpUseContinuationIntelligence = true; // Bounded confirmation evidence only
input int InpContinuationADXPeriod = 14;
input double InpContinuationADXTrendThreshold = 25.0; // Require a confirmed trend, not the 20-25 transition zone
input int InpOvernightStartServerHour = 22; // Broker server time, verify DST
input int InpOvernightEndServerHour = 7;
input double InpVWAPPullbackScoreWeight = 5.0;
input double InpOvernightBiasScoreWeight = 3.0;
input double InpTwinContinuationScoreWeight = 5.0;

input group "=== ADVANCED MULTI-SESSION ORB ===";
input bool            InpEnableAdvancedSessionORB = false; // Opt in only after broker-server session hours are verified
input int             InpORBRangeMinutes = 15;             // Opening range duration
input ENUM_TIMEFRAMES InpORBBreakoutTimeframe = PERIOD_M5; // Closed-bar breakout/retest confirmation timeframe
input int             InpORBAsiaServerHour = 0;            // Broker server time, not local or exchange time
input int             InpORBLondonServerHour = 8;           // Adjust for broker/DST session mapping
input int             InpORBNewYorkServerHour = 13;         // Adjust for broker/DST session mapping
input double          InpORBBufferPoints = 5.0;             // Close must clear the range boundary by this buffer
input double          InpORBMinBodyRatio = 0.45;            // Minimum breakout candle body/range
input double          InpORBMinCloseLocation = 0.72;        // Bull close near high; bear close near low
input double          InpORBMinVolumeRatio = 1.20;          // Breakout tick volume / preceding 20-bar average
input double          InpORBMinRangePoints = 0.0;           // 0 disables minimum range filter
input double          InpORBMaxRangePoints = 0.0;           // 0 disables maximum range filter
input double          InpORBMinRoomToHTFLevelPoints = 0.0;   // 0 disables prior D1/W1 level proximity filter
input double          InpORBScoreBonus = 8.0;               // Bounded directional evidence bonus, not an independent entry

input group "=== SPREAD COST INTELLIGENCE ===";
input bool   InpUseSpreadCostIntelligence = true;
input int    InpSpreadCostMinSamples       = 20;
input double InpSpreadCostMaxCostToGross  = 0.25;
input double InpSpreadCostMaxSpreadToAtr  = 0.15;

input group "=== GAP HOUR CONTINUOUS EXECUTION ===";
input bool   InpGapContinuousExecutionEnabled = true; // Continuously classify spread conditions; all entries use the adaptive market-state gate
input int    InpGapContinuousMinSpreadSamples = 20; // Valid rolling observations required before new entries are permitted
input double InpGapContinuousNormalizationMultiple = 1.5; // Current spread must remain within this multiple of the rolling baseline
input group "=== GAP HOUR OBSERVATION ===";
input bool   InpGapUnlimitedLeverageVerified = false; // Enable only after verifying broker policy for this account and symbol
input bool   InpGapLeverageEligibilityVerified = false; // Enable only after confirming this account meets broker eligibility
input bool   InpGapCommissionScheduleVerified = false; // Enable only after confirming round-trip commission from broker tariff
input int    InpGapReopenStaleSeconds = 3600; // Quote outage duration required before classifying a market reopening
input int    InpGapReopenObservationSeconds = 3600; // Observation window after a detected reopening
input int    InpGapQuoteFreshnessMs = 2000; // Maximum quote age for a valid live observation
input int    InpGapObservationIntervalSeconds = 5; // Persist one observation at this interval
input int    InpGapAnalyticsSummaryIntervalSeconds = 900; // Refresh time-of-week summary every 15 minutes
input group "=== GAP HOUR POST-GAP QUALIFICATION (SIGNAL ONLY) ===";
input bool   InpGapPostGapSignalEnabled = false; // Qualify post-gap continuation; no order is sent by this module
input double InpGapPostGapMinPoints = 0.0; // Symbol-specific M1 open gap threshold; zero disables qualification
input int    InpGapPostGapWaitSeconds = 90; // Monotonic wait after the M1 gap is detected
input int    InpGapPostGapMaxAgeSeconds = 300; // Expire stale post-gap candidates
input double InpGapPostGapMaxSpreadPoints = 15.0; // Absolute spread ceiling after the wait
input double InpGapSpreadNormalizationMultiple = 1.5; // Current spread must also normalize to rolling 100-tick baseline
input double InpGapPostGapMinFollowThroughPoints = 5.0; // Minimum price displacement beyond prior close in gap direction
input double InpGapPostGapMinSweepPenetrationPoints = 5.0; // Minimum penetration beyond prior close to classify a failed gap
input bool   InpGapPostGapAllowSweepReversal = true; // Expose a separately labelled sweep-reversal candidate
input bool   InpGapRolloverSignalEnabled = false; // Observe rollover spread spikes; direction is not inferred from spread
input int    InpGapRolloverStartMinute = 0; // Broker-server minute of day, 0-1439; equal start/end disables window
input int    InpGapRolloverEndMinute = 0; // Broker-server minute of day, 0-1439
input double InpGapRolloverSpikeMultiple = 3.0; // Current spread / prior rolling baseline

input group "=== RISK ENGINE ===";
input double         InpDailyLossLimitPercent   = 8.0;    // Daily loss limit (%) - stops session when hit
input int            InpMaxConsecutiveLosses    = 5;      // Max consecutive losses before pausing
input int            InpMaxOpenPositions        = 1;      // Max simultaneously open positions
input int            InpMaxFlipsPerDay          = 0;       // 0 = no fixed daily flip-count cap; every opportunity must still pass all risk gates
input int            InpMaxTradesPerRollingPeriod = 0;       // 0 = no fixed rolling trade-count cap; safety controls remain active
input int            InpRollingPeriodSeconds    = 300;     // Rolling window length, seconds
input double         InpMaxSpreadPoints         = 250;     // Max acceptable spread, points
input double         InpMaxSlippagePoints       = 30;      // Max acceptable slippage, points
input double         InpMinFreeMarginPercent    = 150.0;   // Existing minimum margin-level gate
input double         InpEmergencyMarginLevel     = 150.0;   // Close this EA's managed position below this broker margin level
input double         InpWeeklyLossLimitPercent  = 15.0;    // Weekly loss limit (%), Monday-anchored - stops the week when hit
input int            InpMaxPositionsPerSymbol   = 1;       // Max simultaneously open positions on this symbol specifically
input double         InpBrokerStopOutBufferPercent = 100.0; // Keep projected margin level this many percentage points above broker call/stop-out thresholds
input int            InpMaxExecutionFailures    = 5;        // Max consecutive order-send failures before blocking new entries

input group "=== EXECUTION MODE & EMERGENCY CONTROLS ===";
input ENUM_AX_EXECUTION_MODE InpExecutionMode = AX_EXEC_ANALYSIS_ONLY; // ANALYSIS_ONLY sends no orders at all - see EmergencyControls.mqh

input group "=== DISTRIBUTED ACCOUNT RISK COORDINATOR ===";
input string InpRiskCoordinatorUrl = ""; // HTTPS base URL for the persistent risk service
input string InpRiskCoordinatorKey = ""; // Secret from the server environment; never share .set files containing this value
input int    InpRiskCoordinatorTimeoutMs = 3000; // Fail-closed request timeout, milliseconds
input bool           InpEnableTrading           = true;    // Master trading switch - false blocks ALL new entries (existing positions still managed)
input bool           InpEnableLong              = true;    // false blocks new BUY entries specifically
input bool           InpEnableShort             = true;    // false blocks new SELL entries specifically

input group "=== SIGNAL SCORE ===";
input double         InpMinScoreToAct           = 60.0;    // Min BUY/SELL score required to act
input double         InpMinGapToAct             = 15.0;    // Min BUY-SELL gap required to act

input group "=== ENTRY ===";
input double         InpMinConfidenceToEnter    = 65.0;    // Min confidence % to open a new position

input group "=== FLIPDEMON REVERSAL ===";
input int            InpFlipRequiredConfirmations = 3;     // Consecutive confirming ticks required to flip
input double         InpFlipMinConfidence       = 70.0;    // Min confidence % required to confirm a flip

input group "=== ANTI-CHOP ===";
input int            InpAntiChopBaseCooldownSec = 20;      // Base cooldown after a chop-triggering event
input int            InpAntiChopMaxCooldownSec  = 1800;    // Max cooldown ceiling, seconds

input group "=== EXIT / PROFIT MANAGEMENT ===";
input double         InpEmergencySlPoints       = 300;     // Emergency stop-loss distance, points
input double         InpDynamicTpRR             = 1.6;     // Take-profit as multiple of SL distance
input double         InpBreakEvenTriggerPoints  = 150;     // Favorable move required to arm break-even
input double         InpBreakEvenLockPoints     = 20;      // Points locked in beyond entry at break-even
input double         InpTrailStartPoints        = 220;     // Favorable move required to start trailing
input double         InpTrailDistancePoints     = 120;     // Trailing distance, points
input int            InpMaxHoldSeconds          = 0;       // 0 = no time-based exit; trend, structure and protective exits govern holding duration
input double         InpMaxHoldExtensionMultiplier = 2.0;  // Optional extension multiplier when a positive maximum holding time is configured
input double         InpSpreadAbnormalMultiplier= 2.2;     // Spread-abnormal exit multiplier vs average
input double         InpOpposingExitConfidence  = 55.0;    // Confidence required for a defensive opposite-signal exit
input bool           InpUseAtrStops             = true;    // Widen the emergency SL by ATR when volatility warrants it
input double          InpAtrStopMultiplier      = 1.8;     // ATR multiple compared against the fixed SL floor

// Intentional partial-profit exits are disabled. Positions remain full-size until a full exit decision.
input bool            InpEnablePartialTP        = false;   // Bank part of the position at a defined R-multiple
input double          InpPartialTriggerRR       = 1.0;     // Favorable move required, as a multiple of the SL distance
input double          InpPartialClosePercent    = 50.0;    // % of current position volume to close on trigger

input group "=== HIGHER-TIMEFRAME CONFLUENCE ===";
input ENUM_TIMEFRAMES InpHtfTimeframe           = PERIOD_H1; // Higher timeframe used for the confluence filter
input bool            InpRequireHtfConfluence   = true;      // Block entries that fight a clear HTF trend
input double          InpHtfMinR2ToBlock        = 0.35;      // HTF R^2 below this = no clear HTF opinion, don't block
input bool            InpRequireH4TrendFilter    = true;      // Require closed H4 price/EMA400 slope agreement with W1/D1
input double          InpH4BreakoutScoreBonus     = 8.0;       // Bounded score bonus for a confirmed H4 20-bar range breakout

input group "=== SESSION / ROLLOVER FILTER ===";
input int             InpSessionStartHour       = 0;   // Broker-time session start hour (0-23); equal to end = no restriction
input int             InpSessionEndHour         = 0;   // Broker-time session end hour (0-23)
input int             InpAvoidRolloverMinutes   = 5;   // Minutes around broker midnight to avoid (spread spikes)
input bool            InpGapHourBypassSessionHours = false; // Let qualified Gap Hour setups ignore the ordinary session-hour window
input bool            InpGapHourAllowRollover      = false; // Explicitly permit Gap Hour entries inside the rollover avoidance window

input group "=== ADAPTIVE TUNING ===";
input bool            InpAdaptiveTuning         = true;   // Nudge the confidence bar from trailing live performance
input int             InpAdaptiveLookbackTrades = 20;     // Trades considered for the adaptive read
input double          InpAdaptiveMinMultiplier  = 0.85;   // Floor on the adaptive confidence multiplier
input double          InpAdaptiveMaxMultiplier  = 1.25;   // Ceiling on the adaptive confidence multiplier

input group "=== EXECUTION ===";
input ulong          InpMagicNumber             = 24091500; // Magic number
input int            InpDeviationPoints         = 20;       // Min allowed price deviation, points (floor)
input double          InpDeviationSpreadMultiplier = 1.5;   // Deviation also scales to spread*this, whichever is larger
input int            InpMaxExecRetries          = 2;        // Max retries on transient broker errors

input group "=== LIVE EXECUTION QUALITY ===";
input int             InpMaxFillLatencyMs        = 800;     // Fill considered "slow" past this, ms
input int             InpMaxConsecutivePoorFills = 4;       // Kill switch after this many consecutive slow/high-slippage fills
input int             InpMaxModifyFailures       = 3;       // Force-exit a position after this many failed SL/TP modifies

input group "=== STATISTICS / GATE ===";
input int            InpMinTradesForGateSignal  = 20;      // Min trades before the gate reports anything but INSUFFICIENT_DATA
input int            InpMinTradesForValidation  = 100;     // Min trades before VALIDATED is possible
input double         InpMaxAcceptableDrawdownPct= 15.0;    // Max drawdown % still compatible with VALIDATED

input group "=== MISC ===";
input ENUM_TIMEFRAMES InpRegimeTimeframe        = PERIOD_M1; // Timeframe used for regime/liquidity structure
input bool            InpShowDashboard          = true;      // Show on-chart dashboard
input bool            InpCloseAllOnKill         = true;      // Close open position when kill switch activates
input bool            InpVerboseLogging         = false;     // Verbose diagnostic logging (keep off live)
input int             InpMaxConsecutiveExecFailures = 3;     // Consecutive execution failures before auto-kill

input group "=== REGIME INTELLIGENCE (ANALYSIS ONLY) ===";
input bool            InpEnableRegimeClassificationAnalysis = true; // Observe R1-R8 classifications; never gates orders
input bool            InpEnableRegimeResearchJournal = true; // Persist one research row per completed regime bar; never gates orders
input string          InpMacroReferenceSymbol = ""; // Optional broker-specific cross-asset symbol; blank means unavailable
input int             InpRegimePersistenceBars = 5; // Completed bars required before a trend is called persistent
input double          InpRegimePersistenceStability = 70.0; // Direction-sign stability floor, percent
input double          InpRegimePersistenceMomentum = 0.70; // Existing momentum persistence floor
input double          InpRegimeShockAccelPct = 60.0; // ATR acceleration threshold for volatility-shock classification

input group "=== ADVANCED TREND SUITE (ANALYSIS ONLY) ===";
input bool            InpEnableAdvancedTrendSuite = true;
input ENUM_TIMEFRAMES InpAdvancedSignalTimeframe = PERIOD_H1;
input int             InpAlphaTrendPeriod = 14;
input double          InpAlphaTrendMultiplier = 1.0;
input int             InpMfiPeriod = 14;
input int             InpSlingshotFastEMA = 38;
input int             InpSlingshotSlowEMA = 62;
input int             InpChandelierLookback = 22;
input int             InpChandelierAtrPeriod = 22;
input double          InpChandelierAtrMultiplier = 3.0;
input double          InpShadowRiverSensitivityPoints = 100.0;
input double          InpShadowRiverReversalMultiplier = 2.0;

//====================================================================
// GLOBAL ENGINE OBJECTS
//====================================================================
CBrokerCompatibility  g_brokerCompatibility;
SAxBrokerCompatibilitySnapshot g_brokerSnapshot;
CMarketData          g_md;
CMarketSnapshotRecorder g_marketSnapshotRecorder;
CSpreadCostIntelligence g_spreadCost;
CGapIntelligenceEngine g_gapIntelligence;
CGapExecutionEngine g_gapExecution;
SAxGapExecutionSignal g_gapExecutionSignal;
SAxGapMarketCondition g_gapMarketCondition;
ENUM_AX_GAP_MARKET_STATE g_gapMarketLastState=AX_GAP_MARKET_INVALID;
ENUM_AX_GAP_EXEC_STATE g_gapExecutionLastState=AX_GAP_EXEC_IDLE;
CGapObservationJournal g_gapJournal;
CGapWindowAnalytics g_gapAnalytics;
bool g_gapAnalyticsReady=false;
datetime g_gapLastAnalysisTime=0;
datetime g_gapLastSummaryTime=0;
bool g_gapJournalReady=false;
datetime g_gapLastJournalTime=0;
SAxGapSnapshot g_gapSnapshot;
long g_gapLastQuoteTimeMsc=0;
datetime g_gapReopenUntil=0;
bool g_gapObservationInitialized=false;
CMomentumEngine       g_mom;
CMicrostructureEngine g_micro;
CHawkesEventIntensityEngine g_hawkesEventIntensity;
SAxHawkesSnapshot g_hawkesSnapshot;
CLiquidityEngine      g_liq;
CRegimeEngine         g_regime;
CRegimeEngine         g_regimeHtf;
CMacroRegimeEngine    g_macroRegime;
CVolatilityEngine     g_volatility;
CRegimeIntelligenceEngine g_regimeIntelligence;
CRegimeClassifierEngine g_regimeClassifier;
CShadowRiverEngine g_shadowRiver;
CAlphaTrendEngine g_alphaTrend;
CMFIEngine g_mfi;
CSlingshotEMAEngine g_slingshot;
CChandelierExitEngine g_chandelier;
CUltimateTrendAlphaEngine g_ultimateTrendAlpha;
CAdaptiveMarketRegimeEngine g_adaptiveMarketRegime;
CExecutionFeedbackEngine g_executionFeedback;
SAxRegimeIntelligence g_regimeIntelSnapshot;
SAxRegimeClassification g_regimeClassification;
CRegimeResearchJournal g_regimeJournal;
bool                  g_regimeJournalReady = false;
bool                  g_volatilityReady = false;
bool                  g_regimeClassificationAvailable = false;
CStructureEngine      g_structure;
CPurePriceAction      g_purePriceAction;
bool                  g_purePriceActionReady = false;
CW1InstitutionalDirection g_w1Institutional;
CD1InstitutionalLevels g_d1Institutional;
CInstitutionalEvidenceAdapter g_institutionalEvidenceAdapter;
CEvidenceArbitrationEngine g_evidenceArbitrator;
CPremiumDiscountEngine g_premiumDiscount;
CMarketMakerModelEngine g_marketMakerModel;
CFairValueGapEngine g_fvg;
COrderBlockEngine g_orderBlock;
CDailyExtremeProjectionEngine g_dailyExtremeProjection;
CH4TrendBreakoutEngine g_h4TrendBreakout;
CCompositeDirectionEngine g_compositeDirection;
CVPMACDEngine         g_vpMacd;
CNewsDefenseEngine    g_newsDefense;
CSignalScorer         g_scorer;
CFlipEngine           g_flip;
CAntiChopEngine       g_chop;
CRiskEngine           g_risk;
CMarginGuard           g_marginGuard;
CAccountRiskCalculator g_accountRisk;
CAccountRiskCoordinator g_accountRiskCoordinator;
CDistributedRiskCoordinator g_distributedRiskCoordinator;
CEmergencyControls    g_emergency;
ENUM_AX_VWAP_EXIT_MODE g_effectiveVwapExitMode = AX_VWAP_EXIT_OFF; // set at OnInit, may be forced
                                                                     // down from InpVWAPExitMode - see
                                                                     // OnInit's validation for why
CEntryEngine          g_entryEngine;
CExecutionEligibility g_executionEligibility;
CTradeLifecycle        g_tradeLifecycle;
CExecutionEngine      g_exec;
CExecutionLatencyProfiler g_executionLatency;
CExecutionQualityJournal g_executionQualityJournal;
bool g_executionQualityJournalReady=false;
CAxIQ200Telemetry g_iq200Telemetry;
bool g_iq200TelemetryReady=false;
CExitEngine           g_exit;
CSniperEngine         g_sniper;
CPrecisionEntryEngine g_precisionEntry;
bool g_precisionEntryReady=false;
COrderFlowEngine      g_orderFlow;
CVolumeProfileEngine  g_volProfile;
CFootprintEngine      g_footprint;
CPulseEngine          g_pulse;
CHeatmapEngine        g_heatmap;
CAdaptiveFlipEngine   g_afe;
CAccountFlipEngine    g_accountFlip;
CVWAPEngine           g_vwap;
CContinuationIntelligence g_continuationIntelligence;
datetime g_lastContinuationDiagnosticBar=0;
CAdvancedSessionORBEngine g_advancedSessionOrb;
datetime g_lastOrbDiagnosticBar=0;
CTradeAutopsy         g_autopsy;
CStatistics           g_stats;
CAccuracyEngine       g_accuracy;
CDashboard            g_dash;
CTradeReconciler       g_tradeReconciler;
CRestartRecovery       g_restartRecovery;
CVirtualExitRegistry   g_virtualExitRegistry;
CHedgingPartialCloseLedger g_hedgingPartialCloseLedger;
bool g_hedgingPartialLedgerReady=false;
CHedgingFullCloseLedger g_hedgingFullCloseLedger;
bool g_hedgingFullCloseLedgerReady=false;
CPyramidEngine         g_pyramidEngine; // calculation engine; campaign execution remains disabled until lifecycle integration
CPyramidCampaignRegistry g_pyramidCampaignRegistry; // durable campaign state; execution integration is not active yet
CHedgingPositionManager g_hedgingPositionManager;
CHedgingCampaignLifecycle g_hedgingCampaignLifecycle;
CPositionStateRegistry g_positionStateRegistry; // durable state keyed by broker POSITION_IDENTIFIER
bool g_positionStateRegistryReady=false;
bool g_hedgingLifecycleLock=false; // sticky fail-closed lock after multiple live legs are detected
bool                   g_virtualExitInitialized = false;
bool                   g_virtualExitReady = false; // persistence and broker-state reconciliation must both be verified
bool                   g_recoveryInitialized = false;
bool                   g_recoveryReady = false; // false means new entries are blocked; existing positions remain managed
bool                   g_nettingReversalQuarantined = false; // broker reversed the net position; stale campaign state must never manage the new side
bool                   g_accountRiskIntegrityLock = false; // post-fill breach/unknown exposure; cleared only by a clean broker rescan
bool                   g_distributedRecoveryPending = false;
bool                   g_distributedRejectedCallbackPending = false; // matching definitive request rejection waits for timer-side broker snapshot // unresolved terminal reservation or startup snapshot; timer retries while all new entries stay blocked
bool                   g_accountRiskReconciliationPending = false; // any broker transaction dirties the account-wide exposure snapshot
bool                   g_pyramidReady = false; // broker history and durable campaign registry must reconcile before any future scale-in path
bool                   g_pyramidReconcilePending = false; // a confirmed entry deal waits for live-position and protective-stop reconciliation
datetime               g_lastPyramidDecisionBar = 0; // one evaluation per completed H1 bar, never one per tick
datetime               g_lastAdvancedSignalBar = 0;

SAxPositionState      g_posState;
bool                  g_haveOpenPosition = false;
ulong                 g_positionIdentifier = 0; // POSITION_IDENTIFIER retained for history lookup
bool                  g_partialClosePending = false;
double                g_pendingPartialCloseVolume = 0.0;
ENUM_AX_ENGINE_STATE  g_engineState = AX_ENGINE_ACTIVE;
datetime              g_lastBarTime = 0;
datetime              g_lastHtfBarTime = 0;
int                   g_consecutiveExecFailures = 0;
double                g_adaptiveConfMultiplier = 1.0;
// the score actually acted on this tick, AFTER AxApplyOrderFlowBonus - CSignalScorer's own Last()
// only ever holds the PRE-bonus reading, so the dashboard reads this instead to show what really
// drove the decision rather than a stale, lower-confidence number that silently diverges from it
SAxScore              g_lastScore;

// VWAP Trend Engine readings, refreshed once per new bar (same cadence as regime/liquidity) -
// g_vwapValue is -1 when unavailable, g_vwapTrend is "NEUTRAL" in that case (never fabricated)
double                g_vwapValue = -1.0;
string                g_vwapTrend = "NEUTRAL";
double                g_lastClosedBarClose = 0.0;

//--- live execution-quality tracking: a demo feed rarely shows meaningful slippage or fill    ---
//--- latency, so these only really start to matter once running on a live account. Tracked    ---
//--- separately from g_consecutiveExecFailures (hard broker errors) because a "successful" but ---
//--- badly-slipped or slow fill is its own live-only warning sign that a fresh entry gets past. ---
int                   g_consecutivePoorFills = 0;
bool                  g_isLiveAccount = false;
double                g_sumSlippagePts = 0;
double                g_sumLatencyMs = 0;
int                   g_fillCount = 0;
int                   g_poorFillsToday = 0;
datetime              g_lastStatsDay = 0;

//--- pending entry intent: decision made on tick N, re-verified and executed on a later tick ---
bool                  g_pendingActive = false;
SAxScore              g_pendingScore;
datetime              g_pendingTime = 0;
#define AX_PENDING_MAX_AGE_SEC 2

//--- accuracy-engine registration throttle: sample at most once per direction-state or once ---
//--- per second, rather than every tick a decisive signal persists (avoids saturating the    ---
//--- accuracy ring buffer on fast-ticking symbols before longer horizons can resolve)         ---
ENUM_AX_DIR           g_lastAccSignalDir = AX_DIR_NONE;
datetime              g_lastAccSignalTime = 0;

//====================================================================
// HELPERS
//====================================================================
double AxRiskPercentForMode(void)
  {
   double maximumRisk=AxClampD(InpMaxAccountStopRiskPercent,0.05,100.0);
   if(InpMode==AX_MODE_NORMAL)      return(MathMin(0.5,maximumRisk));
   if(InpMode==AX_MODE_AGGRESSIVE)  return(MathMin(1.0,maximumRisk));
   return(AxClampD(InpExtremeRiskPercent,0.05,maximumRisk));
  }

// Margin utilisation is selected independently from strategy aggression and stop-loss risk.
double AxMarginUsageLimitForProfile(void)
  {
   if(InpMarginProfile==AX_MARGIN_LOW)      return(5.0);
   if(InpMarginProfile==AX_MARGIN_MEDIUM)   return(50.0);
   if(InpMarginProfile==AX_MARGIN_MAXIMUM)  return(100.0);
   return(0.0); // invalid profile fails closed
  }

// Maximum additional margin permitted by the selected account utilisation profile.
// The budget is capped by actual free margin and never assumes leverage.
bool AxAdditionalMarginBudgetMoney(double &budget,string &reason)
  {
   budget=0.0;
   reason="";
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double usedMargin=AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double limitPct=AxMarginUsageLimitForProfile();
   if(!MathIsValidNumber(equity) || equity<=0.0 ||
      !MathIsValidNumber(usedMargin) || usedMargin<0.0 ||
      !MathIsValidNumber(freeMargin) || freeMargin<0.0 ||
      !MathIsValidNumber(limitPct) || limitPct<=0.0 || limitPct>100.0)
     {
      reason="MARGIN_PROFILE_OR_ACCOUNT_SNAPSHOT_INVALID";
      return(false);
     }
   double profileBudget=equity*limitPct/100.0-usedMargin;
   budget=MathMin(freeMargin,profileBudget);
   if(!MathIsValidNumber(budget) || budget<=0.0)
     {
      budget=0.0;
      reason="MARGIN_PROFILE_BUDGET_EXHAUSTED";
      return(false);
     }
   return(true);
  }

 // Uses broker-reported stop-out settings, not a guessed universal threshold.
 // Money-based stop-out modes are rejected because their thresholds are not
 // directly comparable with a projected margin-level percentage.
bool AxBrokerMarginPreflight(const double requiredMargin,
                             double &projectedUsage,
                             double &projectedLevel,
                             string &reason)
  {
   projectedUsage=1000000.0;
   projectedLevel=0.0;
   reason="";
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double usedMargin=AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(!MathIsValidNumber(requiredMargin) || requiredMargin<=0.0 ||
      !MathIsValidNumber(equity) || equity<=0.0 ||
      !MathIsValidNumber(usedMargin) || usedMargin<0.0 ||
      !MathIsValidNumber(freeMargin) || freeMargin<0.0)
     {
      reason="BROKER_MARGIN_ACCOUNT_VALUES_INVALID";
      return(false);
     }
   double additionalMarginBudget=0.0;
   string budgetReason="";
   if(!AxAdditionalMarginBudgetMoney(additionalMarginBudget,budgetReason))
     {
      reason=budgetReason;
      return(false);
     }
   if(requiredMargin>additionalMarginBudget+0.01)
     {
      reason="SELECTED_MARGIN_PROFILE_BUDGET_EXCEEDED";
      return(false);
     }
   ENUM_ACCOUNT_STOPOUT_MODE stopoutMode=(ENUM_ACCOUNT_STOPOUT_MODE)AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);
   if(stopoutMode!=ACCOUNT_STOPOUT_MODE_PERCENT)
     {
      reason="BROKER_MONEY_BASED_STOPOUT_UNSUPPORTED_FAIL_CLOSED";
      return(false);
     }
   double marginCall=AccountInfoDouble(ACCOUNT_MARGIN_SO_CALL);
   double stopout=AccountInfoDouble(ACCOUNT_MARGIN_SO_SO);
   if(!MathIsValidNumber(marginCall) || !MathIsValidNumber(stopout) ||
      marginCall<0.0 || stopout<0.0 ||
      !MathIsValidNumber(InpBrokerStopOutBufferPercent) || InpBrokerStopOutBufferPercent<0.0)
     {
      reason="BROKER_STOPOUT_THRESHOLDS_INVALID";
      return(false);
     }
   double projectedMargin=usedMargin+requiredMargin;
   projectedUsage=projectedMargin/equity*100.0;
   projectedLevel=(projectedMargin>0.0)?equity/projectedMargin*100.0:1000000.0;
   double brokerFloor=MathMax(marginCall,stopout)+InpBrokerStopOutBufferPercent;
   double requiredLevel=MathMax(InpMinFreeMarginPercent,brokerFloor);
   if(projectedLevel<requiredLevel)
     {
      reason="BROKER_MARGIN_LEVEL_BUFFER_NOT_MET";
      return(false);
     }
   return(true);
  }

//--- sums only OUT deals with a ticket strictly greater than sinceTicketExclusive - lets partial ---
//--- closes and the eventual final close each claim their own slice of a position's deal history ---
//--- with no double count. Filtering by ticket (not DEAL_TIME) matters: MT5 deal time only has    ---
//--- 1-second resolution, so a fast scalper's entry-to-exit could land in the same wall-clock      ---
//--- second - deal tickets are strictly increasing in chronological order regardless.              ---
// Position-scoped close history reader. Unlike the legacy single-campaign wrapper,
// this function has no dependency on g_posState or g_positionIdentifier and can
// reconcile each hedging/pyramid leg independently by stable broker identity.
bool AxFetchCloseFinancialsByIdentifier(const ulong positionIdentifier,
                                        const string expectedSymbol,const ulong expectedMagic,
                                        const ENUM_AX_DIR expectedDirection,
                                        const ulong sinceTicketExclusive,
                                        double &closePrice,double &grossProfit,
                                        double &commission,double &swap,datetime &closeTime,
                                        ulong &lastDealTicketOut,double &closedVolumeOut)
  {
   closePrice=0.0;
   grossProfit=0.0;
   commission=0.0;
   swap=0.0;
   closeTime=0;
   lastDealTicketOut=sinceTicketExclusive;
   closedVolumeOut=0.0;
   if(positionIdentifier==0 || expectedSymbol=="" || expectedMagic==0 ||
      (expectedDirection!=AX_DIR_BUY && expectedDirection!=AX_DIR_SELL) ||
      !HistorySelectByPosition((long)positionIdentifier))
      return(false);

   const long expectedCloseType=(expectedDirection==AX_DIR_BUY)?DEAL_TYPE_SELL:DEAL_TYPE_BUY;
   double weightedCloseValue=0.0;
   bool found=false;
   const int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      const ulong dealTicket=HistoryDealGetTicket(i);
      if(dealTicket==0 || dealTicket<=sinceTicketExclusive) continue;
      if((ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID)!=positionIdentifier)
         return(false);
      if(HistoryDealGetString(dealTicket,DEAL_SYMBOL)!=expectedSymbol ||
         (ulong)HistoryDealGetInteger(dealTicket,DEAL_MAGIC)!=expectedMagic)
         return(false);

      const long entryType=HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      // A reversal deal mixes closing and opening volume. Its close allocation
      // cannot be inferred from DEAL_VOLUME, so force explicit reconciliation.
      if(entryType==DEAL_ENTRY_INOUT) return(false);
      if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) continue;
      if(HistoryDealGetInteger(dealTicket,DEAL_TYPE)!=expectedCloseType)
         return(false);

      const double dealVolume=HistoryDealGetDouble(dealTicket,DEAL_VOLUME);
      const double dealPrice=HistoryDealGetDouble(dealTicket,DEAL_PRICE);
      const double dealProfit=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
      const double dealCommission=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
      const double dealSwap=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
      if(!MathIsValidNumber(dealVolume) || dealVolume<=0.0 ||
         !MathIsValidNumber(dealPrice) || dealPrice<=0.0 ||
         !MathIsValidNumber(dealProfit) || !MathIsValidNumber(dealCommission) ||
         !MathIsValidNumber(dealSwap))
         return(false);

      grossProfit+=dealProfit;
      commission+=dealCommission;
      swap+=dealSwap;
      closedVolumeOut+=dealVolume;
      weightedCloseValue+=dealPrice*dealVolume;
      if(dealTicket>lastDealTicketOut)
        {
         lastDealTicketOut=dealTicket;
         closeTime=(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
        }
      found=true;
     }
   if(!found || closedVolumeOut<=0.0) return(false);
   closePrice=weightedCloseValue/closedVolumeOut;
   return(MathIsValidNumber(closePrice) && closePrice>0.0);
  }

// Persist one reconciled partial-exit slice without consulting single-position globals.
// The caller must supply the durable position snapshot and broker-history aggregates.
bool AxRecordHedgingPartialCloseLedger(const SAxVirtualExitRecord &saved,
                                       const double closePrice,const double grossProfit,
                                       const double commission,const double swap,
                                       const datetime closeTime,const ulong lastDealTicket,
                                       const double closedVolume)
  {
   if(!g_hedgingPartialLedgerReady || !g_hedgingPartialCloseLedger.IsPersisting() ||
      saved.positionIdentifier==0 || saved.symbol=="" ||
      saved.entryTime<=0 || saved.entryPrice<=0.0 || saved.entryVolume<=0.0 ||
      lastDealTicket==0 || closeTime<=0 || closePrice<=0.0 ||
      closedVolume<=0.0 || closedVolume>=saved.entryVolume ||
      !MathIsValidNumber(closePrice) || !MathIsValidNumber(grossProfit) ||
      !MathIsValidNumber(commission) || !MathIsValidNumber(swap) ||
      !MathIsValidNumber(closedVolume))
      return(false);

   SAxPartialCloseLedgerRecord record;
   record.positionIdentifier=saved.positionIdentifier;
   record.dealTicket=lastDealTicket;
   record.symbol=saved.symbol;
   record.magic=InpMagicNumber;
   record.direction=saved.dir;
   record.entryTime=saved.entryTime;
   record.entryPrice=saved.entryPrice;
   record.entryVolume=saved.entryVolume;
   record.closeTime=closeTime;
   record.closePrice=closePrice;
   record.closedVolume=closedVolume;
   record.grossProfit=grossProfit;
   record.commission=commission;
   record.swap=swap;
   if(!g_hedgingPartialCloseLedger.Record(record) ||
      !g_hedgingPartialCloseLedger.IsPersisting())
     {
      PrintFormat("FLIPDEMON HEDGING PARTIAL LEDGER ERROR: durable slice rejected for identifier=%I64u deal=%I64u; action lock must remain held.",
                  saved.positionIdentifier,lastDealTicket);
      return(false);
     }
   return(true);
  }

bool AxFetchCloseFinancials(const ulong posTicket,const ulong sinceTicketExclusive,double &closePrice,
                             double &grossProfit,double &commission,double &swap,datetime &closeTime,
                             ulong &lastDealTicketOut,double &closedVolumeOut)
  {
   closePrice=0; grossProfit=0; commission=0; swap=0; closeTime=0;
   lastDealTicketOut=sinceTicketExclusive; closedVolumeOut=0.0;
   // HistorySelectByPosition requires POSITION_IDENTIFIER, not POSITION_TICKET.
   // Prefer the campaign's retained identifier; fallback must select the exact ticket,
   // never an arbitrary same-symbol position on a hedging account.
   ulong positionId=(g_posState.ticket==posTicket)?g_positionIdentifier:0;
   if(positionId==0 && PositionSelectByTicket(posTicket) &&
      (ulong)PositionGetInteger(POSITION_TICKET)==posTicket)
      positionId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   if(positionId==0 || !HistorySelectByPosition((long)positionId)) return(false);
   int total=HistoryDealsTotal();
   double weightedCloseValue=0.0;
   bool found=false;
   for(int i=0;i<total;i++)
     {
      ulong dealTicket=HistoryDealGetTicket(i);
      if(dealTicket==0 || dealTicket<=sinceTicketExclusive) continue;
      long entryType=HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      // DEAL_ENTRY_INOUT reverses a netting position: one deal closes the old exposure
      // and opens residual exposure in the opposite direction. Its full DEAL_VOLUME is
      // not the old campaign's closed volume. Do not misattribute it as an ordinary exit.
      if(entryType==DEAL_ENTRY_INOUT)
        {
         g_recoveryReady=false;
         g_nettingReversalQuarantined=true;
         g_accountRiskReconciliationPending=true;
         PrintFormat("FLIPDEMON RECONCILIATION ERROR: netting reversal deal %I64u requires explicit close/open allocation; campaign management and new entries blocked until restart reconciliation.",dealTicket);
         return(false);
        }
      if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) continue;
      double dealVolume=HistoryDealGetDouble(dealTicket,DEAL_VOLUME);
      double dealPrice=HistoryDealGetDouble(dealTicket,DEAL_PRICE);
      if(!MathIsValidNumber(dealVolume) || dealVolume<=0.0 ||
         !MathIsValidNumber(dealPrice) || dealPrice<=0.0)
         return(false);
      grossProfit+=HistoryDealGetDouble(dealTicket,DEAL_PROFIT);
      commission+=HistoryDealGetDouble(dealTicket,DEAL_COMMISSION);
      swap+=HistoryDealGetDouble(dealTicket,DEAL_SWAP);
      closedVolumeOut+=dealVolume;
      weightedCloseValue+=dealPrice*dealVolume;
      if(dealTicket>lastDealTicketOut)
        {
         lastDealTicketOut=dealTicket;
         closeTime=(datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
        }
      found=true;
     }
   if(!found || closedVolumeOut<=0.0) return(false);
   closePrice=weightedCloseValue/closedVolumeOut;
   return(MathIsValidNumber(closePrice) && closePrice>0.0);
  }

// Sum the complete broker-side campaign result, including entry and exit
// commissions/fees and every partial exit. A campaign is one position identifier;
// netting reversals and foreign-magic deals are rejected rather than misattributed.
bool AxGetCampaignNetProfit(const ulong positionIdentifier,const string symbol,
                            const ulong magic,double &netProfit,ulong &lastExitDeal)
  {
   netProfit=0.0;
   lastExitDeal=0;
   if(positionIdentifier==0 || symbol=="" ||
      !HistorySelectByPosition((long)positionIdentifier))
      return(false);

   bool found=false;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0) return(false);
      if((ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=positionIdentifier)
         continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=magic)
         return(false);

      long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_INOUT)
         return(false);
      double profit=HistoryDealGetDouble(deal,DEAL_PROFIT);
      double commission=HistoryDealGetDouble(deal,DEAL_COMMISSION);
      double swap=HistoryDealGetDouble(deal,DEAL_SWAP);
      double fee=HistoryDealGetDouble(deal,DEAL_FEE);
      if(!MathIsValidNumber(profit) || !MathIsValidNumber(commission) ||
         !MathIsValidNumber(swap) || !MathIsValidNumber(fee))
         return(false);
      netProfit+=profit+commission+swap+fee;
      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
        {
         if(deal>lastExitDeal) lastExitDeal=deal;
         found=true;
        }
     }
   return(found && lastExitDeal>0 && MathIsValidNumber(netProfit));
  }

string AxBuildEntryReason(const SAxScore &score,const ENUM_AX_DIR dir)
  {
   string tags="";
   if(score.regime==AX_REGIME_BREAKOUT) tags+="BREAKOUT ";
   bool liqReady = (dir==AX_DIR_BUY) ? g_liq.BullishAttackReady(g_mom.DisplacementPts())
                                       : g_liq.BearishAttackReady(g_mom.DisplacementPts());
   if(liqReady) tags+="LIQUIDITY_SWEEP ";
   SAxMarketMakerModelSnapshot mmxm=g_marketMakerModel.Read();
   if(mmxm.direction==dir && mmxm.stage==AX_MMXM_REVERSAL_CONFIRMED)
      tags+=(dir==AX_DIR_BUY ? "MMBM_CONFIRMED " : "MMSM_CONFIRMED ");
   tags+="MOMENTUM";
   // VWAP trend read reported alongside the other engines here - advisory evidence only, never an
   // override of the regime/structure engines that already decided this trade (Task 2)
   return(StringFormat("%s | %s | VWAP=%s | B=%.0f S=%.0f C=%.0f",
          AxRegimeToString(score.regime),tags,g_vwapTrend,score.buyScore,score.sellScore,score.confidence));
  }

//--- builds a trade record from the current position state; does NOT touch g_posState or file it ---
SAxTradeRecord AxBuildTradeRecord(const double closePrice,const double grossProfit,const double commission,
                                   const double swap,const datetime closeTime,const ENUM_AX_EXIT_REASON reason,
                                   const double lotsForRecord,const bool isPartial)
  {
   SAxTradeRecord rec;
   rec.setupId       = g_posState.setupId;
   rec.dealIdIn      = g_posState.entryDealId;
   rec.ticket        = g_posState.ticket;
   rec.positionIdentifier = g_positionIdentifier;
   rec.entryTime     = g_posState.entryTime;
   rec.exitTime      = (closeTime>0)? closeTime : TimeCurrent();
   rec.direction     = g_posState.dir;
   rec.entryPrice    = g_posState.entryPrice;
   rec.exitPrice     = closePrice;
   rec.lots          = lotsForRecord;
   rec.spreadAtEntry = g_posState.entrySpreadPts;
   rec.slippagePts   = g_posState.entrySlippagePts;
   rec.holdSeconds   = (int)(rec.exitTime-g_posState.entryTime);
   rec.buyScore      = g_posState.entryBuyScore;
   rec.sellScore     = g_posState.entrySellScore;
   rec.confidence    = g_posState.entryConfidence;
   rec.vwapPullbackBullBonus=g_posState.vwapPullbackBullBonus;
   rec.vwapPullbackBearBonus=g_posState.vwapPullbackBearBonus;
   rec.overnightBiasBullBonus=g_posState.overnightBiasBullBonus;
   rec.overnightBiasBearBonus=g_posState.overnightBiasBearBonus;
   rec.twinContinuationBullBonus=g_posState.twinContinuationBullBonus;
   rec.twinContinuationBearBonus=g_posState.twinContinuationBearBonus;
   rec.regime        = g_posState.entryRegime;
   rec.entryReason   = g_posState.entryReason;
   rec.exitReason    = reason;
   rec.mfe           = g_posState.mfeCurrency;
   rec.mae           = g_posState.maeCurrency;
   rec.grossProfit   = grossProfit;
   rec.commission    = commission;
   rec.swap          = swap;
   rec.netProfit     = grossProfit+commission+swap;
   // a partial is never itself the flip's outcome - only the leg's eventual full close is,
   // so tag it flipSeq=0 to keep it out of CORRECT_FLIP/FALSE_FLIP classification entirely
   rec.flipSeq       = isPartial ? 0 : g_posState.flipSeq;
   rec.isPartial     = isPartial;
   rec.afeCapitalState   = g_posState.afeCapitalState;
   rec.afeRiskOfRuinPct  = g_posState.afeRiskOfRuinPct;
   rec.afeExpectedValueR = g_posState.afeExpectedValueR;
   rec.afeWinProbability = g_posState.afeWinProbability;
   rec.afeRiskMultiplier = g_posState.afeRiskMultiplier;
   rec.impactCostPct     = g_posState.impactCostPct;

   //--- R-multiple (Journal v2, spec section 27) - only computed for a full close, never a partial  ---
   //--- slice (a partial's netProfit isn't the whole original risk's outcome, and GetDatasetRecords  ---
   //--- excludes isPartial records from Monte Carlo/Kelly input anyway, so 0 here is correct, not a   ---
   //--- placeholder). Uses g_posState.originalSlPrice - the AS-PLACED stop, never mutated by break-   ---
   //--- even/trailing - so this is always measured against the true original risk, same invariant    ---
   //--- the existing partial-take-profit R-multiple trigger already relies on. ---
   rec.rMultiple = EMPTY_VALUE;
   if(!isPartial && g_posState.originalSlPrice>0)
     {
      double riskPricePts = MathAbs(g_posState.entryPrice-g_posState.originalSlPrice);
      double tickSize = g_md.TickSize();
      double tickValue = g_md.TickValue();
      if(riskPricePts>0 && tickSize>0 && tickValue>0 && g_posState.lots>0)
        {
         double originalRiskCurrency = (riskPricePts/tickSize)*tickValue*g_posState.lots;
         if(originalRiskCurrency>0) rec.rMultiple = rec.netProfit/originalRiskCurrency;
        }
     }

   //--- Frozen evidence is copied from the confirmed position snapshot, never reconstructed from exit-time data.
   rec.vwapStateAtEntry       = g_posState.vwapStateAtEntry;
   rec.vpMacdStateAtEntry     = g_posState.vpMacdStateAtEntry;
   rec.orderFlowStateAtEntry  = g_posState.orderFlowStateAtEntry;
   rec.structureStateAtEntry  = g_posState.structureStateAtEntry;
   rec.liquidityStateAtEntry  = g_posState.liquidityStateAtEntry;
   rec.newsStateAtEntry       = g_posState.newsStateAtEntry;
   rec.sessionAtEntry         = g_posState.sessionAtEntry;
   // dealIdIn is deliberately left 0 until the actual broker IN deal is reconciled by identifier.
   return(rec);
  }

void AxFinalizeTrade(const double closePrice,const double grossProfit,const double commission,
                      const double swap,const datetime closeTime,const ENUM_AX_EXIT_REASON reason,const ulong lastDealTicket)
  {
   SAxTradeRecord rec = AxBuildTradeRecord(closePrice,grossProfit,commission,swap,closeTime,reason,g_posState.lots,false);
   rec.dealIdOut=lastDealTicket;
   rec.positionIdentifier=g_positionIdentifier;

   g_autopsy.RecordTrade(rec);
   if(!g_autopsy.IsPersisting() ||
      (lastDealTicket>0 && g_autopsy.LastAccountedDealTicket(g_positionIdentifier)<lastDealTicket))
     {
      g_recoveryReady=false;
      Print("FLIPDEMON JOURNAL ERROR: final exit persistence is unverified; existing positions remain managed, new entries blocked.");
     }
   else if(lastDealTicket>0 && g_autopsy.LastAccountedDealTicket(g_positionIdentifier)>=lastDealTicket &&
           g_tradeLifecycle.SetupId()==g_posState.setupId)
     {
      // External SL/TP/manual closes arrive through broker history, not AxCloseAndRecord.
      // Convert those confirmed exits into the same lifecycle path before journal completion.
      bool exitTriggered=(g_tradeLifecycle.State()==AX_LIFECYCLE_EXIT_TRIGGERED);
      if(!exitTriggered &&
         (g_tradeLifecycle.State()==AX_LIFECYCLE_POSITION_ACTIVE ||
          g_tradeLifecycle.State()==AX_LIFECYCLE_POSITION_MANAGED))
         exitTriggered=g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_EXIT_TRIGGERED);
      bool lifecycleClosed=exitTriggered &&
                           g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_POSITION_CLOSED) &&
                           g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_JOURNALED) &&
                           g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_AUTOPSIED);
      if(!lifecycleClosed)
        {
         g_recoveryReady=false;
         PrintFormat("FLIPDEMON LIFECYCLE ERROR: closed campaign %s could not complete journal/autopsy transitions (%s); new entries blocked.",
                     g_posState.setupId,g_tradeLifecycle.LastError());
        }
     }
   // A campaign can contain several banked partial exits. Risk streaks must
   // use the complete broker-confirmed campaign result, not only its final slice.
   double campaignNetProfit=0.0;
   ulong campaignLastExitDeal=0;
   if(!AxGetCampaignNetProfit(g_positionIdentifier,_Symbol,InpMagicNumber,
                              campaignNetProfit,campaignLastExitDeal) ||
      campaignLastExitDeal!=lastDealTicket)
     {
      g_recoveryReady=false;
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON RISK ACCOUNTING ERROR: full campaign result is not confirmed for identifier=%I64u; durable recovery records retained.",
                  g_positionIdentifier);
      return;
     }

   // Persist the exit-side registry update before clearing in-memory campaign state. A failed
   // removal does not undo the broker close, but it blocks future entries until recovery is sound.
   bool recoveryRemovalOk = true;
   if(g_recoveryInitialized)
      recoveryRemovalOk = g_restartRecovery.RemoveOpenSetup(g_posState.ticket);
   if(!recoveryRemovalOk || (g_recoveryInitialized && !g_restartRecovery.IsPersisting()))
     {
      g_recoveryReady = false;
      Print("FLIPDEMON RECOVERY ERROR: close completed but registry removal was not persisted; new entries remain blocked.");
     }
   if(g_virtualExitInitialized &&
      (!g_virtualExitRegistry.Remove(g_positionIdentifier) || !g_virtualExitRegistry.IsPersisting()))
     {
      g_virtualExitReady=false;
      Print("FLIPDEMON VIRTUAL EXIT ERROR: position closed but state removal failed; new entries remain blocked.");
     }
   if(g_positionStateRegistryReady &&
      (!g_positionStateRegistry.Remove(g_positionIdentifier) ||
       !g_positionStateRegistry.IsPersisting()))
     {
      g_recoveryReady=false;
      g_hedgingLifecycleLock=true;
      PrintFormat("FLIPDEMON POSITION STATE ERROR: closed identifier=%I64u could not be removed from durable lifecycle ledger; new entries remain blocked.",
                  g_positionIdentifier);
     }
   // Do not re-enable entries from an exit callback. Recovery may have been blocked because
   // startup reconciliation found an untracked/mismatched live position, not merely a failed write.
   // A fresh successful reconciliation is required to clear that safety latch.
   if(rec.flipSeq>0) g_accuracy.RegisterFlipOutcome(campaignNetProfit>0);
   if(campaignLastExitDeal==lastDealTicket)
      g_risk.RegisterTradeClosed(campaignNetProfit);
   if(reason==AX_EXIT_SL || reason==AX_EXIT_MOMENTUM_COLLAPSE || reason==AX_EXIT_MICROSTRUCTURE_REVERSAL)
      g_chop.RegisterStopOut();

   g_haveOpenPosition = false;
   g_posState.active  = false;
   g_posState.ticket  = 0;

   g_positionIdentifier = 0;

   g_partialClosePending = false;

   g_pendingPartialCloseVolume = 0.0;
   g_posState.dir     = AX_DIR_NONE;
   g_posState.entryReason = "";
  }

bool AxCloseAndRecord(const ENUM_AX_EXIT_REASON reason)
  {
   ulong ticket = g_posState.ticket;
   if(g_tradeLifecycle.SetupId()==g_posState.setupId &&
      (g_tradeLifecycle.State()==AX_LIFECYCLE_POSITION_ACTIVE ||
       g_tradeLifecycle.State()==AX_LIFECYCLE_POSITION_MANAGED))
     {
      if(!g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_EXIT_TRIGGERED))
        {
         PrintFormat("FLIPDEMON LIFECYCLE ERROR: close request withheld for setup %s (%s).",
                     g_posState.setupId,g_tradeLifecycle.LastError());
         return(false);
        }
     }
   // Capture the executable quote immediately before this EA-initiated full close.
   // BUY positions sell at bid; SELL positions buy at ask. Use it only after exact
   // broker close-history confirmation below.
   MqlTick exitBenchmarkTick;
   ZeroMemory(exitBenchmarkTick);
   bool exitBenchmarkValid=SymbolInfoTick(_Symbol,exitBenchmarkTick) &&
                           exitBenchmarkTick.bid>0.0 && exitBenchmarkTick.ask>=exitBenchmarkTick.bid;
   double exitBenchmarkPrice=0.0;
   if(exitBenchmarkValid)
      exitBenchmarkPrice=(g_posState.dir==AX_DIR_BUY)?exitBenchmarkTick.bid:exitBenchmarkTick.ask;

   string errReason;
   bool closeOutcomeUncertain=false;
   if(!g_exec.ClosePosition(_Symbol,ticket,g_positionIdentifier,InpMagicNumber,
                            errReason,closeOutcomeUncertain))
     {
      g_consecutiveExecFailures++;
      if(closeOutcomeUncertain)
        {
         // The close may have reached the broker. Stop all new actions and let
         // transaction/history reconciliation establish the actual residual state.
         g_recoveryReady=false;
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         g_accountRiskReconciliationPending=true;
         PrintFormat("FLIPDEMON FULL CLOSE UNCERTAIN: ticket=%I64u positionId=%I64u; no resend, campaign quarantined (%s)",
                     ticket,g_positionIdentifier,errReason);
        }
      else if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: close rejected (%s)",errReason);
      return(false);
     }
   g_consecutiveExecFailures = 0;

   double closePrice=0,grossProfit=0,commission=0,swap=0; datetime closeTime=0; ulong lastTicket=0; double closedVolume=0.0;
   if(!AxFetchCloseFinancials(ticket,g_posState.lastAccountedDealTicket,closePrice,grossProfit,commission,swap,closeTime,lastTicket,closedVolume))
     {
      // Broker close succeeded, but history may lag. Preserve campaign state and defer
      // finalization; returning false prevents immediate flip-entry on incomplete evidence.
      Print("FLIPDEMON: close confirmed but deal history is not ready; finalization deferred.");
      return(false);
     }
   if(exitBenchmarkValid && exitBenchmarkPrice>0.0 && g_md.Point()>0.0)
     {
      // Adverse-only slippage: long exits sell below bid; short exits buy above ask.
      double adverseExitSlippagePts=(g_posState.dir==AX_DIR_BUY)
                                    ?MathMax(0.0,(exitBenchmarkPrice-closePrice)/g_md.Point())
                                    :MathMax(0.0,(closePrice-exitBenchmarkPrice)/g_md.Point());
      if(MathIsValidNumber(adverseExitSlippagePts))
        {
         g_spreadCost.ObserveExitSlippage(adverseExitSlippagePts);
         if(g_executionQualityJournalReady)
           {
            double exitAtrPoints=(g_volatilityReady && g_md.Point()>0.0)
                                 ?g_volatility.CurrentAtr()/g_md.Point():0.0;
            if(!g_executionQualityJournal.Record(TimeCurrent(),"EXIT",(int)g_posState.dir,
                                                 exitBenchmarkTick.bid,exitBenchmarkTick.ask,
                                                 g_md.Point(),exitAtrPoints,(int)g_regime.Regime(),
                                                 (int)g_volatility.State(),adverseExitSlippagePts,0))
              {
               g_executionQualityJournalReady=g_executionQualityJournal.IsPersisting();
               if(!g_executionQualityJournalReady)
                  Print("FLIPDEMON EXECUTION JOURNAL WARNING: persistence lost; telemetry disabled, trading decisions unchanged.");
              }
           }
        }
     }
   AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,reason,lastTicket);
   return(true);
  }

void AxRecordExternalClose(void)
  {
   double closePrice=0,grossProfit=0,commission=0,swap=0; datetime closeTime=0; ulong lastTicket=0; double closedVolume=0.0;
   ENUM_AX_EXIT_REASON reason = AX_EXIT_SL;
   if(!AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,closePrice,grossProfit,commission,swap,closeTime,lastTicket,closedVolume))
     {
      // Never fabricate a zero-PnL outcome when the broker history cache lags.
      // Keep campaign state active so OnTick can retry this reconciliation.
      if(InpVerboseLogging) Print("FLIPDEMON: external close detected but deal history is not ready; finalization deferred.");
      return;
     }
   double distToSl = MathAbs(closePrice-g_posState.initialSlPrice);
   double distToTp = MathAbs(closePrice-g_posState.initialTpPrice);
   reason = (distToTp<distToSl) ? AX_EXIT_TP : AX_EXIT_SL;
   AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,reason,lastTicket);
  }

//--- records the banked slice of a scale-out partial close without touching g_haveOpenPosition; ---
//--- the remainder keeps trading under the same ticket with g_posState.lots reduced accordingly ---
bool AxRecordPartialClose(const double volumeClosed,const double closePrice,const double grossProfit,
                           const double commission,const double swap,const datetime closeTime,
                           const ulong lastDealTicket)
  {
   if(volumeClosed<=0.0 || lastDealTicket==0 || g_positionIdentifier==0)
      return(false);
   SAxTradeRecord rec = AxBuildTradeRecord(closePrice,grossProfit,commission,swap,closeTime,AX_EXIT_TP,volumeClosed,true);
   rec.dealIdOut=lastDealTicket;
   rec.positionIdentifier=g_positionIdentifier;
   g_autopsy.RecordTrade(rec);
   if(g_autopsy.LastAccountedDealTicket(g_positionIdentifier)<lastDealTicket)
     {
      g_recoveryReady=false;
      Print("FLIPDEMON JOURNAL ERROR: partial exit record was not confirmed in the durable journal; action lock retained.");
      return(false);
     }
   // A partial is a banked slice, not the campaign's final outcome.
   g_posState.lots -= volumeClosed;
   g_posState.partialTaken = true;
   g_posState.lastAccountedDealTicket = lastDealTicket;
   g_posState.mfeCurrency = 0;
   g_posState.maeCurrency = 0;
   g_posState.bestFavorablePrice = 0;
   return(true);
  }

// Commit accounting only after broker volume and exact position history agree.
// Registry recording is idempotent for the last deal, allowing journal recovery
// without issuing another broker close request.
bool AxCommitPartialClose(const double volumeClosed,const double closePrice,const double grossProfit,
                          const double commission,const double swap,const datetime closeTime,
                          const ulong lastDealTicket)
  {
   // Commit the deal journal first. If the registry write then fails, the
   // still-locked baseline and unchanged last-deal cursor allow restart replay;
   // the journal deduplicates the already-accounted deal ticket.
   if(!AxRecordPartialClose(volumeClosed,closePrice,grossProfit,commission,swap,closeTime,lastDealTicket))
      return(false);
   if(!g_virtualExitRegistry.RecordPartialClose(g_positionIdentifier,volumeClosed,lastDealTicket) ||
      !g_virtualExitRegistry.IsPersisting())
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON PARTIAL CLOSE ERROR: journal is accounted but registry update failed; action lock retained for restart replay.");
      return(false);
     }
   if(!g_virtualExitRegistry.ResolveAction(g_positionIdentifier,3) ||
      !g_virtualExitRegistry.IsPersisting())
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON PARTIAL CLOSE ERROR: accounting is recorded but the durable action lock could not be cleared.");
      return(false);
     }
   return(true);
  }

void AxExecutePartialClose(const double volumeToClose)
  {
   if(g_partialClosePending)
     {
      if(InpVerboseLogging) Print("FLIPDEMON: partial close reconciliation pending; refusing another scale-out.");
      return;
     }
   SAxVirtualExitRecord partialState;
   if(!g_virtualExitReady || !g_virtualExitRegistry.IsPersisting() ||
      !g_virtualExitRegistry.Find(g_positionIdentifier,partialState) || partialState.actionLocked)
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON PARTIAL CLOSE BLOCKED: durable unlocked position state is unavailable.");
      return;
     }
   if(!PositionSelectByTicket(g_posState.ticket) ||
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=g_positionIdentifier ||
      (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber ||
      MathAbs(PositionGetDouble(POSITION_VOLUME)-g_posState.lots)>
         MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.5,0.0000001))
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON PARTIAL CLOSE BLOCKED: broker position changed before baseline capture.");
      return;
     }
   double partialBaselineVolume=PositionGetDouble(POSITION_VOLUME);
   if(!g_virtualExitRegistry.BeginPartialCloseAction(g_positionIdentifier,partialBaselineVolume) ||
      !g_virtualExitRegistry.IsPersisting())
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON PARTIAL CLOSE BLOCKED: action lock could not be persisted; no broker request sent.");
      return;
     }

   string partErr;
   bool outcomeUncertain=false;
   if(!g_exec.ClosePartial(_Symbol,g_posState.ticket,g_positionIdentifier,InpMagicNumber,volumeToClose,partErr,outcomeUncertain))
     {
      if(outcomeUncertain)
        {
         // The request may have reached the broker. Lock out another scale-out
         // and let the existing history/volume reconciliation path determine
         // what actually happened. Never resend an ambiguous close.
         g_partialClosePending=true;
         g_pendingPartialCloseVolume=volumeToClose;
         g_accountRiskReconciliationPending=true;
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON: partial close outcome uncertain; retry blocked pending broker reconciliation (%s)",partErr);
        }
      else
        {
         // A definite rejection is the only failure path that may release the lock.
         if(!g_virtualExitRegistry.ResolveAction(g_positionIdentifier,3) ||
            !g_virtualExitRegistry.IsPersisting())
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_engineState=AX_ENGINE_PAUSED;
            Print("FLIPDEMON PARTIAL CLOSE ERROR: rejected request lock could not be cleared.");
           }
         else if(InpVerboseLogging)
            PrintFormat("AUTOPSY X: partial close failed (%s)",partErr);
        }
      return;
     }

   g_partialClosePending=true;
   g_pendingPartialCloseVolume=volumeToClose;
   // Do not fabricate a partial-close result if the broker history cache lags.
   double pClosePrice=0,pGross=0,pComm=0,pSwap=0,closedVolume=0.0;
   datetime pTime=0;
   ulong pLastTicket=g_posState.lastAccountedDealTicket;
   if(!AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,
                              pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket,closedVolume))
     {
      g_partialClosePending=true;
      g_pendingPartialCloseVolume=volumeToClose;
      Print("FLIPDEMON: partial close confirmed but deal history is not ready; accounting deferred.");
      return;
     }

   if(!PositionSelectByTicket(g_posState.ticket))
     {
      g_partialClosePending=true;
      g_pendingPartialCloseVolume=volumeToClose;
      Print("FLIPDEMON: partial-close position snapshot unavailable; accounting deferred.");
      return;
     }
   double actualClosed=g_posState.lots-PositionGetDouble(POSITION_VOLUME);
   double volumeTolerance=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.5,0.0000001);
   if(actualClosed<=0.0 || MathAbs(actualClosed-closedVolume)>volumeTolerance)
     {
      g_partialClosePending=true;
      g_pendingPartialCloseVolume=volumeToClose;
      Print("FLIPDEMON: partial close deal found but broker volume has not reconciled; accounting deferred.");
      return;
     }
   if(!AxCommitPartialClose(actualClosed,pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket))
      return;
   g_partialClosePending=false;
   g_pendingPartialCloseVolume=0.0;
  }

// Retry accounting only. Never submit a second close order while reconciliation is pending.
void AxRetryPendingPartialClose(void)
  {
   if(!g_partialClosePending || !g_posState.active) return;
   if(!PositionSelectByTicket(g_posState.ticket))
     {
      // The tracked ticket is gone. The final-close history query will consume all unaccounted exit deals.
      g_partialClosePending=false;
      g_pendingPartialCloseVolume=0.0;
      return;
     }

   double pClosePrice=0,pGross=0,pComm=0,pSwap=0,closedVolume=0.0;
   datetime pTime=0;
   ulong pLastTicket=g_posState.lastAccountedDealTicket;
   if(!AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,
                              pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket,closedVolume))
      return;
   if(!PositionSelectByTicket(g_posState.ticket)) return;
   double actualClosed=g_posState.lots-PositionGetDouble(POSITION_VOLUME);
   double volumeTolerance=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)*0.5,0.0000001);
   if(actualClosed<=0.0 || MathAbs(actualClosed-closedVolume)>volumeTolerance) return;

   if(!AxCommitPartialClose(actualClosed,pClosePrice,pGross,pComm,pSwap,pTime,pLastTicket))
      return;
   g_partialClosePending=false;
   g_pendingPartialCloseVolume=0.0;
  }


bool AxSaveVirtualExitState(const bool allowEmergencyUpdate=false,const bool isNewFill=false)
  {
   if(!PositionSelect(_Symbol)) return(false);
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) return(false);

   ulong ticket=(ulong)PositionGetInteger(POSITION_TICKET);
   ulong positionId=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   long type=PositionGetInteger(POSITION_TYPE);
   ENUM_AX_DIR dir=(type==POSITION_TYPE_BUY) ? AX_DIR_BUY : AX_DIR_SELL;
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double brokerSl=PositionGetDouble(POSITION_SL);
   double brokerTp=PositionGetDouble(POSITION_TP);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ticket==0 || positionId==0 || entry<=0.0 || brokerSl<=0.0 ||
      tickSize<=0.0 || !MathIsValidNumber(entry) || !MathIsValidNumber(brokerSl))
     {
      g_virtualExitReady=false;
      Print("FLIPDEMON VIRTUAL EXIT: broker position identity or emergency SL invalid; new entries blocked.");
      return(false);
     }

   SAxVirtualExitRecord record,existing;
   bool found=g_virtualExitRegistry.Find(positionId,existing);
   double riskDistance=MathAbs(entry-brokerSl);
   double initialSl=brokerSl;
   bool breakEvenDone=false;
   if(found)
     {
      // POSITION_IDENTIFIER is the stable broker identity. POSITION_TICKET can
      // change after broker service operations, so a ticket-only change is not
      // a different trade and must not discard its original-risk/exit history.
      if(existing.symbol!=_Symbol || existing.dir!=dir ||
         (!allowEmergencyUpdate && MathAbs(existing.emergencySlPrice-brokerSl)>tickSize*0.5))
        {
         g_virtualExitReady=false;
         PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: persisted state identity or emergency stop mismatches broker position ticket=%I64u identifier=%I64u; new entries blocked.",ticket,positionId);
         return(false);
        }
      if(existing.ticket!=ticket)
         PrintFormat("FLIPDEMON VIRTUAL EXIT: broker ticket refreshed from %I64u to %I64u using stable position identifier=%I64u.",
                     existing.ticket,ticket,positionId);
      initialSl=existing.initialSlPrice;
      riskDistance=existing.originalRiskDistance;
      breakEvenDone=(existing.breakEvenDone || g_posState.breakEvenDone);
      g_posState.originalSlPrice=existing.initialSlPrice;
      g_posState.breakEvenDone=breakEvenDone;
     }
   else
     {
      // Only a just-confirmed fill may seed a new record from the original broker stop.
      // A pre-existing position may already have a trailed/breakeven stop, so its original risk cannot be reconstructed safely from the current broker snapshot.
      bool stopOnLossSide=(dir==AX_DIR_BUY) ? (brokerSl<entry-tickSize*0.5)
                                            : (brokerSl>entry+tickSize*0.5);
      if(!isNewFill || !stopOnLossSide || riskDistance<=tickSize*0.5)
        {
         g_virtualExitReady=false;
         PrintFormat("FLIPDEMON VIRTUAL EXIT: untracked position %I64u has no verified original risk record; broker protection retained, new entries blocked.",ticket);
         return(false);
        }
     }

   g_posState.originalSlPrice=initialSl;
   g_posState.initialSlPrice=brokerSl;
   g_posState.initialTpPrice=brokerTp;
   g_posState.breakEvenDone=breakEvenDone;

   record.ticket=ticket;
   record.positionIdentifier=positionId;
   record.symbol=_Symbol;
   record.dir=dir;
   record.initialSlPrice=initialSl;
   record.emergencySlPrice=brokerSl;
   record.virtualSlPrice=brokerSl;
   record.virtualTpPrice=brokerTp;
   record.originalRiskDistance=riskDistance;
   record.breakEvenDone=breakEvenDone;
   // Preserve lifecycle evidence when the current broker snapshot refreshes
   // ordinary position fields. Never clear an unresolved action lock on restart.
   if(found)
     {
      record.trailingActive=existing.trailingActive;
      record.trailingStopPrice=existing.trailingStopPrice;
      record.partialCloseCount=existing.partialCloseCount;
      record.partialClosedVolume=existing.partialClosedVolume;
      record.partialLastDealTicket=existing.partialLastDealTicket;
      record.actionLocked=existing.actionLocked;
      record.actionCode=existing.actionCode;
      record.actionStartedAt=existing.actionStartedAt;
      record.actionBaselineVolume=existing.actionBaselineVolume;
     }
   else
     {
      record.trailingActive=false;
      record.trailingStopPrice=0.0;
      record.partialCloseCount=0;
      record.partialClosedVolume=0.0;
      record.partialLastDealTicket=0;
      record.actionLocked=false;
      record.actionCode=0;
      record.actionStartedAt=0;
      record.actionBaselineVolume=0.0;
     }
   record.entryTime=(datetime)PositionGetInteger(POSITION_TIME);
    record.entryPrice=entry;
    // Preserve original filled volume across refreshes and scale-outs.
    // Legacy rows lack a trustworthy initial-volume baseline.
    record.entryVolume=(found ? existing.entryVolume : 0.0);
    if(!found && isNewFill)
       record.entryVolume=PositionGetDouble(POSITION_VOLUME);
   record.updatedAt=TimeCurrent();

   if(!g_virtualExitRegistry.Save(record) || !g_virtualExitRegistry.IsPersisting())
     {
      g_virtualExitReady=false;
      PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: state save failed for position %I64u; broker protection retained, new entries blocked.",ticket);
      return(false);
     }
   g_virtualExitReady=true;
   return(true);
  }

// Recover interrupted stop-modification actions only from a complete live
// broker snapshot. The durable emergency SL is the pre-request baseline.
// An unchanged stop proves no broker-side change; a strictly tighter stop is
// adopted only when its action-specific invariants are satisfied.
bool AxRecoverLockedStopAction(const SAxManagedPosition &live,
                               SAxVirtualExitRecord &saved)
  {
   if(!saved.actionLocked || (saved.actionCode!=1 && saved.actionCode!=2) ||
      saved.positionIdentifier!=live.positionIdentifier ||
      saved.ticket==0 || saved.symbol!=live.symbol || saved.dir!=live.direction ||
      saved.emergencySlPrice<=0.0 || !live.hasValidBrokerStop)
      return(false);

   double tickSize=SymbolInfoDouble(live.symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0.0 || !MathIsValidNumber(live.stopLoss) ||
      !MathIsValidNumber(saved.emergencySlPrice))
      return(false);

   bool unchanged=(MathAbs(live.stopLoss-saved.emergencySlPrice)<=tickSize*0.5);
   if(unchanged)
     {
      if(!g_virtualExitRegistry.ResolveAction(live.positionIdentifier,saved.actionCode) ||
         !g_virtualExitRegistry.IsPersisting())
         return(false);
      PrintFormat("FLIPDEMON STOP ACTION RECOVERY: action=%d had no broker-side stop change; stale lock safely resolved for identifier=%I64u.",
                  saved.actionCode,live.positionIdentifier);
      return(true);
     }

   bool tighter=(live.direction==AX_DIR_BUY)
                ?(live.stopLoss>saved.emergencySlPrice+tickSize*0.5)
                :(live.direction==AX_DIR_SELL)
                  ?(live.stopLoss<saved.emergencySlPrice-tickSize*0.5):false;
   if(!tighter) return(false);

   bool stateRecorded=false;
   if(saved.actionCode==1)
     {
      // A break-even action must be confirmed on or beyond entry.
      bool atBreakEven=(live.direction==AX_DIR_BUY)
                       ?(live.stopLoss+tickSize*0.5>=live.openPrice)
                       :(live.direction==AX_DIR_SELL)
                         ?(live.stopLoss-tickSize*0.5<=live.openPrice):false;
      if(!atBreakEven) return(false);
      stateRecorded=g_virtualExitRegistry.RecordBreakEven(live.positionIdentifier,
                                                            live.stopLoss);
     }
   else
     {
      // Trailing is only allowed after the durable break-even milestone.
      if(!saved.breakEvenDone) return(false);
      stateRecorded=g_virtualExitRegistry.RecordTrailingStop(live.positionIdentifier,
                                                              live.stopLoss);
     }

   if(!stateRecorded || !g_virtualExitRegistry.IsPersisting())
      return(false);
   if(!g_virtualExitRegistry.ResolveAction(live.positionIdentifier,saved.actionCode) ||
      !g_virtualExitRegistry.IsPersisting())
      return(false);

   PrintFormat("FLIPDEMON STOP ACTION RECOVERY: broker-confirmed tighter stop adopted for action=%d ticket=%I64u identifier=%I64u stop=%.*f.",
               saved.actionCode,live.ticket,live.positionIdentifier,
               (int)SymbolInfoInteger(live.symbol,SYMBOL_DIGITS),live.stopLoss);
   return(true);
  }

// Reconcile every persisted virtual-exit row against a complete broker snapshot.
// POSITION_IDENTIFIER is authoritative; tickets are refreshed, never used as primary keys.
// Missing state for a live leg is not fabricated from a possibly-trailing broker stop.
bool AxReconcileVirtualExitTickets(const bool removeStaleRecords)
  {
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting())
     {
      g_virtualExitReady=false;
      return(false);
     }

   int liveCount=g_hedgingPositionManager.Count();
   for(int i=0;i<liveCount;i++)
     {
      SAxManagedPosition live;
      if(!g_hedgingPositionManager.GetAt(i,live))
        {
         g_virtualExitReady=false;
         PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: broker snapshot row %d could not be read.",i);
         return(false);
        }

      SAxVirtualExitRecord saved;
      if(!g_virtualExitRegistry.Find(live.positionIdentifier,saved))
        {
         g_virtualExitReady=false;
         PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: live ticket=%I64u identifier=%I64u has no persisted per-position exit state; broker SL/TP retained and new entries blocked.",
                     live.ticket,live.positionIdentifier);
         return(false);
        }

      // Stop modifications are idempotent at the broker level. On restart,
      // compare the exact live stop with the persisted pre-request baseline.
      // Partial-close actions remain under deal-history reconciliation below.
      if(saved.actionLocked && (saved.actionCode==1 || saved.actionCode==2))
        {
         if(!AxRecoverLockedStopAction(live,saved))
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_engineState=AX_ENGINE_PAUSED;
            PrintFormat("FLIPDEMON VIRTUAL EXIT QUARANTINE: stop action=%d cannot be proven from broker state for identifier=%I64u; no retry or lock release.",
                        saved.actionCode,live.positionIdentifier);
            return(false);
           }
         if(!g_virtualExitRegistry.Find(live.positionIdentifier,saved))
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_engineState=AX_ENGINE_PAUSED;
            return(false);
           }
        }
      if(saved.actionLocked)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON VIRTUAL EXIT QUARANTINE: unresolved action=%d started=%s identifier=%I64u; deal-history/manual reconciliation required.",
                     saved.actionCode,TimeToString(saved.actionStartedAt,TIME_DATE|TIME_SECONDS),
                     live.positionIdentifier);
         return(false);
        }

      double tickSize=SymbolInfoDouble(live.symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tickSize<=0.0 || saved.symbol!=live.symbol ||
         saved.dir!=live.direction ||
         (live.hasValidBrokerStop && MathAbs(saved.emergencySlPrice-live.stopLoss)>tickSize*0.5) ||
          (!live.hasValidBrokerStop && (saved.emergencySlPrice<=0.0 || saved.virtualSlPrice<=0.0)) ||
         saved.initialSlPrice<=0.0 || saved.originalRiskDistance<=0.0 ||
         saved.virtualSlPrice<=0.0 || saved.entryTime<=0)
        {
         g_virtualExitReady=false;
         PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: persisted state does not match broker-confirmed stop/identity for ticket=%I64u identifier=%I64u; new entries blocked.",
                     live.ticket,live.positionIdentifier);
         return(false);
        }

      if(saved.ticket!=live.ticket)
        {
         ulong oldTicket=saved.ticket;
         saved.ticket=live.ticket;
         if(live.positionIdentifier==g_positionIdentifier)
            g_posState.ticket=live.ticket;
         if(!g_virtualExitRegistry.Save(saved) || !g_virtualExitRegistry.IsPersisting())
           {
            g_virtualExitReady=false;
            PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: could not persist refreshed ticket %I64u (previous=%I64u identifier=%I64u).",
                        live.ticket,oldTicket,live.positionIdentifier);
            return(false);
           }
         PrintFormat("FLIPDEMON VIRTUAL EXIT: refreshed broker ticket %I64u -> %I64u using stable identifier=%I64u.",
                     oldTicket,live.ticket,live.positionIdentifier);
        }
     }

   // Remove a stale row only after a complete broker snapshot proves its
   // stable identifier is no longer open for this EA and symbol.
   if(removeStaleRecords)
     {
      for(int index=g_virtualExitRegistry.Count()-1;index>=0;index--)
        {
         SAxVirtualExitRecord saved;
         if(!g_virtualExitRegistry.GetAt(index,saved))
           {
            g_virtualExitReady=false;
            PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: registry row %d could not be read.",index);
            return(false);
           }
         SAxManagedPosition live;
         if(!g_hedgingPositionManager.FindByIdentifier(saved.positionIdentifier,live))
           {
            if(saved.actionLocked)
              {
               // A locked row can represent an unjournaled final close. Never
               // erase it merely because the broker position is now absent.
               g_virtualExitReady=false;
               g_hedgingLifecycleLock=true;
               g_engineState=AX_ENGINE_PAUSED;
               PrintFormat("FLIPDEMON VIRTUAL EXIT QUARANTINE: closed/missing position %I64u has unresolved action=%d; preserve state for deal-history recovery.",
                           saved.positionIdentifier,saved.actionCode);
               return(false);
              }
            if(!g_virtualExitRegistry.Remove(saved.positionIdentifier) ||
               !g_virtualExitRegistry.IsPersisting())
              {
               g_virtualExitReady=false;
               PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: stale closed-position row %I64u could not be removed.",
                           saved.positionIdentifier);
               return(false);
              }
            PrintFormat("FLIPDEMON VIRTUAL EXIT: removed stale closed-position state identifier=%I64u.",
                        saved.positionIdentifier);
           }
        }
     }

   g_virtualExitReady=true;
   return(true);
  }

// Reconstruct a completed position whose final close happened while the EA was offline.
// Only broker entry/exit facts are restored. Signal scores, MFE/MAE, AFE state and flip
// generation were not persisted in the old setup registry, so they remain explicitly unknown.
bool AxRecoverFullyClosedPosition(const SAxVirtualExitRecord &saved,
                                  const double exitVolume,const double exitPrice,
                                  const double grossProfit,const double commission,
                                  const double swap,const datetime closeTime,
                                  const ulong journalCursor,const ulong lastExitDeal)
  {
   double tolerance=MathMax(SymbolInfoDouble(saved.symbol,SYMBOL_VOLUME_STEP)*0.5,0.0000001);
   if(saved.positionIdentifier==0 || saved.actionCode!=3 ||
      saved.actionBaselineVolume<=0.0 || exitVolume<=0.0 ||
      exitVolume>saved.actionBaselineVolume+tolerance ||
      exitPrice<=0.0 || lastExitDeal<journalCursor)
      return(false);

   SAxOpenSetupRecord setup;
   bool haveSetup=g_restartRecovery.FindByPositionIdentifier(saved.positionIdentifier,setup);
   if(haveSetup && (setup.symbol!=saved.symbol || setup.dir!=saved.dir))
      return(false);

   if(!HistorySelectByPosition((long)saved.positionIdentifier))
      return(false);
   double entryVolume=0.0,entryValue=0.0;
   ulong firstEntryDeal=0;
   datetime firstEntryTime=0;
   ENUM_AX_DIR entryDirection=AX_DIR_NONE;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 ||
         (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=saved.positionIdentifier)
         continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=saved.symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagicNumber)
         return(false);
      long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_INOUT) return(false);
      if(entry!=DEAL_ENTRY_IN) continue;
      long dealType=HistoryDealGetInteger(deal,DEAL_TYPE);
      ENUM_AX_DIR dealDirection=(dealType==DEAL_TYPE_BUY)?AX_DIR_BUY:
                                (dealType==DEAL_TYPE_SELL)?AX_DIR_SELL:AX_DIR_NONE;
      double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
      double price=HistoryDealGetDouble(deal,DEAL_PRICE);
      datetime dealTime=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      if(dealDirection!=saved.dir || volume<=0.0 || price<=0.0 || dealTime<=0)
         return(false);
      entryVolume+=volume;
      entryValue+=volume*price;
      if(firstEntryDeal==0 || deal<firstEntryDeal)
        {
         firstEntryDeal=deal;
         firstEntryTime=dealTime;
         entryDirection=dealDirection;
        }
     }
   if(firstEntryDeal==0 || entryVolume+0.0000001<saved.actionBaselineVolume ||
      entryValue<=0.0 || entryDirection!=saved.dir)
      return(false);

   SAxTradeRecord rec;
   ZeroMemory(rec);
   rec.setupId=haveSetup ? setup.setupId : "";
   rec.vwapPullbackBullBonus=haveSetup ? setup.vwapPullbackBullBonus : 0.0;
   rec.vwapPullbackBearBonus=haveSetup ? setup.vwapPullbackBearBonus : 0.0;
   rec.overnightBiasBullBonus=haveSetup ? setup.overnightBiasBullBonus : 0.0;
   rec.overnightBiasBearBonus=haveSetup ? setup.overnightBiasBearBonus : 0.0;
   rec.twinContinuationBullBonus=haveSetup ? setup.twinContinuationBullBonus : 0.0;
   rec.twinContinuationBearBonus=haveSetup ? setup.twinContinuationBearBonus : 0.0;
   rec.ticket=saved.ticket;
   rec.positionIdentifier=saved.positionIdentifier;
   rec.dealIdIn=firstEntryDeal;
   rec.dealIdOut=lastExitDeal;
   rec.entryTime=(haveSetup && setup.entryTime>0)?setup.entryTime:firstEntryTime;
   rec.exitTime=(closeTime>0)?closeTime:TimeCurrent();
   rec.direction=saved.dir;
   rec.entryPrice=entryValue/entryVolume;
   rec.exitPrice=exitPrice;
   rec.lots=exitVolume;
   rec.holdSeconds=(int)MathMax(0,(long)(rec.exitTime-rec.entryTime));
   rec.regime=AX_REGIME_UNSAFE; // entry regime was not durably captured; do not fabricate a normal regime.
   rec.entryReason="RESTART_RECOVERED | ENTRY_THESIS_UNAVAILABLE";
   // Broker history is sufficient to prove the close and its financial result,
   // but this recovery path does not yet map every DEAL_REASON to an exit class.
   // Record NONE rather than falsely labelling a manual or external close as SL/TP.
   rec.exitReason=AX_EXIT_NONE;
   rec.grossProfit=grossProfit;
   rec.commission=commission;
   rec.swap=swap;
   rec.netProfit=grossProfit+commission+swap;
   rec.flipSeq=0;
   rec.isPartial=false;
   rec.rMultiple=EMPTY_VALUE;
   double tickSize=SymbolInfoDouble(saved.symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(saved.symbol,SYMBOL_TRADE_TICK_VALUE);
   if(saved.originalRiskDistance>0.0 && tickSize>0.0 && tickValue>0.0 && exitVolume>0.0)
     {
      double originalRiskCurrency=(saved.originalRiskDistance/tickSize)*tickValue*exitVolume;
      if(originalRiskCurrency>0.0)
         rec.rMultiple=rec.netProfit/originalRiskCurrency;
     }

   // The trade journal is the durable source of the final slice's financial result.
   // Risk state is in-memory, so replay it on every startup recovery, including the
   // crash window where the journal append succeeded but risk registration did not.
   // Read the exact durable row to avoid substituting whole-position totals for the
   // final exit slice when earlier partial closes were already journalled.
   bool alreadyJournaled=(g_autopsy.LastAccountedDealTicket(saved.positionIdentifier)>=lastExitDeal);
   if(!alreadyJournaled)
     {
      g_autopsy.RecordTrade(rec);
      if(g_autopsy.LastAccountedDealTicket(saved.positionIdentifier)<lastExitDeal)
        {
         g_recoveryReady=false;
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON FULL-CLOSE RECOVERY: journal write not confirmed for identifier=%I64u; both durable recovery records retained.",
                     saved.positionIdentifier);
         return(false);
        }
     }

   ulong durableDealTicket=0;
   bool durablePartial=false;
   double durableLots=0.0,durableNetProfit=0.0;
   if(!g_autopsy.LastAccountedRecord(saved.positionIdentifier,durableDealTicket,
                                      durablePartial,durableLots,durableNetProfit) ||
      durableDealTicket!=lastExitDeal || durablePartial || durableLots<=0.0)
     {
      g_recoveryReady=false;
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON FULL-CLOSE RECOVERY: final journal row could not be verified for identifier=%I64u deal=%I64u.",
                  saved.positionIdentifier,lastExitDeal);
      return(false);
     }

   // Restore the complete campaign outcome, including previously journalled
   // partial slices and entry-side charges. The final journal row alone is only
   // the last slice and is not the campaign's total result.
   double campaignNetProfit=0.0;
   ulong campaignLastExitDeal=0;
   if(!AxGetCampaignNetProfit(saved.positionIdentifier,saved.symbol,InpMagicNumber,
                              campaignNetProfit,campaignLastExitDeal) ||
      campaignLastExitDeal!=lastExitDeal)
     {
      g_recoveryReady=false;
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON FULL-CLOSE RECOVERY: complete campaign result unavailable for identifier=%I64u.",
                  saved.positionIdentifier);
      return(false);
     }
   // This function runs during startup reconciliation. Replaying the complete
   // broker-confirmed result restores the risk streak after an interrupted close.
   g_risk.RegisterTradeClosed(campaignNetProfit);

   if(g_restartRecovery.FindByPositionIdentifier(saved.positionIdentifier,setup) &&
      (!g_restartRecovery.RemoveOpenSetupByPositionIdentifier(saved.positionIdentifier) ||
       !g_restartRecovery.IsPersisting()))
     {
      g_recoveryReady=false;
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      return(false);
     }
   if(!g_virtualExitRegistry.Remove(saved.positionIdentifier) ||
      !g_virtualExitRegistry.IsPersisting())
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      return(false);
     }
   PrintFormat("FLIPDEMON FULL-CLOSE RECOVERY: identifier=%I64u journal boundary=%I64u final deal=%I64u recovered volume=%.8f net=%.2f; stale lifecycle records removed.",
               saved.positionIdentifier,journalCursor,lastExitDeal,exitVolume,rec.netProfit);
   return(true);
  }

// Recover a locked partial close for one hedging leg without touching the
// single-position trade journal or global g_posState.
bool AxRecoverHedgingPartialCloseAction(const SAxVirtualExitRecord &saved)
  {
   if(!g_hedgingPartialLedgerReady || !g_hedgingPartialCloseLedger.IsPersisting() ||
      !g_virtualExitRegistry.IsPersisting() || !saved.actionLocked ||
      saved.actionCode!=3 || saved.positionIdentifier==0 ||
      saved.actionBaselineVolume<=0.0 || saved.entryTime<=0 ||
      saved.entryPrice<=0.0 || saved.entryVolume<=0.0 ||
      saved.symbol!=_Symbol || saved.partialLastDealTicket==0 && saved.partialCloseCount>0)
      return(false);

   SAxManagedPosition live;
   if(!g_hedgingPositionManager.FindByIdentifier(saved.positionIdentifier,live) ||
      live.positionIdentifier!=saved.positionIdentifier || live.ticket==0 ||
      live.symbol!=saved.symbol || live.magic!=InpMagicNumber ||
      live.direction!=saved.dir || !PositionSelectByTicket(live.ticket) ||
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=saved.positionIdentifier ||
      (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
      return(false);

   const double liveVolume=PositionGetDouble(POSITION_VOLUME);
   const double expectedReduction=saved.actionBaselineVolume-liveVolume;
   const double step=SymbolInfoDouble(saved.symbol,SYMBOL_VOLUME_STEP);
   const double tolerance=MathMax(step*0.5,0.0000001);
   if(step<=0.0 || !MathIsValidNumber(liveVolume) || liveVolume<=0.0 ||
      expectedReduction<=tolerance)
      return(false);

   const ulong ledgerHighWater=g_hedgingPartialCloseLedger.LastDealTicket(saved.positionIdentifier);
   if(ledgerHighWater<saved.partialLastDealTicket)
      return(false);

   // Recover both crash windows: ledger durable before registry cursor, and
   // registry cursor durable before action-lock release. The exact final deal,
   // action timestamp, per-leg facts and live volume reduction must all agree.
   if(ledgerHighWater>0 && ledgerHighWater>=saved.partialLastDealTicket)
     {
      SAxPartialCloseLedgerRecord accounted;
      if(!g_hedgingPartialCloseLedger.Find(saved.positionIdentifier,
                                            ledgerHighWater,accounted) ||
         accounted.symbol!=saved.symbol || accounted.magic!=InpMagicNumber ||
         accounted.direction!=saved.dir ||
         MathAbs(accounted.entryPrice-saved.entryPrice)>0.00000001 ||
         MathAbs(accounted.entryVolume-saved.entryVolume)>0.00000001 ||
         MathAbs(accounted.closedVolume-expectedReduction)>tolerance ||
         saved.partialClosedVolume+accounted.closedVolume>=saved.entryVolume-tolerance ||
         accounted.closeTime<saved.actionStartedAt ||
         !HistorySelectByPosition((long)saved.positionIdentifier))
         return(false);

      bool finalDealVerified=false;
      for(int d=0;d<HistoryDealsTotal();d++)
        {
         ulong deal=HistoryDealGetTicket(d);
         if(deal!=ledgerHighWater) continue;
         long closeType=(saved.dir==AX_DIR_BUY)?DEAL_TYPE_SELL:DEAL_TYPE_BUY;
         long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
         datetime dealTime=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
         if((ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)==saved.positionIdentifier &&
            HistoryDealGetString(deal,DEAL_SYMBOL)==saved.symbol &&
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)==InpMagicNumber &&
            HistoryDealGetInteger(deal,DEAL_TYPE)==closeType &&
            (entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY) &&
            dealTime==accounted.closeTime)
            finalDealVerified=true;
         break;
        }
      if(!finalDealVerified)
         return(false);

      // If the ledger write won the crash race, advance the durable virtual
      // cursor now. If both were committed, this is an idempotent no-op.
      if(saved.partialLastDealTicket<ledgerHighWater &&
         (!g_virtualExitRegistry.RecordPartialClose(saved.positionIdentifier,
                                                     accounted.closedVolume,ledgerHighWater) ||
          !g_virtualExitRegistry.IsPersisting()))
         return(false);
      if(!g_virtualExitRegistry.ResolveAction(saved.positionIdentifier,3) ||
         !g_virtualExitRegistry.IsPersisting())
         return(false);
      PrintFormat("FLIPDEMON HEDGING PARTIAL RECOVERY: identifier=%I64u verified durable slice %.8f at deal=%I64u; action lock cleared.",
                  saved.positionIdentifier,accounted.closedVolume,ledgerHighWater);
      return(true);
     }

   double closePrice=0.0,grossProfit=0.0,commission=0.0,swap=0.0,closedVolume=0.0;
   datetime closeTime=0;
   ulong lastDeal=saved.partialLastDealTicket;
   if(!AxFetchCloseFinancialsByIdentifier(saved.positionIdentifier,saved.symbol,
                                           InpMagicNumber,saved.dir,
                                           saved.partialLastDealTicket,
                                           closePrice,grossProfit,commission,swap,
                                           closeTime,lastDeal,closedVolume) ||
      lastDeal<=saved.partialLastDealTicket || closeTime<=0 ||
      MathAbs(expectedReduction-closedVolume)>tolerance ||
      saved.partialClosedVolume+closedVolume>=saved.entryVolume-tolerance)
      return(false);

   // The ledger write is idempotent by (position identifier, final deal ticket).
   // Only after it is durable may the virtual-exit cursor advance and unlock.
   if(ledgerHighWater>lastDeal)
      return(false);
   if(!AxRecordHedgingPartialCloseLedger(saved,closePrice,grossProfit,commission,swap,
                                          closeTime,lastDeal,closedVolume))
      return(false);
   if(!g_virtualExitRegistry.RecordPartialClose(saved.positionIdentifier,closedVolume,lastDeal) ||
      !g_virtualExitRegistry.IsPersisting())
      return(false);
   if(!g_virtualExitRegistry.ResolveAction(saved.positionIdentifier,3) ||
      !g_virtualExitRegistry.IsPersisting())
      return(false);

   PrintFormat("FLIPDEMON HEDGING PARTIAL RECOVERY: identifier=%I64u ticket=%I64u closed=%.8f remaining=%.8f deal=%I64u; per-leg ledger durable.",
               saved.positionIdentifier,live.ticket,closedVolume,liveVolume,lastDeal);
   return(true);
  }

// Rebuild the immutable final-liquidation record from the complete position
// history. This deliberately aggregates prior scale-outs and the final exit.
bool AxBuildHedgingFullCloseRecord(const SAxVirtualExitRecord &saved,
                                   SAxFullCloseLedgerRecord &recordOut)
  {
   if(!g_hedgingFullCloseLedgerReady || !g_hedgingFullCloseLedger.IsPersisting() ||
      !g_hedgingPartialLedgerReady || !g_hedgingPartialCloseLedger.IsPersisting() ||
      saved.positionIdentifier==0 || saved.symbol=="" || saved.entryTime<=0 ||
      saved.entryPrice<=0.0 || saved.entryVolume<=0.0 ||
      (saved.dir!=AX_DIR_BUY && saved.dir!=AX_DIR_SELL) ||
      !g_hedgingPositionManager.IsComplete() ||
      !HistorySelectByPosition((long)saved.positionIdentifier))
      return(false);

   SAxManagedPosition live;
   if(g_hedgingPositionManager.FindByIdentifier(saved.positionIdentifier,live))
      return(false); // never journal a position that still has live broker volume

   const long entryTypeExpected=(saved.dir==AX_DIR_BUY)?DEAL_TYPE_BUY:DEAL_TYPE_SELL;
   const long exitTypeExpected=(saved.dir==AX_DIR_BUY)?DEAL_TYPE_SELL:DEAL_TYPE_BUY;
   double entryVolume=0.0,entryValue=0.0,exitVolume=0.0,exitValue=0.0;
   double gross=0.0,commission=0.0,swap=0.0,fees=0.0;
   datetime lastExitTime=0;
   ulong firstEntryDeal=0,lastExitDeal=0;
   int exitCount=0;
   bool historyValid=true;
   for(int i=0;i<HistoryDealsTotal();i++)
     {
      const ulong deal=HistoryDealGetTicket(i);
      if(deal==0 ||
         (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=saved.positionIdentifier ||
         HistoryDealGetString(deal,DEAL_SYMBOL)!=saved.symbol ||
         (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagicNumber)
        {
         historyValid=false;
         break;
        }
      const long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      const long type=HistoryDealGetInteger(deal,DEAL_TYPE);
      const double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
      const double price=HistoryDealGetDouble(deal,DEAL_PRICE);
      const double profit=HistoryDealGetDouble(deal,DEAL_PROFIT);
      const double dealCommission=HistoryDealGetDouble(deal,DEAL_COMMISSION);
      const double dealSwap=HistoryDealGetDouble(deal,DEAL_SWAP);
      const double dealFees=HistoryDealGetDouble(deal,DEAL_FEE);
      const datetime dealTime=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
      if(entry==DEAL_ENTRY_INOUT || !MathIsValidNumber(volume) ||
         volume<=0.0 || !MathIsValidNumber(price) || price<=0.0 ||
         !MathIsValidNumber(profit) || !MathIsValidNumber(dealCommission) ||
         !MathIsValidNumber(dealSwap) || !MathIsValidNumber(dealFees) || dealTime<=0)
        {
         historyValid=false;
         break;
        }
      gross+=profit;
      commission+=dealCommission;
      swap+=dealSwap;
      fees+=dealFees;
      if(entry==DEAL_ENTRY_IN)
        {
         if(type!=entryTypeExpected)
           {
            historyValid=false;
            break;
           }
         entryVolume+=volume;
         entryValue+=volume*price;
         if(firstEntryDeal==0 || deal<firstEntryDeal) firstEntryDeal=deal;
        }
      else if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
        {
         if(type!=exitTypeExpected)
           {
            historyValid=false;
            break;
           }
         exitVolume+=volume;
         exitValue+=volume*price;
         exitCount++;
         if(deal>lastExitDeal)
           {
            lastExitDeal=deal;
            lastExitTime=dealTime;
           }
        }
      else
        {
         historyValid=false;
         break;
        }
     }
   const double volumeStep=SymbolInfoDouble(saved.symbol,SYMBOL_VOLUME_STEP);
   const double volumeTolerance=MathMax(volumeStep*0.51,0.0000001);
   const double tickSize=SymbolInfoDouble(saved.symbol,SYMBOL_TRADE_TICK_SIZE);
   const double priceTolerance=MathMax(tickSize*0.51,0.00000001);
   if(!historyValid || firstEntryDeal==0 || lastExitDeal==0 || exitCount<=0 ||
      entryVolume<=0.0 || exitVolume<=0.0 || exitValue<=0.0 ||
      MathAbs(entryVolume-saved.entryVolume)>volumeTolerance ||
      MathAbs(entryValue/entryVolume-saved.entryPrice)>priceTolerance ||
      MathAbs(exitVolume-saved.entryVolume)>volumeTolerance ||
      lastExitTime<=0 || (saved.actionStartedAt>0 && lastExitTime<saved.actionStartedAt))
      return(false);

   // A final close may only be journalled if the already committed partial
   // slice agrees with broker history and the durable registry cursor.
   if(saved.partialClosedVolume>volumeTolerance)
     {
      SAxPartialCloseLedgerRecord partial;
      if(saved.partialCloseCount!=1 || saved.partialLastDealTicket==0 ||
         !g_hedgingPartialCloseLedger.Find(saved.positionIdentifier,
                                            saved.partialLastDealTicket,partial) ||
         MathAbs(partial.closedVolume-saved.partialClosedVolume)>volumeTolerance ||
         partial.symbol!=saved.symbol || partial.magic!=InpMagicNumber ||
         partial.direction!=saved.dir)
         return(false);
     }
   else if(saved.partialCloseCount!=0 || saved.partialLastDealTicket!=0)
      return(false);

   ZeroMemory(recordOut);
   recordOut.positionIdentifier=saved.positionIdentifier;
   recordOut.finalDealTicket=lastExitDeal;
   recordOut.lastExitDealTicket=lastExitDeal;
   recordOut.symbol=saved.symbol;
   recordOut.magic=InpMagicNumber;
   recordOut.direction=saved.dir;
   recordOut.entryTime=saved.entryTime;
   recordOut.entryPrice=entryValue/entryVolume;
   recordOut.entryVolume=entryVolume;
   recordOut.closeTime=lastExitTime;
   recordOut.weightedClosePrice=exitValue/exitVolume;
   recordOut.totalClosedVolume=exitVolume;
   recordOut.exitDealCount=exitCount;
   recordOut.grossProfit=gross;
   recordOut.commission=commission;
   recordOut.swap=swap;
   recordOut.fees=fees;
   recordOut.netProfit=gross+commission+swap+fees;
   recordOut.partialClosedVolume=saved.partialClosedVolume;
   return(MathIsValidNumber(recordOut.netProfit) &&
          recordOut.weightedClosePrice>0.0);
  }

// The final journal is written before the virtual-exit row is removed. Replaying
// after a crash is idempotent because the ledger accepts only an identical row.
bool AxFinalizeHedgingFullClose(const SAxVirtualExitRecord &saved)
  {
   SAxFullCloseLedgerRecord finalRecord;
   if(!AxBuildHedgingFullCloseRecord(saved,finalRecord) ||
      !g_hedgingFullCloseLedger.Record(finalRecord) ||
      !g_hedgingFullCloseLedger.IsPersisting())
      return(false);
   SAxFullCloseLedgerRecord verified;
   if(!g_hedgingFullCloseLedger.Find(saved.positionIdentifier,verified) ||
      verified.finalDealTicket!=finalRecord.finalDealTicket ||
      MathAbs(verified.totalClosedVolume-finalRecord.totalClosedVolume)>0.0000001 ||
      MathAbs(verified.netProfit-finalRecord.netProfit)>0.0000001)
      return(false);
   // Keep the virtual-exit action lock until both durable lifecycle ledgers
   // have committed. A failed state removal must remain recoverable on restart.
   if(!g_positionStateRegistryReady ||
      !g_positionStateRegistry.Remove(saved.positionIdentifier) ||
      !g_positionStateRegistry.IsPersisting())
      return(false);
   if(!g_virtualExitRegistry.Remove(saved.positionIdentifier) ||
      !g_virtualExitRegistry.IsPersisting())
      return(false);
   PrintFormat("FLIPDEMON HEDGING FULL CLOSE: identifier=%I64u final deal=%I64u volume=%.8f net=%.2f; immutable liquidation journal committed.",
               saved.positionIdentifier,finalRecord.finalDealTicket,
               finalRecord.totalClosedVolume,finalRecord.netProfit);
   return(true);
  }

// Restart/tick recovery for actionCode=4. It never submits another close request.
// If any live volume remains after an uncertain close, the action stays quarantined.
bool AxRecoverLockedHedgingFullCloseActions(void)
  {
   if(!g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting() ||
      !g_hedgingPositionManager.IsComplete() || !g_hedgingFullCloseLedgerReady ||
      !g_hedgingFullCloseLedger.IsPersisting())
      return(false);

   // Never infer completion from a durable action lock or an old request result.
   // Refresh broker truth before touching any actionCode=4 record.
   if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber))
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_recoveryReady=false;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON HEDGING FULL-CLOSE RECOVERY: broker snapshot incomplete; locked actions preserved.");
      return(false);
     }

   for(int i=0;i<g_virtualExitRegistry.Count();i++)
     {
      SAxVirtualExitRecord saved;
      if(!g_virtualExitRegistry.GetAt(i,saved)) return(false);
      if(!saved.actionLocked || saved.actionCode!=4) continue;

      // A still-live identifier means the close is not proven complete. This
      // includes unchanged volume, partial execution, and delayed broker fills.
      // Keep the original action lock and do not submit another close request.
      SAxManagedPosition stillLive;
      if(saved.positionIdentifier==0 || saved.actionBaselineVolume<=0.0 ||
         g_hedgingPositionManager.FindByIdentifier(saved.positionIdentifier,stillLive))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING FULL-CLOSE RECOVERY QUARANTINE: identifier=%I64u still has live broker exposure or invalid baseline; action lock retained and no retry issued.",
                     saved.positionIdentifier);
         return(false);
        }

      // Broker absence is necessary but not sufficient. AxBuildHedgingFullCloseRecord
      // independently requires complete, correctly attributed exit-deal volume.
      if(!AxFinalizeHedgingFullClose(saved))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING FULL-CLOSE RECOVERY QUARANTINE: identifier=%I64u has no live position but complete deal-history finalization is unavailable; action lock retained.",
                     saved.positionIdentifier);
         return(false);
        }
      // Finalization removes this registry row. Revisit the same index because
      // the next locked record shifts into its place.
      i--;
     }
   return(true);
  }

bool AxRecoverLockedPartialCloseActions(void)
  {
   if(!g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting() ||
      !g_hedgingPositionManager.IsComplete())
      return(false);

   // Account mode, not the current leg count, selects the recovery ledger.
   // A hedging account may have only one surviving leg after other positions close.
   // Never route any hedging-account partial close through the legacy single-trade journal.
   long marginMode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   bool hedgingAccount=(marginMode==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(hedgingAccount)
     {
      for(int i=0;i<g_virtualExitRegistry.Count();i++)
        {
         SAxVirtualExitRecord hedged;
         if(!g_virtualExitRegistry.GetAt(i,hedged)) return(false);
         if(!hedged.actionLocked || hedged.actionCode!=3) continue;
         if(!AxRecoverHedgingPartialCloseAction(hedged))
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_recoveryReady=false;
            g_engineState=AX_ENGINE_PAUSED;
            PrintFormat("FLIPDEMON HEDGING PARTIAL RECOVERY QUARANTINE: identifier=%I64u remains locked; no retry or journal mutation.",
                        hedged.positionIdentifier);
            return(false);
           }
        }
      return(true);
     }

   for(int i=0;i<g_virtualExitRegistry.Count();i++)
     {
      SAxVirtualExitRecord saved;
      if(!g_virtualExitRegistry.GetAt(i,saved)) return(false);
      if(!saved.actionLocked || saved.actionCode!=3) continue;
      if(saved.actionBaselineVolume<=0.0 || saved.positionIdentifier==0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: legacy action lock for identifier=%I64u has no baseline volume.",
                     saved.positionIdentifier);
         return(false);
        }

      ulong journalCursor=saved.partialLastDealTicket;
      bool journalRowPartial=false;
      double journalRowLots=0.0,journalRowNetProfit=0.0;
      bool journalRowFound=g_autopsy.LastAccountedRecord(saved.positionIdentifier,
                                                          journalCursor,journalRowPartial,
                                                          journalRowLots,journalRowNetProfit);
      ulong journalHighWater=g_autopsy.LastAccountedDealTicket(saved.positionIdentifier);
      if(saved.partialLastDealTicket>journalHighWater ||
         (journalRowFound && (journalCursor<saved.partialLastDealTicket ||
                              !MathIsValidNumber(journalRowNetProfit))))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: registry deal cursor %I64u is ahead of durable journal cursor %I64u for identifier=%I64u.",
                     saved.partialLastDealTicket,journalHighWater,saved.positionIdentifier);
         return(false);
        }
      if(!journalRowFound)
         journalCursor=saved.partialLastDealTicket;

      if(!HistorySelectByPosition((long)saved.positionIdentifier))
         return(false);
      double historyExitVolume=0.0,journalExitVolume=0.0,unaccountedExitVolume=0.0;
      double allWeightedClose=0.0,allGross=0.0,allCommission=0.0,allSwap=0.0;
      double pendingWeightedClose=0.0,pendingGross=0.0,pendingCommission=0.0,pendingSwap=0.0;
      datetime allCloseTime=0,pendingCloseTime=0;
      ulong lastExitDeal=saved.partialLastDealTicket;
      ulong lastJournalExitDeal=saved.partialLastDealTicket;
      ulong lastUnaccountedExitDeal=journalCursor;
      bool historyValid=true;
      for(int d=0;d<HistoryDealsTotal();d++)
        {
         ulong deal=HistoryDealGetTicket(d);
         if(deal==0 || deal<=saved.partialLastDealTicket) continue;
         if((ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=saved.positionIdentifier ||
            HistoryDealGetString(deal,DEAL_SYMBOL)!=saved.symbol ||
            (ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagicNumber)
           {
            historyValid=false;
            break;
           }
         long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
         if(entry==DEAL_ENTRY_INOUT)
           {
            historyValid=false;
            break;
           }
         if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;
         double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
         double price=HistoryDealGetDouble(deal,DEAL_PRICE);
         if(!MathIsValidNumber(volume) || volume<=0.0 ||
            !MathIsValidNumber(price) || price<=0.0)
           {
            historyValid=false;
            break;
           }
         double profit=HistoryDealGetDouble(deal,DEAL_PROFIT);
         double dealCommission=HistoryDealGetDouble(deal,DEAL_COMMISSION);
         double dealSwap=HistoryDealGetDouble(deal,DEAL_SWAP);
         datetime dealTime=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);
         historyExitVolume+=volume;
         allWeightedClose+=price*volume;
         allGross+=profit;
         allCommission+=dealCommission;
         allSwap+=dealSwap;
         if(deal>lastExitDeal)
           {
            lastExitDeal=deal;
            allCloseTime=dealTime;
           }
         if(deal<=journalCursor)
           {
            journalExitVolume+=volume;
            if(deal>lastJournalExitDeal) lastJournalExitDeal=deal;
           }
         else
           {
            unaccountedExitVolume+=volume;
            pendingWeightedClose+=price*volume;
            pendingGross+=profit;
            pendingCommission+=dealCommission;
            pendingSwap+=dealSwap;
            if(deal>lastUnaccountedExitDeal)
              {
               lastUnaccountedExitDeal=deal;
               pendingCloseTime=dealTime;
              }
           }
        }
      if(!historyValid)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: invalid, foreign-magic or reversal deal history for identifier=%I64u.",
                     saved.positionIdentifier);
         return(false);
        }

      bool journalAdvanced=(journalCursor>saved.partialLastDealTicket);
      if(journalAdvanced &&
         (!journalRowFound || lastJournalExitDeal!=journalCursor || journalExitVolume<=0.0))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: journal cursor %I64u does not match exact exit-deal history for identifier=%I64u.",
                     journalCursor,saved.positionIdentifier);
         return(false);
        }

      SAxManagedPosition live;
      bool positionStillOpen=g_hedgingPositionManager.FindByIdentifier(saved.positionIdentifier,live);
      double step=SymbolInfoDouble(saved.symbol,SYMBOL_VOLUME_STEP);
      double tolerance=MathMax(step*0.5,0.0000001);
      if(step<=0.0) return(false);

      if(!positionStillOpen)
        {
         if(MathAbs(historyExitVolume-saved.actionBaselineVolume)>tolerance ||
            historyExitVolume<=0.0 || allWeightedClose<=0.0)
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_recoveryReady=false;
            g_engineState=AX_ENGINE_PAUSED;
            PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: closed identifier=%I64u exit volume %.8f does not reconcile to action baseline %.8f.",
                        saved.positionIdentifier,historyExitVolume,saved.actionBaselineVolume);
            return(false);
           }

         // A durable non-partial row at the final exit ticket means the close
         // was journalled before the crash. Re-run cleanup only, never append it again.
         if(journalAdvanced && !journalRowPartial)
           {
            if(journalCursor!=lastExitDeal)
               return(false);
            if(!AxRecoverFullyClosedPosition(saved,historyExitVolume,
                                             allWeightedClose/historyExitVolume,
                                             allGross,allCommission,allSwap,allCloseTime,
                                             journalCursor,lastExitDeal))
               return(false);
            continue;
           }

         double expectedFinalVolume=saved.actionBaselineVolume-journalExitVolume;
         if(journalAdvanced && !journalRowPartial)
            return(false);
         if(MathAbs(unaccountedExitVolume-expectedFinalVolume)>tolerance ||
            unaccountedExitVolume<=0.0 || pendingWeightedClose<=0.0 ||
            lastUnaccountedExitDeal<=journalCursor)
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_recoveryReady=false;
            g_engineState=AX_ENGINE_PAUSED;
            PrintFormat("FLIPDEMON FULL-CLOSE RECOVERY QUARANTINE: identifier=%I64u remaining expected=%.8f unaccounted exit volume=%.8f journal cursor=%I64u.",
                        saved.positionIdentifier,expectedFinalVolume,
                        unaccountedExitVolume,journalCursor);
            return(false);
           }
         if(!AxRecoverFullyClosedPosition(saved,unaccountedExitVolume,
                                          pendingWeightedClose/unaccountedExitVolume,
                                          pendingGross,pendingCommission,pendingSwap,
                                          pendingCloseTime,journalCursor,lastUnaccountedExitDeal))
            return(false);
         continue;
        }

      if(live.symbol!=saved.symbol || live.magic!=InpMagicNumber ||
         live.positionIdentifier!=saved.positionIdentifier ||
         !PositionSelectByTicket(live.ticket))
         return(false);
      double currentVolume=PositionGetDouble(POSITION_VOLUME);
      double expectedReduction=saved.actionBaselineVolume-currentVolume;
      if(expectedReduction<=tolerance ||
         MathAbs(expectedReduction-historyExitVolume)>tolerance)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: identifier=%I64u baseline=%.8f live=%.8f reduction=%.8f dealVolume=%.8f; no journal mutation.",
                     saved.positionIdentifier,saved.actionBaselineVolume,currentVolume,
                     expectedReduction,historyExitVolume);
         return(false);
        }
      if(journalAdvanced && !journalRowPartial)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: full-close journal row exists while position %I64u remains open.",
                     saved.positionIdentifier);
         return(false);
        }
      if(!g_posState.active || g_positionIdentifier!=saved.positionIdentifier)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON PARTIAL RECOVERY QUARANTINE: broker volume reconciles for identifier=%I64u, but restored campaign state is unavailable.",
                     saved.positionIdentifier);
         return(false);
        }

      if(journalAdvanced)
        {
         if(!g_virtualExitRegistry.RecordPartialClose(saved.positionIdentifier,
                                                       journalExitVolume,journalCursor) ||
            !g_virtualExitRegistry.IsPersisting())
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_engineState=AX_ENGINE_PAUSED;
            return(false);
           }
        }
      g_posState.lots=saved.actionBaselineVolume-journalExitVolume;
      g_posState.lastAccountedDealTicket=journalCursor;
      if(journalExitVolume>tolerance)
         g_posState.partialTaken=true;

      if(unaccountedExitVolume>tolerance)
        {
         double closePrice=0.0,grossProfit=0.0,commission=0.0,swap=0.0,closedVolume=0.0;
         datetime closeTime=0;
         ulong lastDeal=journalCursor;
         if(!AxFetchCloseFinancials(live.ticket,journalCursor,
                                    closePrice,grossProfit,commission,swap,closeTime,lastDeal,closedVolume) ||
            MathAbs(closedVolume-unaccountedExitVolume)>tolerance)
            return(false);
         if(!AxCommitPartialClose(unaccountedExitVolume,closePrice,grossProfit,commission,
                                  swap,closeTime,lastDeal))
            return(false);
         PrintFormat("FLIPDEMON PARTIAL RECOVERY: identifier=%I64u reconciled new partial volume=%.8f remaining=%.8f lastDeal=%I64u.",
                     saved.positionIdentifier,unaccountedExitVolume,currentVolume,lastDeal);
        }
      else
        {
         if(!g_virtualExitRegistry.ResolveAction(saved.positionIdentifier,3) ||
            !g_virtualExitRegistry.IsPersisting())
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_engineState=AX_ENGINE_PAUSED;
            return(false);
           }
         PrintFormat("FLIPDEMON PARTIAL RECOVERY: identifier=%I64u recovered journal-first partial volume=%.8f remaining=%.8f; action lock cleared.",
                     saved.positionIdentifier,journalExitVolume,currentVolume);
        }
     }
   return(true);
  }

bool AxReconcilePyramidCampaignTickets(const bool removeStaleRecords)
  {
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_pyramidCampaignRegistry.IsPersisting())
     {
      g_pyramidReady=false;
      return(false);
     }

   int liveCount=g_hedgingPositionManager.Count();
   for(int i=0;i<liveCount;i++)
     {
      SAxManagedPosition live;
      if(!g_hedgingPositionManager.GetAt(i,live))
        {
         g_pyramidReady=false;
         PrintFormat("FLIPDEMON PYRAMID ERROR: broker snapshot row %d could not be read.",i);
         return(false);
        }

      SAxPyramidCampaignRecord campaign;
      if(!g_pyramidCampaignRegistry.Find(live.positionIdentifier,campaign))
        {
         bool recovered=false;
         if(!g_pyramidCampaignRegistry.ReconcileLivePosition(live.ticket,recovered) ||
            !recovered ||
            !g_pyramidCampaignRegistry.Find(live.positionIdentifier,campaign))
           {
            g_pyramidReady=false;
            PrintFormat("FLIPDEMON PYRAMID ERROR: no campaign record for live ticket=%I64u identifier=%I64u and broker deal-history reconstruction failed; scale-ins blocked.",
                        live.ticket,live.positionIdentifier);
            return(false);
           }
         PrintFormat("FLIPDEMON PYRAMID: reconstructed missing campaign from broker deal history, ticket=%I64u identifier=%I64u tiers=%d.",
                     live.ticket,live.positionIdentifier,campaign.tierCount);
        }

      if(!campaign.active || campaign.positionIdentifier!=live.positionIdentifier ||
         campaign.symbol!=live.symbol || campaign.dir!=live.direction ||
         campaign.tierCount<1 ||
         campaign.lastTierDealTicket==0 || campaign.lastTierFillPrice<=0.0 ||
         campaign.lastTierFilledLots<=0.0 || campaign.campaignStartTime<=0)
        {
         g_pyramidReady=false;
         PrintFormat("FLIPDEMON PYRAMID ERROR: campaign identity or tier state conflicts with broker ticket=%I64u identifier=%I64u; scale-ins blocked.",
                     live.ticket,live.positionIdentifier);
         return(false);
        }

      if(campaign.ticket!=live.ticket)
        {
         ulong previousTicket=campaign.ticket;
         campaign.ticket=live.ticket;
         if(!g_pyramidCampaignRegistry.Save(campaign) ||
            !g_pyramidCampaignRegistry.IsPersisting())
           {
            g_pyramidReady=false;
            PrintFormat("FLIPDEMON PYRAMID ERROR: could not persist refreshed broker ticket=%I64u (previous=%I64u identifier=%I64u).",
                        live.ticket,previousTicket,live.positionIdentifier);
            return(false);
           }
         PrintFormat("FLIPDEMON PYRAMID: refreshed broker ticket %I64u -> %I64u using stable identifier=%I64u.",
                     previousTicket,live.ticket,live.positionIdentifier);
        }
     }

   // Stale campaign rows are removed only after a complete position snapshot.
   if(removeStaleRecords)
     {
      for(int index=g_pyramidCampaignRegistry.Count()-1;index>=0;index--)
        {
         SAxPyramidCampaignRecord campaign;
         if(!g_pyramidCampaignRegistry.GetAt(index,campaign))
           {
            g_pyramidReady=false;
            PrintFormat("FLIPDEMON PYRAMID ERROR: registry row %d could not be read.",index);
            return(false);
           }
         SAxManagedPosition live;
         if(!g_hedgingPositionManager.FindByIdentifier(campaign.positionIdentifier,live))
           {
            if(!g_pyramidCampaignRegistry.Remove(campaign.positionIdentifier) ||
               !g_pyramidCampaignRegistry.IsPersisting())
              {
               g_pyramidReady=false;
               PrintFormat("FLIPDEMON PYRAMID ERROR: stale campaign for closed identifier=%I64u could not be removed.",
                           campaign.positionIdentifier);
               return(false);
              }
            PrintFormat("FLIPDEMON PYRAMID: removed stale closed-position campaign identifier=%I64u.",
                        campaign.positionIdentifier);
           }
        }
     }

   g_pyramidReady=true;
   return(true);
  }

void AxInitPositionState(const ulong ticket,const ENUM_AX_DIR dir,const double lots,const double fillPrice,
                          const double slPrice,const double tpPrice,const SAxScore &score,
                          const string entryReason,const int flipSeq,const double intendedPrice)
  {
   g_posState.ticket=ticket;
   g_positionIdentifier=0;
   // PositionSelect(symbol) is ambiguous on hedging accounts. Select the exact
   // broker-confirmed ticket, then verify symbol and magic before accepting its ID.
   if(PositionSelectByTicket(ticket) &&
      (ulong)PositionGetInteger(POSITION_TICKET)==ticket &&
      PositionGetString(POSITION_SYMBOL)==_Symbol &&
      (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
      g_positionIdentifier=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
   g_posState.entryTime          = TimeCurrent();
   g_posState.entryPrice         = fillPrice;
   g_posState.dir                = dir;
   g_posState.lots               = lots;
   g_posState.initialSlPrice     = slPrice;
   g_posState.initialTpPrice     = tpPrice;
   g_posState.originalSlPrice    = slPrice;
   g_posState.breakEvenDone      = false;
   g_posState.bestFavorablePrice = fillPrice;
   g_posState.mfeCurrency        = 0;
   g_posState.maeCurrency        = 0;
   g_posState.entryBuyScore      = score.buyScore;
   g_posState.entrySellScore     = score.sellScore;
   g_posState.entryConfidence    = score.confidence;
   g_posState.vwapPullbackBullBonus=score.vwapPullbackBullBonus;
   g_posState.vwapPullbackBearBonus=score.vwapPullbackBearBonus;
   g_posState.overnightBiasBullBonus=score.overnightBiasBullBonus;
   g_posState.overnightBiasBearBonus=score.overnightBiasBearBonus;
   g_posState.twinContinuationBullBonus=score.twinContinuationBullBonus;
   g_posState.twinContinuationBearBonus=score.twinContinuationBearBonus;
   g_posState.entryRegime        = score.regime;
   g_posState.entryReason        = entryReason;
   g_posState.setupId            = "";
   g_posState.entryDealId         = 0;
   g_posState.vwapStateAtEntry   = "NOT_CAPTURED";
   g_posState.vpMacdStateAtEntry = "NOT_CAPTURED";
   g_posState.orderFlowStateAtEntry = "NOT_CAPTURED";
   g_posState.structureStateAtEntry = "NOT_CAPTURED";
   g_posState.liquidityStateAtEntry = "NOT_CAPTURED";
   g_posState.newsStateAtEntry   = "NOT_CAPTURED";
   g_posState.sessionAtEntry     = "NOT_CAPTURED";
   g_posState.entrySpreadPts     = g_md.CurrentSpreadPts();
   double point = g_md.Point();
   g_posState.entrySlippagePts = (point>0) ? MathAbs(fillPrice-intendedPrice)/point : 0.0;
   g_posState.flipSeq = flipSeq;
   g_posState.active  = true;
   g_posState.modifyFailCount = 0;
   g_posState.partialTaken = false;
   g_posState.lastAccountedDealTicket = 0; // a freshly opened position has no OUT deals yet
   g_haveOpenPosition  = true;
  }

//--- higher-timeframe confluence: block entries that fight a clear HTF trend. A HTF with no ---
//--- clear direction (low R^2) never blocks - this is a filter against fighting HTF trend,  ---
//--- not a requirement that HTF agree outright. ---
bool AxHtfConfluenceOk(const ENUM_AX_DIR dir)
  {
   // W1 institutional direction is the non-bypassable directional authority.
   // Neutral, reversal-pending and unavailable weekly states all fail closed.
   if(!g_w1Institutional.AllowsDirection(dir))
     {
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: W1 institutional authority blocked %s (%s)",
                     AxDirToString(dir),g_w1Institutional.Summary());
      return(false);
     }
   // D1 structure and liquidity map confirms the weekly direction. This gate is
   // deliberately independent of the optional legacy H1 regression filter.
   if(!g_d1Institutional.AllowsDirection(dir))
     {
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: D1 institutional confirmation blocked %s (%s)",
                     AxDirToString(dir),g_d1Institutional.Summary());
      return(false);
     }
   // H4 EMA400 is a directional regime filter, not a replacement for W1/D1.
   // Missing H4 history fails closed when this filter is enabled.
   if(InpRequireH4TrendFilter && !g_h4TrendBreakout.AllowsDirection(dir))
     {
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: H4 trend filter blocked %s (%s)",
                     AxDirToString(dir),g_h4TrendBreakout.Summary());
      return(false);
     }
   // M15 confirmation is mandatory even when the legacy regression filter is disabled.
   // It uses only the last completed candle, never a forming-bar signal.
   if(!g_precisionEntryReady || !g_precisionEntry.AllowsDirection(dir))
     {
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: M15 precision displacement confirmation blocked %s.",AxDirToString(dir));
      return(false);
     }
   if(!InpRequireHtfConfluence) return(true);
   if(g_regimeHtf.R2() < InpHtfMinR2ToBlock) return(true);
   double slope = g_regimeHtf.Slope();
   if(dir==AX_DIR_BUY)  return(slope>=0);
   if(dir==AX_DIR_SELL) return(slope<=0);
   return(true);
  }

//--- blends order flow / footprint / volume profile / heatmap into an already-computed score as a ---
//--- bounded advisory bonus (never a hard gate) - each of the (up to) four contributes at most     ---
//--- InpOrderFlowScoreWeight points to a side's raw score (heatmap only when available - see       ---
//--- below), same additive-component pattern the scorer already uses internally for micro/         ---
//--- liquidity/momentum. Confidence and action are then                                            ---
//--- RE-derived from the blended scores using the EA's own configured thresholds, so a strong      ---
//--- order-flow read can genuinely turn a sub-threshold score into an actionable one (and vice     ---
//--- versa a contradicting order-flow read can silently keep a borderline score from firing)       ---
//--- exactly as if it had been part of the score from the start. ---
//--- Regime-condition the combined flow/footprint/profile/DOM evidence bundle.
//--- This is an advisory weight adjustment, not a new trade gate. Trend direction
//--- comes from the already-updated completed-bar regime engine. Countertrend flow
//--- remains visible at reduced weight; range/shock regimes cannot dominate the score.
double AxOrderFlowRegimeMultiplier(const ENUM_AX_DIR direction)
  {
   ENUM_AX_REGIME regime=g_regime.Regime();
   switch(regime)
     {
      case AX_REGIME_STRONG_TREND:
        if(g_regime.Slope()==0.0) return(0.65);
        return(((direction==AX_DIR_BUY && g_regime.Slope()>0.0) ||
                (direction==AX_DIR_SELL && g_regime.Slope()<0.0)) ? 1.0 : 0.35);
      case AX_REGIME_TREND:
        if(g_regime.Slope()==0.0) return(0.60);
        return(((direction==AX_DIR_BUY && g_regime.Slope()>0.0) ||
                (direction==AX_DIR_SELL && g_regime.Slope()<0.0)) ? 0.85 : 0.45);
      case AX_REGIME_BREAKOUT:
        if(g_regime.Slope()==0.0) return(0.70);
        return(((direction==AX_DIR_BUY && g_regime.Slope()>0.0) ||
                (direction==AX_DIR_SELL && g_regime.Slope()<0.0)) ? 0.90 : 0.30);
      case AX_REGIME_RANGE:          return(0.55);
      case AX_REGIME_MEAN_REVERSION: return(0.65);
      case AX_REGIME_HIGH_VOL:       return(0.50);
      case AX_REGIME_LOW_VOL:        return(0.70);
      case AX_REGIME_CHAOTIC:        return(0.20);
      case AX_REGIME_UNSAFE:         return(0.0);
     }
   return(0.0);
  }

void AxApplyOrderFlowBonus(SAxScore &score)
  {
   if(!InpUseOrderFlow) return;
   // mirror CSignalScorer::Evaluate's own regime gate - an unsafe/untradeable regime already forces
   // an all-zero score with action=NONE, and a bonus must never be the thing that overrides that
   if(!g_regime.TradingAllowed()) return;

   double w = InpOrderFlowScoreWeight;
   double refPrice = g_md.CurrentMid();

   double buyBonus  = (g_orderFlow.BullishScoreComponent(InpUseCvdDivergence)/100.0)*w
                     + (g_footprint.BullishScoreComponent()/100.0)*w
                     + (g_volProfile.BullishScoreComponent(refPrice)/100.0)*w;
   double sellBonus = (g_orderFlow.BearishScoreComponent(InpUseCvdDivergence)/100.0)*w
                     + (g_footprint.BearishScoreComponent()/100.0)*w
                     + (g_volProfile.BearishScoreComponent(refPrice)/100.0)*w;

   if(InpUseHeatmap && g_heatmap.IsAvailable())
     {
      buyBonus  += (g_heatmap.BullishScoreComponent()/100.0)*w;
      sellBonus += (g_heatmap.BearishScoreComponent()/100.0)*w;
     }

   // Regime-conditioned evidence weighting: directional flow aligned with a
   // confirmed trend keeps its influence; countertrend flow and unstable regimes
   // are discounted rather than treated as equally predictive.
   double buyRegimeMultiplier=AxOrderFlowRegimeMultiplier(AX_DIR_BUY);
   double sellRegimeMultiplier=AxOrderFlowRegimeMultiplier(AX_DIR_SELL);
   buyBonus*=buyRegimeMultiplier;
   sellBonus*=sellRegimeMultiplier;

   // Preserve the final additive evidence, including its regime adjustment.
   // These fields remain diagnostic and do not alter the base score formula.
   score.orderFlowBullBonus=buyBonus;
   score.orderFlowBearBonus=sellBonus;
   score.buyScore  = AxClampD(score.preBonusBuyScore+buyBonus,0,100);
   score.sellScore = AxClampD(score.preBonusSellScore+sellBonus,0,100);

   double gap = MathAbs(score.buyScore-score.sellScore);
   score.scoreGap=gap;
   score.minimumScoreToAct=InpMinScoreToAct;
   score.minimumGapToAct=InpMinGapToAct;
   score.confidence = AxClampD(gap*1.15,0,100);

   score.action = AX_DIR_NONE;
   if(gap>=InpMinGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=InpMinScoreToAct)       score.action = AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=InpMinScoreToAct) score.action = AX_DIR_SELL;
     }
  }

//--- Premium/discount is location evidence only. W1/D1 remain the directional
//--- authority, while H4 supplies the primary dealing range and H1 refines it.
void AxApplyPremiumDiscountScoreBonus(SAxScore &score)
  {
   if(!InpUsePremiumDiscountEngine || InpPremiumDiscountScoreWeight<=0.0 ||
      !g_regime.TradingAllowed())
      return;
   double weight=AxClampD(InpPremiumDiscountScoreWeight,0.0,20.0);
   double buyComponent=g_premiumDiscount.BullishScoreComponent();
   double sellComponent=g_premiumDiscount.BearishScoreComponent();
   double buyBonus=0.0,sellBonus=0.0;
   if(g_w1Institutional.AllowsDirection(AX_DIR_BUY) &&
      g_d1Institutional.AllowsDirection(AX_DIR_BUY))
      buyBonus=(buyComponent/100.0)*weight;
   if(g_w1Institutional.AllowsDirection(AX_DIR_SELL) &&
      g_d1Institutional.AllowsDirection(AX_DIR_SELL))
      sellBonus=(sellComponent/100.0)*weight;
   score.buyScore=AxClampD(score.buyScore+buyBonus,0.0,100.0);
   score.sellScore=AxClampD(score.sellScore+sellBonus,0.0,100.0);
   score.scoreGap=MathAbs(score.buyScore-score.sellScore);
   score.confidence=AxClampD(score.scoreGap*1.15,0.0,100.0);
   score.action=AX_DIR_NONE;
   if(score.scoreGap>=InpMinGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=InpMinScoreToAct)
         score.action=AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=InpMinScoreToAct)
         score.action=AX_DIR_SELL;
     }
   if(InpVerboseLogging && (buyBonus>0.0 || sellBonus>0.0))
      PrintFormat("AUTOPSY X PREMIUM/DISCOUNT: BUY +%.1f SELL +%.1f | %s",
                  buyBonus,sellBonus,g_premiumDiscount.Summary());
  }

//--- FVG retest is bounded confirmation evidence, never an independent order signal.
void AxApplyFvgRetestScoreBonus(SAxScore &score)
  {
   if(!InpUseFvgRetestEngine || InpFvgScoreWeight<=0.0 || !g_regime.TradingAllowed())
      return;
   double weight=AxClampD(InpFvgScoreWeight,0.0,8.0);
   double buyComponent=g_fvg.BullishScoreComponent();
   double sellComponent=g_fvg.BearishScoreComponent();
   double buyBonus=0.0,sellBonus=0.0;
   if(buyComponent>0.0 && g_w1Institutional.AllowsDirection(AX_DIR_BUY) &&
      g_d1Institutional.AllowsDirection(AX_DIR_BUY))
      buyBonus=(buyComponent/100.0)*weight;
   if(sellComponent>0.0 && g_w1Institutional.AllowsDirection(AX_DIR_SELL) &&
      g_d1Institutional.AllowsDirection(AX_DIR_SELL))
      sellBonus=(sellComponent/100.0)*weight;
   if(buyBonus<=0.0 && sellBonus<=0.0) return;
   score.buyScore=AxClampD(score.buyScore+buyBonus,0.0,100.0);
   score.sellScore=AxClampD(score.sellScore+sellBonus,0.0,100.0);
   score.scoreGap=MathAbs(score.buyScore-score.sellScore);
   score.confidence=AxClampD(score.scoreGap*1.15,0.0,100.0);
   score.action=AX_DIR_NONE;
   if(score.scoreGap>=InpMinGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=InpMinScoreToAct)
         score.action=AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=InpMinScoreToAct)
         score.action=AX_DIR_SELL;
     }
   if(InpVerboseLogging)
      PrintFormat("AUTOPSY X ICT FVG RETEST: BUY +%.2f SELL +%.2f | %s",
                  buyBonus,sellBonus,g_fvg.Summary());
  }

//--- Order Block / Breaker is location evidence only after a closed-bar structure break.
void AxApplyOrderBlockScoreBonus(SAxScore &score)
  {
   if(!InpUseOrderBlockEngine || InpOrderBlockScoreWeight<=0.0 || !g_regime.TradingAllowed())
      return;
   double weight=AxClampD(InpOrderBlockScoreWeight,0.0,8.0);
   double buyComponent=g_orderBlock.BullishScoreComponent();
   double sellComponent=g_orderBlock.BearishScoreComponent();
   double buyBonus=0.0,sellBonus=0.0;
   if(buyComponent>0.0 && g_w1Institutional.AllowsDirection(AX_DIR_BUY) &&
      g_d1Institutional.AllowsDirection(AX_DIR_BUY))
      buyBonus=(buyComponent/100.0)*weight;
   if(sellComponent>0.0 && g_w1Institutional.AllowsDirection(AX_DIR_SELL) &&
      g_d1Institutional.AllowsDirection(AX_DIR_SELL))
      sellBonus=(sellComponent/100.0)*weight;
   if(buyBonus<=0.0 && sellBonus<=0.0) return;
   score.buyScore=AxClampD(score.buyScore+buyBonus,0.0,100.0);
   score.sellScore=AxClampD(score.sellScore+sellBonus,0.0,100.0);
   score.scoreGap=MathAbs(score.buyScore-score.sellScore);
   score.confidence=AxClampD(score.scoreGap*1.15,0.0,100.0);
   score.action=AX_DIR_NONE;
   if(score.scoreGap>=InpMinGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=InpMinScoreToAct)
         score.action=AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=InpMinScoreToAct)
         score.action=AX_DIR_SELL;
     }
   if(InpVerboseLogging && (buyBonus>0.0 || sellBonus>0.0))
      PrintFormat("AUTOPSY X ICT ORDER BLOCK: BUY +%.2f SELL +%.2f | %s",
                  buyBonus,sellBonus,g_orderBlock.Summary());
  }

//--- 
 //--- Complete Market Maker Buy/Sell delivery-cycle confirmation.
 //--- W1/D1 remain directional authorities; this cannot bypass risk or execution gates.
 void AxApplyMarketMakerModelScoreBonus(SAxScore &score)
   {
    if(!InpEnableMarketMakerModel || InpMMXMScoreWeight<=0.0 ||
       !g_regime.TradingAllowed())
       return;
    SAxMarketMakerModelSnapshot mmxm=g_marketMakerModel.Read();
    if(!mmxm.available || !mmxm.reversalConfirmed ||
       mmxm.stage!=AX_MMXM_REVERSAL_CONFIRMED ||
       mmxm.direction==AX_DIR_NONE)
       return;
    if(!g_w1Institutional.AllowsDirection(mmxm.direction) ||
       !g_d1Institutional.AllowsDirection(mmxm.direction))
       return;

    double weight=AxClampD(InpMMXMScoreWeight,0.0,8.0);
    double bonus=(g_marketMakerModel.DirectionalScoreComponent()/100.0)*weight;
    if(mmxm.direction==AX_DIR_BUY)
       score.buyScore=AxClampD(score.buyScore+bonus,0.0,100.0);
    else
       score.sellScore=AxClampD(score.sellScore+bonus,0.0,100.0);

    score.scoreGap=MathAbs(score.buyScore-score.sellScore);
    score.confidence=AxClampD(score.scoreGap*1.15,0.0,100.0);
    score.action=AX_DIR_NONE;
    if(score.scoreGap>=InpMinGapToAct)
      {
       if(score.buyScore>score.sellScore && score.buyScore>=InpMinScoreToAct)
          score.action=AX_DIR_BUY;
       else if(score.sellScore>score.buyScore && score.sellScore>=InpMinScoreToAct)
          score.action=AX_DIR_SELL;
      }
    if(InpVerboseLogging)
       PrintFormat("AUTOPSY X MMXM CONFIRMED: %s +%.2f | %s",
                   (mmxm.direction==AX_DIR_BUY ? "BUY" : "SELL"),
                   bonus,g_marketMakerModel.Summary());
   }

//--- VWAP pullback, overnight bias and twin continuation are bounded confirmation evidence.
void AxApplyContinuationIntelligenceBonus(SAxScore &score)
  {
   if(!InpUseContinuationIntelligence || !g_regime.TradingAllowed()) return;
   SAxContinuationSnapshot r=g_continuationIntelligence.Read();
   if(!r.available) return;
   double buy=0.0,sell=0.0;
   if(r.vwapPullbackDirection==AX_DIR_BUY && g_w1Institutional.AllowsDirection(AX_DIR_BUY) && g_d1Institutional.AllowsDirection(AX_DIR_BUY)) buy+=(r.vwapPullbackScore/100.0)*AxClampD(InpVWAPPullbackScoreWeight,0.0,8.0);
   if(r.vwapPullbackDirection==AX_DIR_SELL && g_w1Institutional.AllowsDirection(AX_DIR_SELL) && g_d1Institutional.AllowsDirection(AX_DIR_SELL)) sell+=(r.vwapPullbackScore/100.0)*AxClampD(InpVWAPPullbackScoreWeight,0.0,8.0);
   if(r.overnightBias==AX_DIR_BUY && g_w1Institutional.AllowsDirection(AX_DIR_BUY) && g_d1Institutional.AllowsDirection(AX_DIR_BUY)) buy+=(r.overnightBiasScore/100.0)*AxClampD(InpOvernightBiasScoreWeight,0.0,5.0);
   if(r.overnightBias==AX_DIR_SELL && g_w1Institutional.AllowsDirection(AX_DIR_SELL) && g_d1Institutional.AllowsDirection(AX_DIR_SELL)) sell+=(r.overnightBiasScore/100.0)*AxClampD(InpOvernightBiasScoreWeight,0.0,5.0);
   if(r.twinDirection==AX_DIR_BUY && g_w1Institutional.AllowsDirection(AX_DIR_BUY) && g_d1Institutional.AllowsDirection(AX_DIR_BUY)) buy+=(r.twinContinuationScore/100.0)*AxClampD(InpTwinContinuationScoreWeight,0.0,8.0);
   if(r.twinDirection==AX_DIR_SELL && g_w1Institutional.AllowsDirection(AX_DIR_SELL) && g_d1Institutional.AllowsDirection(AX_DIR_SELL)) sell+=(r.twinContinuationScore/100.0)*AxClampD(InpTwinContinuationScoreWeight,0.0,8.0);
   // Preserve strategy-level attribution after the W1/D1 authority filters.
   score.vwapPullbackBullBonus=(r.vwapPullbackDirection==AX_DIR_BUY && g_w1Institutional.AllowsDirection(AX_DIR_BUY) && g_d1Institutional.AllowsDirection(AX_DIR_BUY)) ? (r.vwapPullbackScore/100.0)*AxClampD(InpVWAPPullbackScoreWeight,0.0,8.0) : 0.0;
   score.vwapPullbackBearBonus=(r.vwapPullbackDirection==AX_DIR_SELL && g_w1Institutional.AllowsDirection(AX_DIR_SELL) && g_d1Institutional.AllowsDirection(AX_DIR_SELL)) ? (r.vwapPullbackScore/100.0)*AxClampD(InpVWAPPullbackScoreWeight,0.0,8.0) : 0.0;
   score.overnightBiasBullBonus=(r.overnightBias==AX_DIR_BUY && g_w1Institutional.AllowsDirection(AX_DIR_BUY) && g_d1Institutional.AllowsDirection(AX_DIR_BUY)) ? (r.overnightBiasScore/100.0)*AxClampD(InpOvernightBiasScoreWeight,0.0,5.0) : 0.0;
   score.overnightBiasBearBonus=(r.overnightBias==AX_DIR_SELL && g_w1Institutional.AllowsDirection(AX_DIR_SELL) && g_d1Institutional.AllowsDirection(AX_DIR_SELL)) ? (r.overnightBiasScore/100.0)*AxClampD(InpOvernightBiasScoreWeight,0.0,5.0) : 0.0;
   score.twinContinuationBullBonus=(r.twinDirection==AX_DIR_BUY && g_w1Institutional.AllowsDirection(AX_DIR_BUY) && g_d1Institutional.AllowsDirection(AX_DIR_BUY)) ? (r.twinContinuationScore/100.0)*AxClampD(InpTwinContinuationScoreWeight,0.0,8.0) : 0.0;
   score.twinContinuationBearBonus=(r.twinDirection==AX_DIR_SELL && g_w1Institutional.AllowsDirection(AX_DIR_SELL) && g_d1Institutional.AllowsDirection(AX_DIR_SELL)) ? (r.twinContinuationScore/100.0)*AxClampD(InpTwinContinuationScoreWeight,0.0,8.0) : 0.0;
   if(buy<=0.0 && sell<=0.0) return;
   score.buyScore=AxClampD(score.buyScore+buy,0.0,100.0);
   score.sellScore=AxClampD(score.sellScore+sell,0.0,100.0);
   score.scoreGap=MathAbs(score.buyScore-score.sellScore);
   score.confidence=AxClampD(score.scoreGap*1.15,0.0,100.0);
   score.action=AX_DIR_NONE;
   if(score.scoreGap>=score.minimumGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=score.minimumScoreToAct) score.action=AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=score.minimumScoreToAct) score.action=AX_DIR_SELL;
     }
   if(InpVerboseLogging && r.barTime!=g_lastContinuationDiagnosticBar)
     {
      g_lastContinuationDiagnosticBar=r.barTime;
      PrintFormat("AUTOPSY X CONTINUATION INTELLIGENCE: BUY +%.2f SELL +%.2f | %s",buy,sell,g_continuationIntelligence.Summary());
     }
  }

//--- Session ORB is bounded confirmation evidence, never an independent order signal.
void AxApplyAdvancedORBScoreBonus(SAxScore &score)
  {
   if(!InpEnableAdvancedSessionORB || InpORBScoreBonus<=0.0 ||
      !g_regime.TradingAllowed())
      return;

   SAxAdvancedOrbReading orb=g_advancedSessionOrb.Read();
   if(!orb.available || orb.direction==AX_DIR_NONE || orb.sessionCount<=0)
      return;

   // ORB is confirmation evidence only. It cannot override the weekly
   // institutional authority or the daily structure direction.
   if(!g_w1Institutional.AllowsDirection(orb.direction) ||
      !g_d1Institutional.AllowsDirection(orb.direction))
      return;

   // Optional room-to-run check against the previous completed D1/W1
   // extremes. Missing higher-timeframe history fails closed when enabled.
   if(InpORBMinRoomToHTFLevelPoints>0.0)
     {
      if(!orb.htfLevelsAvailable) return;
      if(orb.direction==AX_DIR_BUY && orb.nearestResistance>0.0 &&
         orb.roomToNextLevelPoints<InpORBMinRoomToHTFLevelPoints) return;
      if(orb.direction==AX_DIR_SELL && orb.nearestSupport>0.0 &&
         orb.roomToNextLevelPoints<InpORBMinRoomToHTFLevelPoints) return;
     }

   double multiplier=1.0+0.5*(double)MathMax(0,orb.sessionCount-1);
   double bonus=MathMin(InpORBScoreBonus*2.0,InpORBScoreBonus*multiplier);
   if(orb.direction==AX_DIR_BUY)
      score.buyScore=AxClampD(score.buyScore+bonus,0.0,100.0);
   else if(orb.direction==AX_DIR_SELL)
      score.sellScore=AxClampD(score.sellScore+bonus,0.0,100.0);

   double gap=MathAbs(score.buyScore-score.sellScore);
   score.scoreGap=gap;
   score.confidence=AxClampD(gap*1.15,0.0,100.0);
   score.action=AX_DIR_NONE;
   if(gap>=score.minimumGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=score.minimumScoreToAct)
         score.action=AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=score.minimumScoreToAct)
         score.action=AX_DIR_SELL;
     }

   if(InpVerboseLogging && orb.signalBar>0 && orb.signalBar!=g_lastOrbDiagnosticBar)
     {
      g_lastOrbDiagnosticBar=orb.signalBar;
      PrintFormat("AUTOPSY X ADVANCED ORB: %s direction=%s sessions=%d [%s] range=%.*f-%.*f width=%.1fpts volumeRatio=%.2f bonus=%.1f",
                  orb.status,AxDirToString(orb.direction),orb.sessionCount,orb.sessionNames,
                  (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS),orb.rangeLow,
                  (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS),orb.rangeHigh,
                  orb.rangeWidthPoints,orb.volumeRatio,bonus);
     }
  }

//--- H4 breakout is a bounded confirmation bonus, never an independent order signal.
void AxApplyH4BreakoutBonus(SAxScore &score)
  {
   if(InpH4BreakoutScoreBonus<=0.0 || score.action==AX_DIR_NONE) return;
   if(g_h4TrendBreakout.BullishBreakout())
      score.buyScore=AxClampD(score.buyScore+InpH4BreakoutScoreBonus,0.0,100.0);
   if(g_h4TrendBreakout.BearishBreakout())
      score.sellScore=AxClampD(score.sellScore+InpH4BreakoutScoreBonus,0.0,100.0);

   double gap=MathAbs(score.buyScore-score.sellScore);
   score.scoreGap=gap;
   score.confidence=AxClampD(gap*1.15,0.0,100.0);
   score.action=AX_DIR_NONE;
   if(gap>=score.minimumGapToAct)
     {
      if(score.buyScore>score.sellScore && score.buyScore>=score.minimumScoreToAct)
         score.action=AX_DIR_BUY;
      else if(score.sellScore>score.buyScore && score.sellScore>=score.minimumScoreToAct)
         score.action=AX_DIR_SELL;
     }
  }

//--- tracks live execution quality (slippage + fill latency) across fills. A demo feed rarely
//--- exercises this path meaningfully; on a live account, repeated poor fills are a real signal
//--- that current broker/network conditions aren't fit for this strategy right now, and the EA
//--- protects capital by killing itself rather than continuing to trade through it.
void AxRegisterFillQuality(const double slippagePts,const int latencyMs)
  {
   g_sumSlippagePts += slippagePts;
   g_sumLatencyMs   += latencyMs;
   g_fillCount++;
   // This function is called only after exact broker fill confirmation.
   g_spreadCost.ObserveFillSlippage(slippagePts);
   if(g_executionQualityJournalReady)
     {
      MqlTick fillObservationTick;
      ZeroMemory(fillObservationTick);
      if(SymbolInfoTick(_Symbol,fillObservationTick) && g_md.Point()>0.0)
        {
         double fillAtrPoints=(g_volatilityReady)?g_volatility.CurrentAtr()/g_md.Point():0.0;
         if(!g_executionQualityJournal.Record(TimeCurrent(),"ENTRY",(int)g_posState.dir,
                                              fillObservationTick.bid,fillObservationTick.ask,
                                              g_md.Point(),fillAtrPoints,(int)g_regime.Regime(),
                                              (int)g_volatility.State(),slippagePts,latencyMs))
           {
            g_executionQualityJournalReady=g_executionQualityJournal.IsPersisting();
            if(!g_executionQualityJournalReady)
               Print("FLIPDEMON EXECUTION JOURNAL WARNING: persistence lost; telemetry disabled, trading decisions unchanged.");
           }
        }
     }

   bool poor = !g_risk.SlippageAcceptable(slippagePts) || (latencyMs>InpMaxFillLatencyMs);
   if(poor)
     {
      g_consecutivePoorFills++;
      g_poorFillsToday++;
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: poor fill quality (slippage=%.1fpts latency=%dms) - streak=%d",
                     slippagePts,latencyMs,g_consecutivePoorFills);
      if(g_consecutivePoorFills>=InpMaxConsecutivePoorFills && !g_risk.IsKilled())
         g_risk.ActivateKillSwitch("Repeated poor live execution quality (slippage/latency)");
     }
   else
      g_consecutivePoorFills = 0;
  }

//--- real, broker-backed position/exposure counts for THIS symbol+magic, scanned by index (never   ---
//--- PositionSelect(symbol) alone - see DuplicateGuard.mqh's own comment on why that alone misses    ---
//--- positions on a hedging account). Used to feed CRiskEngine::PreTradeAllowed()'s per-symbol/     ---
//--- directional-exposure circuit breakers with real numbers instead of the hardcoded 0/0.0 that     ---
//--- call site used before Phase 8 (code-review finding: those two new breakers were otherwise       ---
//--- silently unreachable, always seeing 0 regardless of real exposure). ---
void AxCountRealPositions(int &positionsForSymbolOut,double &directionalExposureLotsOut,const ENUM_AX_DIR dir)
  {
   positionsForSymbolOut=0; directionalExposureLotsOut=0.0;
   int total = PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      positionsForSymbolOut++;
      long type = PositionGetInteger(POSITION_TYPE);
      ENUM_AX_DIR posDir = (type==POSITION_TYPE_BUY) ? AX_DIR_BUY : AX_DIR_SELL;
      if(posDir==dir) directionalExposureLotsOut += PositionGetDouble(POSITION_VOLUME);
     }
  }

//--- every entry (fresh or flip re-entry) funnels through here, so risk/chop/HTF gates apply ---
//--- unconditionally - a confirmed flip is always allowed to CLOSE the losing side, but the   ---
//--- re-open into the new direction is still just another entry subject to every hard limit.  ---
//--- A netting account has only one position per symbol. If another EA or a manual trade owns
//--- that position, sending an opposite deal can reduce, close, or reverse somebody else's exposure.
//--- Fail closed instead of treating the symbol as flat just because this EA's magic differs.
bool AxHasForeignPositionOnSymbol(string &reasonOut)
  {
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      ulong positionMagic=(ulong)PositionGetInteger(POSITION_MAGIC);
      if(positionMagic!=InpMagicNumber)
        {
         reasonOut=StringFormat("Foreign position on %s (ticket %I64u, magic %I64u); refusing to trade a shared netting position",
                                _Symbol,ticket,positionMagic);
         return(true);
        }
     }
   reasonOut="";
   return(false);
  }

//--- account-wide position count and gross lots. These feed the account-level hard caps in
//--- CRiskEngine; passing literal zeroes here would silently disable both max-open-position and
//--- total-exposure checks whenever other charts/EAs already had risk on the account.
void AxCountAccountExposure(int &positionsOut,double &grossLotsOut)
  {
   positionsOut=0;
   grossLotsOut=0.0;
   int total=PositionsTotal();
   for(int i=0;i<total;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      double volume=PositionGetDouble(POSITION_VOLUME);
      if(volume<=0.0) continue;
      positionsOut++;
      grossLotsOut+=volume;
     }
  }

bool AxAttemptEntry(const ENUM_AX_DIR dir,const SAxScore &score,const int flipSeq,const string tag,
                    const bool gapHourRoute=false)
  {
   if(!g_autopsy.IsPersisting())
     {
      g_recoveryReady=false;
      if(InpVerboseLogging) Print("FLIPDEMON JOURNAL: new entry blocked; trade journal is not verified as persistent.");
      return(false);
     }

   // A post-fill exposure breach latches entries until a fresh broker scan proves
   // A distributed reservation left by a prior terminal session is unresolved.
   // Existing positions continue to be managed, but no fresh entry or pyramid add is allowed.
   if(InpExecutionMode==AX_EXEC_LIVE && g_distributedRecoveryPending)
     {
      if(InpVerboseLogging) Print("FLIPDEMON DISTRIBUTED RISK: new entry blocked; terminal reservation recovery is still pending.");
      return(false);
     }

   // that all live positions and pending orders are known and back inside the cap.
   if(g_accountRiskIntegrityLock)
     {
      SAxAccountRiskSnapshot unlockSnapshot;
      if(!g_accountRisk.Scan(unlockSnapshot) || !unlockSnapshot.exposureKnown ||
         unlockSnapshot.existingRiskMoney>unlockSnapshot.hardRiskBudgetMoney+0.01)
        {
         if(InpVerboseLogging) PrintFormat("FLIPDEMON ACCOUNT RISK LOCK: entries remain blocked; broker exposure is unknown or above configured maximum (%s).",unlockSnapshot.failureReason);
         return(false);
        }
      g_accountRiskIntegrityLock=false;
      Print("FLIPDEMON ACCOUNT RISK LOCK: cleared after a clean broker exposure rescan.");
     }

   // Restart recovery is a hard entry prerequisite. Never add exposure when the persisted
   // ticket-to-setup registry is unreadable, stale, or failed to save. Existing positions
   // continue through the normal management loop.
   if(!g_recoveryReady)
     {
      if(InpVerboseLogging) Print("FLIPDEMON RECOVERY: new entry blocked; registry is not verified and persisted.");
      return(false);
     }
   if(!g_virtualExitReady || !g_virtualExitRegistry.IsPersisting())
     {
      if(InpVerboseLogging) Print("FLIPDEMON VIRTUAL EXIT: new entry blocked; persisted position state is not verified.");
      return(false);
     }
   string gateReason;
   //--- emergency controls checked FIRST, ahead of every other gate - an operator-triggered stop or
   //--- a disabled direction is a deliberate override and should never be shadowed by a message that
   //--- makes it look like an ordinary risk/session gate declined the trade (spec section 38). ---
   if(!g_emergency.CanEnterDirection(dir,gateReason))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   if(AxHasForeignPositionOnSymbol(gateReason))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   int realPositionsForSymbol; double realDirectionalExposure;
   AxCountRealPositions(realPositionsForSymbol,realDirectionalExposure,dir);
   int accountOpenPositions; double accountExposureLots;
   AxCountAccountExposure(accountOpenPositions,accountExposureLots);
   if(!g_risk.PreTradeAllowed(accountOpenPositions,accountExposureLots,g_md.CurrentSpreadPts(),gateReason,
                               realPositionsForSymbol,realDirectionalExposure))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   int effectiveSessionStart=InpSessionStartHour;
   int effectiveSessionEnd=InpSessionEndHour;
   int effectiveRolloverAvoidance=InpAvoidRolloverMinutes;
   if(gapHourRoute && InpGapHourBypassSessionHours)
     {
      effectiveSessionStart=0;
      effectiveSessionEnd=0; // preserve rollover protection unless separately permitted
     }
   if(gapHourRoute && InpGapHourAllowRollover)
      effectiveRolloverAvoidance=0;
   if(!g_entryEngine.SessionAllowed(effectiveSessionStart,effectiveSessionEnd,
                                    effectiveRolloverAvoidance,gateReason))
     {
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked (%s)",gateReason);
      return(false);
     }
   if(g_chop.IsInCooldown())
     {
      if(InpVerboseLogging) Print("AUTOPSY X: entry blocked (anti-chop cooldown)");
      return(false);
     }
   // Zarattini-Aziz directional rule: VWAP is a trade-direction constraint, not merely another
   // weighted vote. A BUY requires a valid bullish closed-bar VWAP read; a SELL requires bearish.
   // Neutral/deadband or unavailable VWAP is not permission to guess. This filter is entry-only;
   // existing positions remain under their already-armed exit and broker protection.
   if(InpRequireVWAPDirection)
     {
      bool vwapDirectionAligned=(dir==AX_DIR_BUY && g_vwapValue>0.0 && g_vwapTrend=="BULLISH") ||
                                (dir==AX_DIR_SELL && g_vwapValue>0.0 && g_vwapTrend=="BEARISH");
      if(!vwapDirectionAligned)
        {
         if(InpVerboseLogging)
            PrintFormat("AUTOPSY X: VWAP directional rule blocked %s (VWAP=%.10f trend=%s; valid aligned trend required).",
                        AxDirToString(dir),g_vwapValue,g_vwapTrend);
         return(false);
        }
     }

   string compositeReason="";
   bool compositeSpreadOk=g_micro.SpreadAcceptable(InpMaxSpreadPoints);
   ENUM_AX_COMPOSITE_DIRECTION compositeDirection=g_compositeDirection.Evaluate(
      g_regime,g_regimeHtf,g_structure,g_orderFlow,g_chop,score,
      g_vwapValue,g_vwapTrend,g_vpMacd.State(),g_newsDefense.State(),
      compositeSpreadOk,compositeReason);
   bool compositeDirectionMatches=(dir==AX_DIR_BUY && compositeDirection==AX_COMPOSITE_BULLISH) ||
                                  (dir==AX_DIR_SELL && compositeDirection==AX_COMPOSITE_BEARISH);
   if(!compositeDirectionMatches)
     {
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X: composite direction gate blocked %s (%s, structure=%s).",
                     AxDirToString(dir),compositeReason,AxStructTrendToString(g_structure.Trend()));
      return(false);
     }
   if(!AxHtfConfluenceOk(dir))
     {
      if(InpVerboseLogging) Print("AUTOPSY X: entry blocked (HTF confluence)");
      return(false);
     }

   double intendedPrice = (dir==AX_DIR_BUY) ? g_md.CurrentAsk() : g_md.CurrentBid();
   double point = g_md.Point();
   double slPrice,tpPrice;
   double atrForStops = InpUseAtrStops ? g_regime.CurrentAtr() : 0.0;
   g_exit.ComputeInitialStops(g_md,dir,intendedPrice,atrForStops,slPrice,tpPrice);

   // sniper precision extends to risk placement: prefer a stop just beyond the nearest tracked
   // liquidity level over the generic ATR/fixed one, but only when it's actually TIGHTER and
   // still respects the broker's minimum stop distance - never widen risk, only sharpen it.
   // Gated on InpUseSniperEntry too so turning sniper entries off is a true A/B baseline, per README.
   // Flip re-entries ("FLIP" tag) are excluded on purpose: they're a defensive, time-critical
   // reaction to a reversal already in progress and must stay on the plain ATR/fixed stop untouched
   // by sniper precision, exactly as README section 13's "Scope" documents.
   if(InpUseSniperEntry && InpSniperUseStructureStop && point>0 && tag!="FLIP")
     {
      bool wantHighLevel = (dir==AX_DIR_SELL); // SELL stops sit above a recent high, BUY below a recent low
      double levelPrice = g_liq.GetNearestLevel(wantHighLevel,intendedPrice);
      double d1SwingLevel = g_d1Institutional.NearestValidSwingLevel(wantHighLevel,intendedPrice);
      bool existingLevelCorrectSide=(dir==AX_DIR_BUY) ? (levelPrice<intendedPrice) : (levelPrice>intendedPrice);
      if(d1SwingLevel>0.0 &&
         (!existingLevelCorrectSide || MathAbs(intendedPrice-d1SwingLevel)<MathAbs(intendedPrice-levelPrice)))
         levelPrice=d1SwingLevel;
      // NearestLevel only picks the geometrically closest level of the requested side - it does NOT
      // guarantee that level is on the correct side of price, e.g. a stale/lagging "low" fractal that
      // now sits above the current ask after a fast reversal. A stop must sit strictly on the loss
      // side of entry (below for BUY, above for SELL); reject anything else outright rather than let
      // an absolute-distance "tighter" comparison mask a stop on the wrong side of the market.
      bool correctSide = (dir==AX_DIR_BUY) ? (levelPrice<intendedPrice) : (levelPrice>intendedPrice);
      if(levelPrice>0 && correctSide)
        {
         double buffer = InpSniperStructureBufferPts*point;
         double structureSl = (dir==AX_DIR_BUY) ? levelPrice-buffer : levelPrice+buffer;
         bool tighter = (dir==AX_DIR_BUY) ? (structureSl>slPrice) : (structureSl<slPrice);
         int minStopPts = g_md.MinStopDistancePts();
         double distFromEntryPts = MathAbs(intendedPrice-structureSl)/point;
         if(tighter && distFromEntryPts>=minStopPts)
            slPrice = g_md.NormalizePrice(structureSl);
        }
     }

   // size off the ACTUAL resulting stop distance (which the above may have widened for the
   // broker's stops/freeze level, widened for ATR, or tightened to structure) so the dollar
   // risk stays pinned to the configured risk percent regardless of how far away the stop sits
   double actualSlDistPts = (point>0) ? MathAbs(intendedPrice-slPrice)/point : InpEmergencySlPoints;

   SAxRiskSizingDecision sizingDecision;
   double lots = g_risk.CalculateLotSize(g_md,intendedPrice,slPrice,dir,sizingDecision);
   if(InpVerboseLogging) PrintFormat("FLIPDEMON SIZING | equity=%.2f budget=%.2f raw=%.5f lots=%.5f risk=%.2f%% reason=%s",sizingDecision.equity,sizingDecision.riskBudgetMoney,sizingDecision.rawLots,sizingDecision.normalizedLots,sizingDecision.projectedRiskPercent,sizingDecision.rejectionReason);
   if(InpVerboseLogging) PrintFormat("ACCOUNT FLIP | baseline=%.2f target=%.2f peak=%.2f progress=%.2fx milestone=%d targetReached=%s scaler=%.2f",g_accountFlip.StartingEquity(),g_accountFlip.TargetEquity(),g_accountFlip.PeakEquity(),g_accountFlip.ProgressMultiple(),g_accountFlip.Milestone(),g_accountFlip.TargetReached()?"YES":"NO",g_accountFlip.RiskMultiplier());

   // A broker minimum lot can otherwise force a position larger than the configured
   // account-risk budget. Fail closed instead of allowing the minimum volume to
   // override the risk ceiling.
   if(lots>0.0 && AccountInfoDouble(ACCOUNT_EQUITY)>0.0)
     {
      double projectedProfit = 0.0;
      ENUM_ORDER_TYPE riskOrderType = (dir==AX_DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(riskOrderType,_Symbol,lots,intendedPrice,slPrice,projectedProfit) ||
         !MathIsValidNumber(projectedProfit) || projectedProfit>=0.0)
         lots=0.0;
      else
        {
         double projectedRiskPct = MathAbs(projectedProfit)/
                                   AccountInfoDouble(ACCOUNT_EQUITY)*100.0;
         if(projectedRiskPct > g_risk.RiskPercent()+0.0001)
            lots = 0.0;
        }
     }

   // Adaptive Flip Engine: capital-protection gate + position-size scaler, applied unconditionally
   // like every other gate above - a flip re-entry gets no exemption from risk-of-ruin/drawdown
   // protection just because it's defensive in nature. Runs here (AFTER stops/base lot size are
   // known) rather than before, because CalculateExpectedCost() needs a real lot size to convert
   // spread/commission/swap/slippage into a real currency figure - it can't run against nothing.
   // Computing the stats snapshot here (rather than reusing OnTimer's cached one) keeps this
   // function a pure read of current state; it's only ever called at an actual entry attempt, far
   // rarer than the tick loop, so this cost is fine.
   double afeRiskMultiplier = 1.0;
   // this signal's own direction vs the current VWAP trend read - feeds both AFE's VWAP alignment
   // bonus (Task 4) below AND g_posState.vwapAlignedAtEntry further down, so it's computed once
   // here, outside the AFE toggle, rather than being unreachable when InpUseAdaptiveFlipEngine is
   // off. Deliberately does NOT check g_posState: this is evaluated before any position exists for
   // this specific attempt, at the moment of a fresh entry/flip decision.
   bool vwapAlignedForThisEntry = (dir==AX_DIR_BUY && g_vwapTrend=="BULLISH") ||
                                   (dir==AX_DIR_SELL && g_vwapTrend=="BEARISH");
   if(InpUseAdaptiveFlipEngine)
     {
      SAxStatsSnapshot afeStats = g_stats.Compute(g_autopsy,g_risk.DayStartEquity()>0?g_risk.DayStartEquity():AccountInfoDouble(ACCOUNT_EQUITY));
      // volatility reused from CRegimeEngine's own ATR (never duplicated here), converted to points
      // to match CalculateExpectedCost's point-based cost math. Session volume is a real MT5 API
      // field, often 0/unavailable on OTC forex-CFD symbols with no consolidated tape - the impact
      // term inside CalculateExpectedCost treats that honestly as "cannot compute", not zero cost.
      double afeVolatilityPts = (point>0) ? g_regime.CurrentAtr()/point : 0.0;
      double afeSessionVolumeLots = SymbolInfoDouble(_Symbol,SYMBOL_SESSION_VOLUME);
      string afeReason;
      if(!g_afe.Evaluate(score,afeStats,g_consecutivePoorFills,
                          _Symbol,dir,lots,point,g_md.TickSize(),g_md.TickValue(),
                          afeVolatilityPts,InpMaxHoldSeconds,afeSessionVolumeLots,
                          InpUseVWAPExit,vwapAlignedForThisEntry,
                          afeRiskMultiplier,afeReason))
        {
         if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry blocked by Adaptive Flip Engine (%s)",afeReason);
         return(false);
        }
     }

   // AFE only ever SCALES DOWN from RiskEngine's configured stop-risk allocation.
   // Its multiplier remains clamped to [0,1], so it cannot exceed the configured maximum.
   // NormalizeVolume() clamps UP to the broker's minimum rather than down to zero, so a scaled size
   // that falls below half a volume step must be treated as "AFE wants this skipped", not silently
   // promoted back up to the broker minimum - that would defeat DEFENSIVE/CAUTION sizing outright
   // on small accounts where the base lot size already sits near the minimum.
   double accountFlipRiskMultiplier=g_accountFlip.RiskMultiplier();
   double combinedRiskMultiplier=MathMin(afeRiskMultiplier,accountFlipRiskMultiplier);
   if(combinedRiskMultiplier<1.0)
     {
      double scaledLots = lots*combinedRiskMultiplier;
      // the real trigger for the up-clamp defeat is scaledLots < VolumeMin() - anything below that
      // floors to (or below) the broker minimum inside NormalizeVolume and gets forced back up to
      // volMin by its own clamp, regardless of how close it is to volMin. A base lot size that's
      // already at the broker minimum (the small-account case this fix targets) times any scaling
      // multiplier below 1.0 will always land under volMin, so it must be zeroed here, not normalized.
      double volMin = g_md.VolumeMin();
      lots = (scaledLots < volMin) ? 0.0 : g_md.NormalizeVolume(scaledLots);
     }

   // order-book impact-cost sizing (Patnaik & Thomas 2004): cap size to what the book can actually
   // absorb within budget, rather than trusting a spread-based tolerance to say anything about a
   // size-dependent cost. A no-op when the broker provides no real depth - EstimateExecution()
   // returns false and lots is left exactly as AFE/RiskEngine already decided it.
   double impactCostPct = 0.0;
   if(InpUseImpactCostSizing && InpUseHeatmap && lots>0)
     {
      double maxAffordableLots = 0.0;
      if(g_heatmap.EstimateExecution(dir,lots,InpMaxImpactCostPct,impactCostPct,maxAffordableLots))
        {
         if(maxAffordableLots<lots)
           {
            double volMin = g_md.VolumeMin();
            lots = (maxAffordableLots < volMin) ? 0.0 : g_md.NormalizeVolume(maxAffordableLots);
           }
        }
     }
   if(lots<=0)
     {
      if(InpVerboseLogging) Print("AUTOPSY X: computed lot size is zero - entry skipped");
      return(false);
     }

   // Scale only the already risk-approved volume. OrderCalcMargin is called for
   // the exact side and executable quote, so symbol-specific HMR is reflected even
   // when ACCOUNT_LEVERAGE remains unchanged. Never force the broker minimum upward.
   MqlTick guardedMarginTick;
   if(!SymbolInfoTick(_Symbol,guardedMarginTick) ||
      guardedMarginTick.bid<=0.0 || guardedMarginTick.ask<=0.0 ||
      guardedMarginTick.ask<guardedMarginTick.bid)
     {
      Print("FLIPDEMON MARGIN GUARD: fresh executable quote unavailable; entry blocked.");
      return(false);
     }
   ENUM_ORDER_TYPE guardedOrderType=(dir==AX_DIR_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double guardedPrice=(dir==AX_DIR_BUY)?guardedMarginTick.ask:guardedMarginTick.bid;
   double marginScaledLots=0.0,guardedRequiredMargin=0.0;
   double additionalMarginBudget=0.0;
   string marginGuardReason="";
   if(!AxAdditionalMarginBudgetMoney(additionalMarginBudget,marginGuardReason) ||
      !g_marginGuard.FitVolumeToFreeMargin(_Symbol,guardedOrderType,guardedPrice,
                                           lots,additionalMarginBudget,
                                           marginScaledLots,guardedRequiredMargin,
                                           marginGuardReason))
     {
      PrintFormat("FLIPDEMON MARGIN GUARD BLOCK: requested=%.8f additionalBudget=%.2f reason=%s",
                  lots,additionalMarginBudget,marginGuardReason);
      return(false);
     }
   if(marginScaledLots<lots-1e-8 && InpVerboseLogging)
      PrintFormat("FLIPDEMON HMR SCALE: requested=%.8f approved=%.8f requiredMargin=%.2f freeMargin=%.2f additionalBudget=%.2f (%s)",
                  lots,marginScaledLots,guardedRequiredMargin,
                  AccountInfoDouble(ACCOUNT_MARGIN_FREE),additionalMarginBudget,
                  marginGuardReason);
   lots=marginScaledLots;

   string symbolOrderReason="";
   if(!AxBrokerSymbolOrderPreflight(dir,lots,symbolOrderReason))
     {
      PrintFormat("FLIPDEMON SYMBOL ORDER BLOCK: symbol=%s direction=%s lots=%.8f reason=%s",
                  _Symbol,dir==AX_DIR_BUY?"BUY":"SELL",lots,symbolOrderReason);
      return(false);
     }

   // Final broker-side margin preflight must use the actual post-risk, post-AFE,
   // post-impact lot size and a fresh executable-side quote. Account leverage alone
   // is not proof that this order is affordable; OrderCalcMargin is broker-specific.
   MqlTick marginTick;
   if(!SymbolInfoTick(_Symbol,marginTick) ||
      marginTick.bid<=0.0 || marginTick.ask<=0.0 || marginTick.ask<marginTick.bid)
     {
      PrintFormat("FLIPDEMON MARGIN ERROR: no valid fresh quote for '%s'; entry blocked.",_Symbol);
      return(false);
     }
   ENUM_ORDER_TYPE marginOrderType=(dir==AX_DIR_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double marginPrice=(dir==AX_DIR_BUY) ? marginTick.ask : marginTick.bid;
   double requiredMargin=0.0;
   if(!OrderCalcMargin(marginOrderType,_Symbol,lots,marginPrice,requiredMargin) ||
      !MathIsValidNumber(requiredMargin) || requiredMargin<=0.0)
     {
      PrintFormat("FLIPDEMON MARGIN ERROR: OrderCalcMargin failed or returned invalid margin for %s lots=%.8f price=%.10g; entry blocked. error=%d",
                  _Symbol,lots,marginPrice,GetLastError());
      return(false);
     }
   double projectedUsage=0.0,projectedLevel=0.0;
   string marginReason="";
   if(!AxBrokerMarginPreflight(requiredMargin,projectedUsage,projectedLevel,marginReason))
     {
      PrintFormat("FLIPDEMON MARGIN BLOCK: symbol=%s lots=%.8f required=%.2f usageAfter=%.2f%% levelAfter=%.2f%% reason=%s",
                  _Symbol,lots,requiredMargin,projectedUsage,projectedLevel,marginReason);
      return(false);
     }
   if(InpVerboseLogging)
      PrintFormat("FLIPDEMON MARGIN OK: symbol=%s lots=%.8f required=%.2f usageAfter=%.2f%% levelAfter=%.2f%%",
                  _Symbol,lots,requiredMargin,projectedUsage,projectedLevel);

   // Final thesis-quality gate. It runs after the actual stops, final lot size and broker
   // margin have been calculated, but before any reservation or broker request is created.
   // Existing risk, account-wide monetary-risk and distributed reservation controls remain
   // authoritative and are deliberately retained after this additional eligibility check.
   // One identifier follows the setup through broker fill, recovery and autopsy.
   // Ambiguous sends remain ORDER_SUBMITTED until broker reconciliation resolves them.
   string entryReason = AxBuildEntryReason(score,dir)+" "+tag+" "+g_d1Institutional.Summary();
   string lifecycleSetupId = AxGenerateSetupId(_Symbol,dir);
   g_tradeLifecycle.Begin(lifecycleSetupId);
   bool lifecycleReady =
      g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_THESIS_CREATED) &&
      g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_VALIDATING) &&
      g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_RISK_CHECK);
   if(!lifecycleReady)
     {
      PrintFormat("FLIPDEMON LIFECYCLE ERROR: could not initialize setup %s (%s).",
                  lifecycleSetupId,g_tradeLifecycle.LastError());
      return(false);
     }
   SAxTradeThesis executionThesis;
   executionThesis.setupId=lifecycleSetupId;
   executionThesis.symbol=_Symbol;
   executionThesis.direction=dir;
   executionThesis.timestamp=TimeCurrent();
   executionThesis.htfBias=AX_COMPOSITE_NEUTRAL; // not independently synthesized here
   executionThesis.executionBias=compositeDirection;
   executionThesis.marketRegime=score.regime;
   executionThesis.liquidityTargetPrice=0.0; // no verified target is supplied by this entry path
   executionThesis.liquidityCondition=g_structure.StateSummary();
   executionThesis.structureState=g_structure.StateSummary();
   executionThesis.entryModel=tag;
   executionThesis.vwapState=g_vwapTrend;
   executionThesis.vpMacdState=g_vpMacd.State();
   double thesisFlowImbalance=g_orderFlow.ImbalanceRatio();
   double thesisFlowVolume=g_orderFlow.WindowVolume();
   executionThesis.orderFlowState=(MathIsValidNumber(thesisFlowImbalance) &&
                                   MathIsValidNumber(thesisFlowVolume) && thesisFlowVolume>0.0)
                                  ? (thesisFlowImbalance>0.0 ? "BUY_DOMINANT" :
                                     thesisFlowImbalance<0.0 ? "SELL_DOMINANT" : "MIXED")
                                  : "DATA_UNAVAILABLE";
   executionThesis.momentumState="SCORE_CONFIRMED";
   executionThesis.signalScore=score;
   executionThesis.expectedEntry=marginPrice;
   executionThesis.stopLoss=slPrice;
   executionThesis.takeProfit=tpPrice;
   double thesisRiskDistance=MathAbs(marginPrice-slPrice);
   double thesisRewardDistance=(tpPrice>0.0) ? MathAbs(tpPrice-marginPrice) : 0.0;
   executionThesis.initialRR=(thesisRiskDistance>0.0 && thesisRewardDistance>0.0)
                             ? thesisRewardDistance/thesisRiskDistance : 0.0;
   executionThesis.spreadPts=g_md.CurrentSpreadPts();
   executionThesis.estimatedImpactCostPct=impactCostPct;
   // No calibrated per-setup EV estimator is wired into this path yet. Keep it explicitly
   // neutral instead of presenting the AFE portfolio estimate as a setup-specific forecast.
   executionThesis.expectedValueR=0.0;
   executionThesis.newsState=g_newsDefense.State();
   executionThesis.session="NOT_CAPTURED";
   executionThesis.volatilityState=AxRegimeToString(score.regime);
   executionThesis.riskPercent=g_risk.RiskPercent();
   executionThesis.riskMultiplier=afeRiskMultiplier;
   executionThesis.flipSeq=0;
   executionThesis.eligibilityStatus="";
   executionThesis.entryReason=entryReason;
   executionThesis.invalidationReason="";
   string eligibilityReason="";
   ENUM_AX_ELIGIBILITY eligibility=g_executionEligibility.Check(
      executionThesis,compositeDirection,g_risk,accountOpenPositions,accountExposureLots,
      g_md.CurrentSpreadPts(),eligibilityReason);
   if(eligibility!=AX_ELIGIBLE_LONG && eligibility!=AX_ELIGIBLE_SHORT)
     {
      g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_CANCELLED);
      if(InpVerboseLogging)
         PrintFormat("FLIPDEMON EXECUTION ELIGIBILITY: %s blocked %s (%s)",
                     AxDirToString(dir),AxEligibilityToString(eligibility),eligibilityReason);
      return(false);
     }
   if(!g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_ORDER_READY))
     {
      PrintFormat("FLIPDEMON LIFECYCLE ERROR: setup %s could not reach ORDER_READY (%s).",
                  lifecycleSetupId,g_tradeLifecycle.LastError());
      return(false);
     }
   if(InpVerboseLogging)
      PrintFormat("FLIPDEMON EXECUTION ELIGIBILITY: %s approved (R:R=%.2f, margin=%.2f, reason=%s)",
                  AxDirToString(dir),executionThesis.initialRR,requiredMargin,eligibilityReason);

   // live spread can widen well past anything a demo feed shows - scale the allowed deviation to
   // it (floored at the configured minimum) so normal spread widening doesn't spuriously reject
   // an otherwise-fine fill, while still capping how far price can move against us
   int deviationPts = (int)MathMax(InpDeviationPoints,MathRound(g_md.CurrentSpreadPts()*InpDeviationSpreadMultiplier));
   g_exec.SetDeviationPoints(deviationPts);

   ulong newTicket; double fillPrice; double actualLots; string execErr; int fillLatencyMs;
   bool entryOutcomeUncertain=false;
   // Hold the shared terminal-local account mutex from the final scan through the
   // broker request and post-fill reconciliation. This closes the race where two
   // charts both approve against the same uncommitted remaining budget.
   if(!g_accountRiskCoordinator.TryAcquire())
     {
      if(InpVerboseLogging) Print("FLIPDEMON: account risk mutex busy; this entry attempt is rejected.");
      return(false);
     }

   // Final account-wide monetary-risk scan immediately before order submission.
   // This uses the broker's latest quote and all broker-confirmed positions plus
   // the remaining unfilled volume of active pending orders. It fails closed when
   // any existing stop/exposure cannot be valued or the audit row cannot persist.
   SAxAccountRiskDecision accountRiskDecision;
   string accountRiskReason;
   if(!g_accountRisk.Evaluate(_Symbol,dir,lots,slPrice,deviationPts,g_risk.RiskPercent(),
                              accountRiskDecision,accountRiskReason))
     {
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      if(InpVerboseLogging) PrintFormat("FLIPDEMON: final account risk gate blocked entry (%s)",accountRiskReason);
      return(false);
     }

   string distributedReservationId="";
   string distributedInstanceId=g_distributedRiskCoordinator.InstanceId();
   bool distributedReservationActive=false;
   if(InpExecutionMode==AX_EXEC_LIVE)
     {
      SAxAccountRiskSnapshot reservationSnapshot;
      string reservationError;
      if(!g_accountRisk.Scan(reservationSnapshot) || !reservationSnapshot.exposureKnown ||
         !g_distributedRiskCoordinator.Reserve(accountRiskDecision,reservationSnapshot,
                                                distributedInstanceId,distributedReservationId,
                                                reservationError))
        {
         g_accountRiskIntegrityLock=true;
         if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: order blocked; central reservation was not confirmed (%s).",
                     reservationError);
         return(false);
        }
      distributedReservationActive=true;
      // Arm the durable uncertainty marker BEFORE submitting to the broker. A crash
      // between send and confirmation must not let restart recovery release risk.
      if(!g_distributedRiskCoordinator.MarkExecutionUncertain(reservationError))
        {
         g_accountRiskIntegrityLock=true;
         g_distributedRecoveryPending=true;
         EventSetTimer(1);
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: entry blocked; execution journal could not be armed (%s).",reservationError);
         if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
         return(false);
        }
     }

   // IQ200 records the fully approved candidate and the current execution route.
   // These events are analysis-only and are not consulted by any trading gate.
   if(g_iq200TelemetryReady)
     {
      SAxIQ200Event decisionEvent;
      g_iq200Telemetry.NewEvent(decisionEvent,AX_IQ200_DECISION,_Symbol,InpMagicNumber);
      decisionEvent.decisionId=lifecycleSetupId;
      decisionEvent.intentId=lifecycleSetupId;
      decisionEvent.direction=(dir==AX_DIR_BUY)?1:-1;
      decisionEvent.requestedVolume=lots;
      decisionEvent.requestedPrice=marginPrice;
      decisionEvent.bid=marginTick.bid;
      decisionEvent.ask=marginTick.ask;
      decisionEvent.pointSize=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      decisionEvent.tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      decisionEvent.atrPoints=(decisionEvent.pointSize>0.0 && g_regime.CurrentAtr()>0.0)
                              ?g_regime.CurrentAtr()/decisionEvent.pointSize:0.0;
      decisionEvent.reasonCode=(int)0;
      g_iq200Telemetry.Enqueue(decisionEvent);

      SAxIQ200Event routeEvent;
      g_iq200Telemetry.NewEvent(routeEvent,AX_IQ200_ROUTE_PLAN,_Symbol,InpMagicNumber);
      routeEvent.decisionId=lifecycleSetupId;
      routeEvent.intentId=lifecycleSetupId;
      routeEvent.direction=(dir==AX_DIR_BUY)?1:-1;
      routeEvent.orderType=(int)((dir==AX_DIR_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
      routeEvent.requestedVolume=lots;
      routeEvent.requestedPrice=marginPrice;
      routeEvent.bid=marginTick.bid;
      routeEvent.ask=marginTick.ask;
      routeEvent.reasonCode=(int)0;
      g_iq200Telemetry.Enqueue(routeEvent);
     }
   ulong orderCallStartUs=GetMicrosecondCount();
   if(!g_exec.OpenMarket(_Symbol,dir,lots,slPrice,tpPrice,"AXFDX",newTicket,fillPrice,execErr,fillLatencyMs,actualLots,entryOutcomeUncertain,g_iq200Telemetry,lifecycleSetupId))
     {
      g_executionLatency.RecordOrderCall(GetMicrosecondCount()-orderCallStartUs);
      if(!entryOutcomeUncertain && g_tradeLifecycle.State()==AX_LIFECYCLE_ORDER_SUBMITTED)
         g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_FAILED);
      g_consecutiveExecFailures++;
      g_risk.RegisterExecutionFailure(); // feeds CRiskEngine's own MaxExecutionFailures circuit breaker
                                          // (spec section 18) - a distinct counter/threshold from
                                          // g_consecutiveExecFailures above, which existed before this
                                          // phase for its own purposes; both now track every failure
      if(distributedReservationActive && entryOutcomeUncertain)
        {
         // Timeout, connection loss, or accepted-but-not-visible state is not a
         // rejection. Keep the server reservation and durable journal active.
         g_accountRiskIntegrityLock=true;
         g_distributedRecoveryPending=true;
         EventSetTimer(1);
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: execution outcome is ambiguous; reservation retained and all new entries locked (%s).",
                     execErr);
        }
      else if(distributedReservationActive)
        {
         // The immediate definitive-rejection path below owns this outcome.
         // Clear any callback flag captured during the synchronous OrderSend.
         g_distributedRejectedCallbackPending=false;
         // Persist the definitive broker rejection before release. If the release
         // response is lost, restart recovery can safely retry it.
         SAxAccountRiskSnapshot failedOrderSnapshot;
         string releaseError;
         if(!g_distributedRiskCoordinator.MarkExecutionRejected(releaseError) ||
            !g_accountRisk.Scan(failedOrderSnapshot) || !failedOrderSnapshot.exposureKnown ||
            !g_distributedRiskCoordinator.Release(distributedReservationId,distributedInstanceId,
                                                   failedOrderSnapshot,releaseError))
           {
            g_accountRiskIntegrityLock=true;
            g_distributedRecoveryPending=true;
            EventSetTimer(1);
            PrintFormat("FLIPDEMON DISTRIBUTED RISK: rejected-order reservation could not be safely released; recovery lock retained (%s).",
                        releaseError);
           }
         else
           {
            distributedReservationActive=false;
            if(failedOrderSnapshot.existingRiskMoney>failedOrderSnapshot.hardRiskBudgetMoney+0.01)
               g_accountRiskIntegrityLock=true;
           }
        }
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry failed (%s)",execErr);
      return(false);
     }
   g_executionLatency.RecordOrderCall(GetMicrosecondCount()-orderCallStartUs);
   g_consecutiveExecFailures = 0;
   g_risk.RegisterExecutionSuccess();
   // OpenMarket returns true only after broker-position confirmation, never on request acceptance.
   if(!g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_ORDER_FILLED) ||
      !g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_POSITION_ACTIVE))
     {
      g_recoveryReady=false;
      PrintFormat("FLIPDEMON LIFECYCLE ERROR: confirmed fill exists for %s but lifecycle transition failed (%s); position remains managed and new entries are blocked.",
                  lifecycleSetupId,g_tradeLifecycle.LastError());
     }

   // Use the confirmed filled volume, not the requested volume. A legitimate partial
   // fill is a real position and must be managed at its actual exposure.
   lots = actualLots;
   AxInitPositionState(newTicket,dir,lots,fillPrice,slPrice,tpPrice,score,entryReason,flipSeq,intendedPrice);
   // The broker has already confirmed this fill. Persist its real ticket and a unique setup ID
   // immediately; if persistence fails, keep managing the open position but block every new entry.
   string recoverySetupId = lifecycleSetupId;
   g_posState.setupId = recoverySetupId;
   // Snapshot the actual engine states at fill time. Missing readings remain explicit.
   g_posState.vwapStateAtEntry = g_vwapTrend;
   g_posState.vpMacdStateAtEntry = g_vpMacd.State();
   double entryFlowImbalance = g_orderFlow.ImbalanceRatio();
   double entrySessionCvd = g_orderFlow.SessionCvd();
   double entryFlowVolume = g_orderFlow.WindowVolume();
   string entryFlowDirection="DATA_UNAVAILABLE";
   if(MathIsValidNumber(entryFlowImbalance) && MathIsValidNumber(entrySessionCvd) &&
      MathIsValidNumber(entryFlowVolume) && entryFlowVolume>0.0)
     {
      if(entryFlowImbalance>0.0 && entrySessionCvd>0.0)
         entryFlowDirection="BUY_DOMINANT";
      else if(entryFlowImbalance<0.0 && entrySessionCvd<0.0)
         entryFlowDirection="SELL_DOMINANT";
      else
         entryFlowDirection="MIXED";
      // Freeze feature values at confirmed fill time. This extends the existing
      // journal field without changing its CSV schema or any production score.
      g_posState.orderFlowStateAtEntry=StringFormat(
         "%s;IMBALANCE=%.4f;PERSISTENCE=%.2f;ABSORPTION=%.2f;BULL_ABS=%d;BEAR_ABS=%d;COVERAGE=%.2f;VOLUME_SOURCE=%s",
         entryFlowDirection,entryFlowImbalance,g_orderFlow.FlowPersistence(),
         g_orderFlow.AbsorptionStrength(),(int)g_orderFlow.BullishAbsorption(),
         (int)g_orderFlow.BearishAbsorption(),g_orderFlow.DirectionalCoveragePct(),
         g_orderFlow.VolumeEvidenceLabel());
     }
   else
      g_posState.orderFlowStateAtEntry="DATA_UNAVAILABLE";
   g_posState.structureStateAtEntry = g_structure.StateSummary();
   bool entryLiquidityReady = (dir==AX_DIR_BUY)
                              ? g_liq.BullishAttackReady(g_mom.DisplacementPts())
                              : g_liq.BearishAttackReady(g_mom.DisplacementPts());
   g_posState.liquidityStateAtEntry = entryLiquidityReady ? "ATTACK_READY" : "NOT_READY_OR_CONSUMED";
   g_posState.newsStateAtEntry = g_newsDefense.State();
   g_posState.sessionAtEntry = "NOT_CAPTURED";
   // Resolve the real opening deal from broker history using the stable position identifier.
   // Do not guess from request/result tickets, which are not guaranteed to be deal tickets.
   g_posState.setupId = recoverySetupId;
   g_posState.entryReason = entryReason;
   g_posState.lastAccountedDealTicket = 0;
   if(g_positionIdentifier>0 && HistorySelectByPosition(g_positionIdentifier))
     {
      int entryDeals=HistoryDealsTotal();
      for(int dealIndex=0;dealIndex<entryDeals;dealIndex++)
        {
         ulong entryDeal=HistoryDealGetTicket(dealIndex);
         if(entryDeal==0) continue;
         if((ulong)HistoryDealGetInteger(entryDeal,DEAL_POSITION_ID)!=g_positionIdentifier) continue;
         if(HistoryDealGetInteger(entryDeal,DEAL_ENTRY)!=DEAL_ENTRY_IN) continue;
         if(HistoryDealGetString(entryDeal,DEAL_SYMBOL)!=_Symbol) continue;
         if((ulong)HistoryDealGetInteger(entryDeal,DEAL_MAGIC)!=InpMagicNumber) continue;
         g_posState.entryDealId=entryDeal;
         break; // history is chronological; retain the first actual opening deal
        }
     }
   bool recoverySaved = g_recoveryInitialized &&
                        g_restartRecovery.RecordOpenSetup(newTicket,g_positionIdentifier,recoverySetupId,_Symbol,dir,TimeCurrent(),
                          g_posState.vwapPullbackBullBonus,g_posState.vwapPullbackBearBonus,
                          g_posState.overnightBiasBullBonus,g_posState.overnightBiasBearBonus,
                          g_posState.twinContinuationBullBonus,g_posState.twinContinuationBearBonus);
   if(!recoverySaved || !g_restartRecovery.IsPersisting())
     {
      g_recoveryReady = false;
      PrintFormat("FLIPDEMON RECOVERY ERROR: live position ticket %I64u is open but its setup registry could not be verified; managing existing position and blocking new entries.",newTicket);
     }
   if(!AxSaveVirtualExitState(false,true))
      Print("FLIPDEMON VIRTUAL EXIT: filled position remains under broker protection; new entries are locked.");

   // AFE's readings at the moment of this entry, carried through to the closed-trade autopsy record
   g_posState.afeCapitalState   = g_afe.State();
   g_posState.afeRiskOfRuinPct  = g_afe.RiskOfRuinPct();
   g_posState.afeExpectedValueR = g_afe.ExpectedValueR();
   g_posState.afeWinProbability = g_afe.WinProbability();
   g_posState.afeRiskMultiplier = afeRiskMultiplier;
   g_posState.impactCostPct     = impactCostPct;
   // arms CExitEngine's mechanical VWAP exit for THIS position only - reuses vwapAlignedForThisEntry
   // (already computed above, same dir/g_vwapTrend comparison) rather than re-deriving it
   g_posState.vwapAlignedAtEntry = InpUseVWAPExit && vwapAlignedForThisEntry;
   if(g_positionIdentifier==0 || !g_positionStateRegistryReady ||
      !g_positionStateRegistry.Upsert(g_positionIdentifier,g_posState.ticket,_Symbol,
                                      InpMagicNumber,g_posState) ||
      !g_positionStateRegistry.IsPersisting())
     {
      g_recoveryReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON POSITION STATE ERROR: confirmed fill ticket=%I64u has no verified durable per-position state; existing broker protection retained and new entries blocked.",
                  g_posState.ticket);
     }
   AxRegisterFillQuality(g_posState.entrySlippagePts,fillLatencyMs);

   // Reconcile the broker-confirmed fill, not the requested size or pre-trade estimate.
   // This catches market fills beyond the configured deviation and any concurrent account
   // exposure change that occurred between approval and execution.
   SAxAccountRiskSnapshot postFillRisk;
   bool postFillScanOk=(g_accountRisk.Scan(postFillRisk) && postFillRisk.exposureKnown);
   bool distributedSettlementOk=true;
   bool distributedWithinCap=true;
   string settlementError="";
   if(postFillScanOk && distributedReservationActive)
     {
      if(!g_distributedRiskCoordinator.Settle(distributedReservationId,distributedInstanceId,
                                               postFillRisk,distributedWithinCap,settlementError))
        {
         distributedSettlementOk=false;
         g_accountRiskIntegrityLock=true;
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: broker fill is open but central settlement failed; position remains managed and new entries locked (%s).",
                     settlementError);
        }
      else
         distributedReservationActive=false;
     }

   if(!postFillScanOk || (postFillScanOk &&
      (postFillRisk.existingRiskMoney>postFillRisk.hardRiskBudgetMoney+0.01 ||
       !distributedWithinCap)))
     {
      g_accountRiskIntegrityLock=true;
      string postFillReason=postFillRisk.failureReason;
      if(postFillRisk.exposureKnown)
         postFillReason=StringFormat("POST_FILL_ACCOUNT_RISK_OVER_CONFIGURED_MAXIMUM risk=%.2f budget=%.2f",
                                     postFillRisk.existingRiskMoney,postFillRisk.hardRiskBudgetMoney);
      PrintFormat("FLIPDEMON POST-FILL RISK BREACH: ticket=%I64u actualLots=%.8f fill=%.8f; %s. New entries locked; attempting defensive close.",
                  newTicket,actualLots,fillPrice,postFillReason);
      if(!AxCloseAndRecord(AX_EXIT_EXECUTION_QUALITY))
         Print("FLIPDEMON POST-FILL DEFENCE: close/finalization not confirmed; existing position remains under management and entry lock stays active.");
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }
   if(!distributedSettlementOk)
     {
      g_accountRiskIntegrityLock=true;
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }
   PrintFormat("FLIPDEMON POST-FILL RISK VERIFIED: ticket=%I64u actualLots=%.8f aggregateRisk=%.2f budget=%.2f",
               newTicket,actualLots,postFillRisk.existingRiskMoney,postFillRisk.hardRiskBudgetMoney);
   if(!g_accountRiskCoordinator.Release())
     {
      g_accountRiskIntegrityLock=true;
      Print("FLIPDEMON COORDINATION ERROR: mutex release failed after fill; new entries remain locked.");
      return(false);
     }

   if(dir==AX_DIR_BUY && g_liq.BullishAttackReady(g_mom.DisplacementPts())) g_liq.ConsumeBullishAttack();
   if(dir==AX_DIR_SELL && g_liq.BearishAttackReady(g_mom.DisplacementPts())) g_liq.ConsumeBearishAttack();

   return(true);
  }

// Broker-confirmed pyramid add for NETTING/EXCHANGE accounts. Hedging remains blocked
// until each campaign leg has ticket-specific exit, recovery and protection management.
bool AxAttemptPyramidNettingAdd(SAxPyramidCampaignRecord &campaign,
                               const double requestedLots,const datetime triggerBar)
  {
   if(!g_w1Institutional.AllowsDirection(campaign.dir))
     {
      if(InpVerboseLogging)
         PrintFormat("FLIPDEMON PYRAMID BLOCKED BY W1 AUTHORITY: direction=%s state=%s",
                     AxDirToString(campaign.dir),g_w1Institutional.Summary());
      return(false);
     }
   if(!g_d1Institutional.AllowsDirection(campaign.dir))
     {
      if(InpVerboseLogging)
         PrintFormat("FLIPDEMON PYRAMID BLOCKED BY D1 STRUCTURE: direction=%s state=%s",
                     AxDirToString(campaign.dir),g_d1Institutional.Summary());
      return(false);
     }
   string gateReason="";
   if(!g_emergency.CanEnterDirection(campaign.dir,gateReason))
     {
      if(InpVerboseLogging) PrintFormat("FLIPDEMON PYRAMID BLOCKED: %s",gateReason);
      return(false);
     }
   // This function submits a real broker order. ANALYSIS_ONLY and PAPER_EXECUTION
   // must never reach CTrade, even if the pyramid opt-in is accidentally enabled.
   // Demo-account validation uses LIVE execution mode on a broker demo account.
   if(InpExecutionMode!=AX_EXEC_LIVE || !InpEnablePyramidExecution ||
      !g_pyramidReady || g_pyramidReconcilePending ||
      g_accountRiskIntegrityLock || g_accountRiskReconciliationPending ||
      g_nettingReversalQuarantined || !g_recoveryReady ||
      !g_virtualExitReady || !g_virtualExitRegistry.IsPersisting())
      return(false);

   // Pyramid order execution is a demo-validation feature in this rollout.
   // AX_EXEC_LIVE means broker orders are enabled; it does NOT mean a real-money
   // account is permitted. Refuse real/contest accounts even if the input is
   // accidentally enabled. A separate reviewed authorization is required before
   // any future real-account campaign execution can be considered.
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
     {
      Print("FLIPDEMON PYRAMID BLOCKED: campaign order execution is restricted to MT5 DEMO accounts.");
      return(false);
     }

   long marginMode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode!=ACCOUNT_MARGIN_MODE_RETAIL_NETTING &&
      marginMode!=ACCOUNT_MARGIN_MODE_EXCHANGE)
     {
      Print("FLIPDEMON PYRAMID BLOCKED: hedging-account execution requires ticket-specific lifecycle integration.");
      return(false);
     }
   if(!PositionSelectByTicket(campaign.ticket) ||
      PositionGetString(POSITION_SYMBOL)!=_Symbol ||
      (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber ||
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=campaign.positionIdentifier)
     {
      g_pyramidReady=false;
      Print("FLIPDEMON PYRAMID BLOCKED: campaign broker identity changed.");
      return(false);
     }
   long liveType=PositionGetInteger(POSITION_TYPE);
   ENUM_AX_DIR liveDir=(liveType==POSITION_TYPE_BUY)?AX_DIR_BUY:AX_DIR_SELL;
   double stop=PositionGetDouble(POSITION_SL);
   if(liveDir!=campaign.dir || PositionGetDouble(POSITION_VOLUME)<=0.0 || stop<=0.0)
     {
      g_pyramidReady=false;
      Print("FLIPDEMON PYRAMID BLOCKED: direction, volume or protective stop is invalid.");
      return(false);
     }

   string symbolOrderReason="";
   if(!AxBrokerSymbolOrderPreflight(campaign.dir,requestedLots,symbolOrderReason))
     {
      PrintFormat("FLIPDEMON PYRAMID BLOCKED: broker symbol contract preflight failed (%s).",
                  symbolOrderReason);
      return(false);
     }

   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0.0 || minLot<=0.0 || maxLot<minLot ||
      requestedLots<minLot || requestedLots>maxLot ||
      MathAbs(requestedLots/step-MathRound(requestedLots/step))>0.000001)
     {
      PrintFormat("FLIPDEMON PYRAMID BLOCKED: add volume %.8f violates broker min/step/max %.8f/%.8f/%.8f.",
                  requestedLots,minLot,step,maxLot);
      return(false);
     }
   if(!g_micro.SpreadAcceptable(InpMaxSpreadPoints)) return(false);

   // No EA-imposed gross or directional lot ceiling. The broker preflight above
   // enforces SYMBOL_VOLUME_MIN/MAX/STEP and SYMBOL_VOLUME_LIMIT for this symbol;
   // account-wide stop-risk and margin checks remain authoritative for total exposure.

   MqlTick quote;
   if(!SymbolInfoTick(_Symbol,quote) || quote.bid<=0.0 || quote.ask<quote.bid) return(false);
   ENUM_ORDER_TYPE orderType=(campaign.dir==AX_DIR_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double orderPrice=(campaign.dir==AX_DIR_BUY)?quote.ask:quote.bid;
   double requiredMargin=0.0;
   bool marginCalcOk=OrderCalcMargin(orderType,_Symbol,requestedLots,orderPrice,requiredMargin);
   double projectedMarginUsage=0.0,projectedMarginLevel=0.0;
   string marginReason="";
   if(!marginCalcOk ||
      !AxBrokerMarginPreflight(requiredMargin,projectedMarginUsage,projectedMarginLevel,marginReason))
     {
      PrintFormat("FLIPDEMON PYRAMID BLOCKED: margin preflight failed; required=%.2f usageAfter=%.2f%% levelAfter=%.2f%% reason=%s.",
                  requiredMargin,projectedMarginUsage,projectedMarginLevel,
                  marginCalcOk?marginReason:"ORDER_CALC_MARGIN_FAILED");
      return(false);
     }

   int deviationPts=(int)MathMax(InpDeviationPoints,
                                 MathRound(g_md.CurrentSpreadPts()*InpDeviationSpreadMultiplier));
   g_exec.SetDeviationPoints(deviationPts);
   if(!g_accountRiskCoordinator.TryAcquire()) return(false);

   // Revalidate the campaign trigger and profit after taking the account mutex.
   // This prevents a stale preflight from becoming a market order after a pullback.
   if(!PositionSelectByTicket(campaign.ticket) ||
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=campaign.positionIdentifier ||
      PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP)<InpPyramidMinProfitMoney ||
      campaign.lastTriggerBarTime==triggerBar)
     {
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }
   ENUM_AX_DIR lockedTrend=AX_DIR_NONE;
   bool lockedCross=false;
   double lockedAtr=0.0;
   MqlTick lockedQuote;
   double lockedGap=0.0;
   bool lockedTrigger=(g_precisionEntryReady && g_precisionEntry.AllowsDirection(campaign.dir) &&
                       g_pyramidEngine.ReadClosedTrend(_Symbol,lockedTrend,lockedCross) &&
                       g_pyramidEngine.ReadClosedAtr(lockedAtr) &&
                       SymbolInfoTick(_Symbol,lockedQuote) &&
                       lockedQuote.bid>0.0 && lockedQuote.ask>=lockedQuote.bid);
   if(lockedTrigger)
     {
      lockedGap=lockedAtr*InpPyramidAtrGapMultiplier;
      lockedTrigger=(lockedTrend==campaign.dir &&
         g_pyramidEngine.TierTriggerReached(campaign.dir,AX_PYRAMID_ATR_GAP,
            campaign.lastTierFillPrice,lockedQuote.bid,lockedQuote.ask,
            lockedGap,iClose(_Symbol,PERIOD_H1,1)));
     }
   if(!lockedTrigger)
     {
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }
   stop=PositionGetDouble(POSITION_SL);
   if(stop<=0.0 ||
      (campaign.dir==AX_DIR_BUY && stop>=lockedQuote.bid) ||
      (campaign.dir==AX_DIR_SELL && stop<=lockedQuote.ask))
     {
      g_pyramidReady=false;
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }

   // Recalculate broker margin with the fresh quote while holding the account
   // mutex. The earlier preflight is only an early rejection; it is not trusted
   // as the final margin decision because price, equity and free margin can move
   // while the campaign is being revalidated.
   double lockedOrderPrice=(campaign.dir==AX_DIR_BUY)?lockedQuote.ask:lockedQuote.bid;
   requiredMargin=0.0;
   projectedMarginUsage=0.0;
   projectedMarginLevel=0.0;
   marginReason="";
   if(!OrderCalcMargin(orderType,_Symbol,requestedLots,lockedOrderPrice,requiredMargin) ||
      !MathIsValidNumber(requiredMargin) || requiredMargin<=0.0 ||
      !AxBrokerMarginPreflight(requiredMargin,projectedMarginUsage,projectedMarginLevel,marginReason))
     {
      PrintFormat("FLIPDEMON PYRAMID BLOCKED: locked final margin recheck failed; required=%.2f usageAfter=%.2f%% levelAfter=%.2f%% reason=%s.",
                  requiredMargin,projectedMarginUsage,projectedMarginLevel,
                  marginReason==""?"ORDER_CALC_MARGIN_FAILED":marginReason);
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }

   SAxAccountRiskDecision riskDecision;
   string riskReason="";
   if(!g_accountRisk.Evaluate(_Symbol,campaign.dir,requestedLots,stop,deviationPts,
                              g_risk.RiskPercent(),riskDecision,riskReason))
     {
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      PrintFormat("FLIPDEMON PYRAMID BLOCKED: final account risk check failed (%s).",riskReason);
      return(false);
     }

   string reservationId="";
   string instanceId=g_distributedRiskCoordinator.InstanceId();
   bool reservationActive=false;
   if(InpExecutionMode==AX_EXEC_LIVE)
     {
      SAxAccountRiskSnapshot reserveSnapshot;
      string reserveError="";
      if(!g_accountRisk.Scan(reserveSnapshot) || !reserveSnapshot.exposureKnown ||
         !g_distributedRiskCoordinator.Reserve(riskDecision,reserveSnapshot,instanceId,
                                                reservationId,reserveError))
        {
         g_accountRiskIntegrityLock=true;
         if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
         PrintFormat("FLIPDEMON PYRAMID BLOCKED: central reservation not confirmed (%s).",reserveError);
         return(false);
        }
      reservationActive=true;
     }

   // Persist the H1 bar guard before sending. A failed attempt cannot loop on ticks
   // or repeat immediately after a restart in the same completed bar.
   campaign.lastTriggerBarTime=triggerBar;
   if(!g_pyramidCampaignRegistry.Save(campaign) || !g_pyramidCampaignRegistry.IsPersisting())
     {
      g_accountRiskIntegrityLock=true;
      if(reservationActive)
        {
         SAxAccountRiskSnapshot releaseSnapshot;
         string releaseError="";
         if(!g_accountRisk.Scan(releaseSnapshot) ||
            !g_distributedRiskCoordinator.Release(reservationId,instanceId,releaseSnapshot,releaseError))
            PrintFormat("FLIPDEMON PYRAMID: reservation retained after campaign guard persistence failure (%s).",releaseError);
        }
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }

   // Persist uncertainty after all local pre-send work, immediately before the broker
   // request. A crash after OrderSend must not release this reservation from a flat
   // account snapshot alone.
   string uncertaintyError="";
   if(reservationActive && !g_distributedRiskCoordinator.MarkExecutionUncertain(uncertaintyError))
     {
      g_accountRiskIntegrityLock=true;
      g_distributedRecoveryPending=true;
      EventSetTimer(1);
      PrintFormat("FLIPDEMON PYRAMID BLOCKED: execution journal could not be armed; broker request was not sent and reservation remains under recovery (%s).",
                  uncertaintyError);
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }

   ulong newTicket=0,newPositionId=0,orderTicket=0;
   double actualAddLots=0.0,fillPrice=0.0;
   bool outcomeUncertain=false;
   string executionError="";
   bool added=g_exec.AddToNettingPosition(_Symbol,campaign.dir,campaign.ticket,
                    campaign.positionIdentifier,requestedLots,InpMagicNumber,
                    "AXFDX|PYRAMID",newTicket,newPositionId,orderTicket,
                    actualAddLots,fillPrice,outcomeUncertain,executionError);
   if(!added)
     {
      if(outcomeUncertain)
        {
         g_accountRiskIntegrityLock=true;
         g_accountRiskReconciliationPending=true;
         g_pyramidReady=false;
         g_pyramidReconcilePending=true;
         PrintFormat("FLIPDEMON PYRAMID UNCERTAIN: no retry permitted; broker reconciliation required (%s).",executionError);
        }
      else
        {
         if(reservationActive)
           {
            SAxAccountRiskSnapshot releaseSnapshot;
            string releaseError="";
            if(!g_accountRisk.Scan(releaseSnapshot) ||
               !g_distributedRiskCoordinator.Release(reservationId,instanceId,releaseSnapshot,releaseError))
              {
               g_accountRiskIntegrityLock=true;
               PrintFormat("FLIPDEMON PYRAMID: failed-order reservation retained (%s).",releaseError);
              }
           }
         PrintFormat("FLIPDEMON PYRAMID: broker rejected add (%s).",executionError);
        }
      if(!g_accountRiskCoordinator.Release()) g_accountRiskIntegrityLock=true;
      return(false);
     }

   // Exact order deals and the resulting net position are broker-confirmed.
   g_pyramidReady=false;
   g_pyramidReconcilePending=true;
   g_accountRiskReconciliationPending=true;
   if(PositionSelectByTicket(newTicket) &&
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)==newPositionId)
     {
      g_posState.ticket=newTicket;
      g_posState.lots=PositionGetDouble(POSITION_VOLUME);
      g_posState.entryPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      g_posState.initialSlPrice=PositionGetDouble(POSITION_SL);
      g_posState.initialTpPrice=PositionGetDouble(POSITION_TP);
      g_positionIdentifier=newPositionId;
      g_haveOpenPosition=true;
     }
   else
      g_accountRiskIntegrityLock=true;

   SAxAccountRiskSnapshot postFill;
   bool postFillKnown=(g_accountRisk.Scan(postFill) && postFill.exposureKnown);
   bool centralWithinCap=true;
   bool settlementOk=true;
   string settlementError="";
   if(postFillKnown && reservationActive)
     {
      settlementOk=g_distributedRiskCoordinator.Settle(reservationId,instanceId,postFill,
                                                         centralWithinCap,settlementError);
      if(settlementOk) reservationActive=false;
      else
        {
         g_accountRiskIntegrityLock=true;
         PrintFormat("FLIPDEMON PYRAMID: confirmed fill but central settlement failed (%s).",settlementError);
        }
     }
   if(!postFillKnown ||
      (postFillKnown && (postFill.existingRiskMoney>postFill.hardRiskBudgetMoney+0.01 ||
                         !centralWithinCap)))
     {
      g_accountRiskIntegrityLock=true;
      PrintFormat("FLIPDEMON PYRAMID RISK UNKNOWN/BREACH: add %.8f at %.8f; entries locked.",
                  actualAddLots,fillPrice);
     }
   if(!settlementOk) g_accountRiskIntegrityLock=true;
   if(!g_accountRiskCoordinator.Release())
     {
      g_accountRiskIntegrityLock=true;
      Print("FLIPDEMON PYRAMID: mutex release failed after confirmed add; entries locked.");
     }
   PrintFormat("FLIPDEMON PYRAMID ADD CONFIRMED: tier=%d addLots=%.8f totalLots=%.8f fill=%.8f order=%I64u positionId=%I64u. Awaiting campaign reconciliation.",
               campaign.tierCount+1,actualAddLots,g_posState.lots,fillPrice,orderTicket,newPositionId);
   return(true);
  }


//--- self-tuning: nudges the entry confidence bar from trailing live performance, bounded so ---
//--- it can never widen or narrow the gate beyond the configured min/max multiplier. This is  ---
//--- the only thing adaptive tuning touches - never position size, never risk limits. ---
double AxAdaptiveConfidenceMultiplier(void)
  {
   if(!InpAdaptiveTuning) return(1.0);
   int n = g_autopsy.Count();
   if(n<=0) return(1.0);

   // walk backward from the most recent record, skipping scale-out partials - a partial is a
   // banked slice of a still-open thesis, not a standalone outcome, and would otherwise pad
   // the win rate with guaranteed wins (it only ever fires in profit) and mislead this reading
   int wins=0,counted=0; double netSum=0;
   for(int i=n-1;i>=0 && counted<InpAdaptiveLookbackTrades;i--)
     {
      SAxTradeRecord r;
      if(!g_autopsy.GetRecord(i,r)) continue;
      if(r.isPartial) continue;
      double campaignNet=0.0;
      bool campaignClosed=false;
      if(!g_autopsy.GetCampaignNetProfit(r.positionIdentifier,campaignNet,campaignClosed) ||
         !campaignClosed) continue;
      // Only the final row represents a completed campaign. Its outcome includes
      // every partial scale-out plus the final close, net of recorded costs.
      if(campaignNet==0.0) continue;
      if(campaignNet>0.0) wins++;
      netSum+=campaignNet;
      counted++;
     }
   if(counted<10) return(1.0);
   double winRate = 100.0*wins/counted;

   double mult = 1.0;
   if(winRate>=55.0 && netSum>0)      mult = 0.90; // performing well - allow slightly more entries
   else if(winRate<40.0 || netSum<0)  mult = 1.15; // performing poorly - be pickier until it improves

   return(AxClampD(mult,InpAdaptiveMinMultiplier,InpAdaptiveMaxMultiplier));
  }

void AxReconcileExistingPosition(void)
  {
   if(!PositionSelect(_Symbol)) return;
   if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) return;

   long type = PositionGetInteger(POSITION_TYPE);
   g_posState.ticket            = (ulong)PositionGetInteger(POSITION_TICKET);

   g_positionIdentifier          = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
   g_posState.entryTime          = (datetime)PositionGetInteger(POSITION_TIME);
   g_posState.entryPrice          = PositionGetDouble(POSITION_PRICE_OPEN);
   g_posState.dir                  = (type==POSITION_TYPE_BUY)? AX_DIR_BUY : AX_DIR_SELL;
   g_posState.lots                  = PositionGetDouble(POSITION_VOLUME);
   g_posState.initialSlPrice         = PositionGetDouble(POSITION_SL);
   g_posState.initialTpPrice          = PositionGetDouble(POSITION_TP);
   // true original (pre-break-even) SL isn't recoverable from position state alone after a
   // restart - approximate with the current SL; only affects the partial-TP R-multiple trigger
   g_posState.originalSlPrice          = g_posState.initialSlPrice;
   g_posState.breakEvenDone            = false;
   g_posState.bestFavorablePrice        = g_posState.entryPrice;
   g_posState.mfeCurrency                = 0;
   g_posState.maeCurrency                 = 0;
   g_posState.entryBuyScore                = 0;
   g_posState.entrySellScore                = 0;
   g_posState.entryConfidence                = 0;
   g_posState.vwapPullbackBullBonus=0.0;
   g_posState.vwapPullbackBearBonus=0.0;
   g_posState.overnightBiasBullBonus=0.0;
   g_posState.overnightBiasBearBonus=0.0;
   g_posState.twinContinuationBullBonus=0.0;
   g_posState.twinContinuationBearBonus=0.0;
   g_posState.entryRegime                     = AX_REGIME_UNSAFE;
   g_posState.entryReason                      = "RECONCILED_ON_INIT";
   g_posState.setupId                           = "RESTART_RECOVERED";
   SAxOpenSetupRecord recoveredSetup;
   if(g_restartRecovery.FindByPositionIdentifier(g_positionIdentifier,recoveredSetup))
     {
      if(recoveredSetup.symbol==_Symbol && recoveredSetup.dir==g_posState.dir)
        {
         g_posState.setupId=recoveredSetup.setupId;
         g_posState.vwapPullbackBullBonus=recoveredSetup.vwapPullbackBullBonus;
         g_posState.vwapPullbackBearBonus=recoveredSetup.vwapPullbackBearBonus;
         g_posState.overnightBiasBullBonus=recoveredSetup.overnightBiasBullBonus;
         g_posState.overnightBiasBearBonus=recoveredSetup.overnightBiasBearBonus;
         g_posState.twinContinuationBullBonus=recoveredSetup.twinContinuationBullBonus;
         g_posState.twinContinuationBearBonus=recoveredSetup.twinContinuationBearBonus;
        }
      else
        {
         g_recoveryReady=false;
         Print("FLIPDEMON RECOVERY ERROR: persisted strategy attribution does not match the live position; new entries remain blocked.");
        }
     }
   g_posState.entryDealId                        = 0;
   g_posState.vwapStateAtEntry                  = "DATA_UNAVAILABLE";
   g_posState.vpMacdStateAtEntry                = "DATA_UNAVAILABLE";
   g_posState.orderFlowStateAtEntry             = "DATA_UNAVAILABLE";
   g_posState.structureStateAtEntry             = "DATA_UNAVAILABLE";
   g_posState.liquidityStateAtEntry             = "DATA_UNAVAILABLE";
   g_posState.newsStateAtEntry                  = "DATA_UNAVAILABLE";
   g_posState.sessionAtEntry                    = "DATA_UNAVAILABLE";
   g_posState.entrySpreadPts                    = 0;
   g_posState.entrySlippagePts                   = 0;
   g_posState.flipSeq = 0;
   g_posState.active  = true;
   g_posState.modifyFailCount = 0;
   // no live AFE reading exists for a position the EA is re-attaching to after a restart -
   // neutral defaults rather than a fabricated one; the autopsy record for this trade will show them
   g_posState.afeCapitalState   = AX_CAPITAL_NORMAL;
   g_posState.afeRiskOfRuinPct  = 0.0;
   g_posState.afeExpectedValueR = 0.0;
   g_posState.afeWinProbability = 0.5;
   g_posState.afeRiskMultiplier = 1.0;
   g_posState.impactCostPct     = 0.0;
   // no real "VWAP trend at entry" reading exists for a position from before this EA session
   // started - never arm the mechanical exit off a fabricated alignment, default to unarmed
   g_posState.vwapAlignedAtEntry = false;

   // baseline to any OUT deals that already happened on this position before this EA session
   // started (e.g. a partial close from before a restart), so they are never re-reported -
   // and if any such deal exists, a partial must already have fired (the position is still
   // open, so a full close would have left PositionSelect() false above) - never re-arm it
   double rClosePrice=0,rGross=0,rComm=0,rSwap=0,closedVolume=0.0; datetime rTime=0; ulong rLastTicket=0;
   bool priorDealFound = AxFetchCloseFinancials(g_posState.ticket,0,rClosePrice,rGross,rComm,rSwap,rTime,rLastTicket,closedVolume);
   // A history high-water mark is NOT proof that earlier exit deals were durably journaled.
   // This build has no persistent deal-by-deal accounting ledger, so silently baselining those
   // deals can hide partial-close PnL after a restart. Keep the known boundary to avoid double
   // counting already-journaled deals, but fail closed and report the unresolved history explicitly.
   g_posState.lastAccountedDealTicket = rLastTicket;
   g_posState.partialTaken = priorDealFound;
   ulong journalBoundary=g_autopsy.LastAccountedDealTicket(g_positionIdentifier);
   if(priorDealFound && rLastTicket>journalBoundary)
     {
      g_recoveryReady = false;
      PrintFormat("FLIPDEMON RECOVERY ERROR: position %I64u has exit history through deal %I64u but the durable journal only confirms through deal %I64u. Existing position will remain managed; NEW ENTRIES BLOCKED pending accounting reconciliation.",g_posState.ticket,rLastTicket,journalBoundary);
     }
   else if(priorDealFound)
      PrintFormat("FLIPDEMON RECOVERY: historical exit deals through %I64u are covered by journal boundary %I64u.",rLastTicket,journalBoundary);

   g_haveOpenPosition  = true;
  }

// Validate broker-specific order permissions and per-symbol directional volume.
// SYMBOL_VOLUME_LIMIT includes open positions and pending orders in that direction.
bool AxBrokerSymbolOrderPreflight(const ENUM_AX_DIR direction,const double lots,
                                  string &reason)
  {
   reason="";
   if(direction!=AX_DIR_BUY && direction!=AX_DIR_SELL)
     {
      reason="INVALID_ORDER_DIRECTION";
      return(false);
     }
   if(!MathIsValidNumber(lots) || lots<=0.0)
     {
      reason="INVALID_ORDER_VOLUME";
      return(false);
     }
   long tradeMode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   long orderMode=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if(tradeMode==SYMBOL_TRADE_MODE_DISABLED || tradeMode==SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      reason="BROKER_SYMBOL_DOES_NOT_ALLOW_NEW_POSITIONS";
      return(false);
     }
   if((orderMode & SYMBOL_ORDER_MARKET)==0)
     {
      reason="BROKER_SYMBOL_MARKET_ORDERS_NOT_ALLOWED";
      return(false);
     }
   if(direction==AX_DIR_BUY && tradeMode==SYMBOL_TRADE_MODE_SHORTONLY)
     {
      reason="BROKER_SYMBOL_SHORT_ONLY";
      return(false);
     }
   if(direction==AX_DIR_SELL && tradeMode==SYMBOL_TRADE_MODE_LONGONLY)
     {
      reason="BROKER_SYMBOL_LONG_ONLY";
      return(false);
     }

   double volumeMin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double volumeMax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double volumeStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double volumeLimit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(!MathIsValidNumber(volumeMin) || !MathIsValidNumber(volumeMax) ||
      !MathIsValidNumber(volumeStep) || !MathIsValidNumber(point) ||
      !MathIsValidNumber(tickSize) || !MathIsValidNumber(volumeLimit) ||
      volumeMin<=0.0 || volumeMax<volumeMin || volumeStep<=0.0 ||
      point<=0.0 || tickSize<=0.0 || volumeLimit<0.0)
     {
      reason="BROKER_SYMBOL_CONTRACT_METADATA_INVALID";
      return(false);
     }
   double gridUnits=lots/volumeStep;
   double gridTolerance=MathMax(0.000001,MathAbs(gridUnits)*0.000000001);
   if(lots<volumeMin-1e-10 || lots>volumeMax+1e-10 ||
      MathAbs(gridUnits-MathRound(gridUnits))>gridTolerance)
     {
      reason="ORDER_VOLUME_OUTSIDE_BROKER_MIN_MAX_STEP";
      return(false);
     }

   if(volumeLimit>0.0)
     {
      double directionalVolume=0.0;
      for(int i=0;i<PositionsTotal();i++)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         long type=PositionGetInteger(POSITION_TYPE);
         if((direction==AX_DIR_BUY && type==POSITION_TYPE_BUY) ||
            (direction==AX_DIR_SELL && type==POSITION_TYPE_SELL))
            directionalVolume+=PositionGetDouble(POSITION_VOLUME);
        }
      for(int i=0;i<OrdersTotal();i++)
        {
         ulong ticket=OrderGetTicket(i);
         if(ticket==0 || OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
         ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         bool sameDirection=(direction==AX_DIR_BUY)?
            (type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP ||
             type==ORDER_TYPE_BUY_STOP_LIMIT):
            (type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP ||
             type==ORDER_TYPE_SELL_STOP_LIMIT);
         if(sameDirection)
            directionalVolume+=OrderGetDouble(ORDER_VOLUME_CURRENT);
        }
      if(directionalVolume+lots>volumeLimit+MathMax(volumeStep*0.000001,1e-10))
        {
         reason=StringFormat("BROKER_SYMBOL_DIRECTIONAL_VOLUME_LIMIT %.8f + %.8f > %.8f",
                             directionalVolume,lots,volumeLimit);
         return(false);
        }
     }
   return(true);
  }

//====================================================================
// BROKER / SYMBOL CAPABILITY DIAGNOSTICS
// Runtime metadata is authoritative; broker names are never used as an allowlist.
// Unsupported or invalid symbol properties must be visible before trading is considered.
//====================================================================
bool AxLogBrokerCompatibility(void)
  {
   string company=AccountInfoString(ACCOUNT_COMPANY);
   string server=AccountInfoString(ACCOUNT_SERVER);
   string currency=AccountInfoString(ACCOUNT_CURRENCY);
   long leverage=AccountInfoInteger(ACCOUNT_LEVERAGE);
   long marginMode=AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   long accountTradeMode=AccountInfoInteger(ACCOUNT_TRADE_MODE);

   if(!SymbolSelect(_Symbol,true))
     {
      PrintFormat("FLIPDEMON BROKER ERROR: unable to select symbol '%s' in Market Watch; entries must remain blocked.",_Symbol);
      return(false);
     }

   long digits=SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   long tradeMode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   long executionMode=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE);
   long fillingMode=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   long orderMode=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   long stopsLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   long swapMode=SymbolInfoInteger(_Symbol,SYMBOL_SWAP_MODE);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickValueProfit=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_PROFIT);
   double tickValueLoss=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   double contractSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   double volumeMin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double volumeMax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double volumeStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double volumeLimit=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   double swapLong=SymbolInfoDouble(_Symbol,SYMBOL_SWAP_LONG);
   double swapShort=SymbolInfoDouble(_Symbol,SYMBOL_SWAP_SHORT);
   double bid=0.0,ask=0.0,spreadPoints=0.0;
   MqlTick quote;
   if(SymbolInfoTick(_Symbol,quote))
     {
      bid=quote.bid;
      ask=quote.ask;
      if(point>0.0 && ask>=bid && bid>0.0) spreadPoints=(ask-bid)/point;
     }

   PrintFormat("FLIPDEMON BROKER: company='%s' server='%s' terminal_build=%d account_currency='%s' leverage=1:%I64d margin_mode=%I64d account_trade_mode=%I64d",
               company,server,(int)TerminalInfoInteger(TERMINAL_BUILD),currency,leverage,marginMode,accountTradeMode);
   PrintFormat("FLIPDEMON SYMBOL: name='%s' digits=%I64d point=%.10g tick_size=%.10g tick_value=%.10g tick_value_profit=%.10g tick_value_loss=%.10g contract_size=%.10g",
               _Symbol,digits,point,tickSize,tickValue,tickValueProfit,tickValueLoss,contractSize);
   PrintFormat("FLIPDEMON SYMBOL RULES: trade_mode=%I64d execution_mode=%I64d filling_flags=%I64d order_flags=%I64d stops_level_points=%I64d freeze_level_points=%I64d volume_min=%.8g volume_max=%.8g volume_step=%.8g volume_limit=%.8g swap_mode=%I64d swap_long=%.8g swap_short=%.8g",
               tradeMode,executionMode,fillingMode,orderMode,stopsLevel,freezeLevel,volumeMin,volumeMax,volumeStep,volumeLimit,swapMode,swapLong,swapShort);
   PrintFormat("FLIPDEMON QUOTE: symbol='%s' bid=%.10g ask=%.10g spread_points=%.2f",
               _Symbol,bid,ask,spreadPoints);

   if(!MathIsValidNumber(point) || point<=0.0 ||
      !MathIsValidNumber(tickSize) || tickSize<=0.0 ||
      !MathIsValidNumber(volumeMin) || volumeMin<=0.0 ||
      !MathIsValidNumber(volumeStep) || volumeStep<=0.0 ||
      !MathIsValidNumber(volumeMax) || volumeMax<volumeMin ||
      !MathIsValidNumber(contractSize) || contractSize<=0.0)
     {
      PrintFormat("FLIPDEMON BROKER ERROR: critical symbol metadata is invalid for '%s'; refusing initialization rather than guessing broker specifications.",_Symbol);
      return(false);
     }

   if(tradeMode==SYMBOL_TRADE_MODE_DISABLED ||
      tradeMode==SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      PrintFormat("FLIPDEMON BROKER ERROR: symbol '%s' does not permit new positions under trade mode %I64d.",_Symbol,tradeMode);
      return(false);
     }
   if((orderMode & SYMBOL_ORDER_MARKET)==0)
     {
      PrintFormat("FLIPDEMON BROKER ERROR: symbol '%s' does not permit market orders.",_Symbol);
      return(false);
     }
   if(!MathIsValidNumber(volumeLimit) || volumeLimit<0.0)
     {
      PrintFormat("FLIPDEMON BROKER ERROR: symbol '%s' has invalid directional volume limit %.8g.",_Symbol,volumeLimit);
      return(false);
     }

   return(true);
  }

//====================================================================
// SPREAD COST INTELLIGENCE
//====================================================================
//--- Additional fail-closed entry filter. Existing absolute spread and risk gates remain intact.
bool AxSpreadCostAllowed(string &reason)
  {
   if(InpGapContinuousExecutionEnabled)
     {
      if(!g_gapMarketCondition.executionConditionsAcceptable)
        {
         reason=g_gapMarketCondition.reason;
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON GAP CONTINUOUS GATE: blocked (%s), state=%d spread=%.2f baseline=%.2f samples=%d.",
                        reason,(int)g_gapMarketCondition.state,
                        g_gapMarketCondition.currentSpreadPoints,
                        g_gapMarketCondition.baselineSpreadPoints,
                        g_gapMarketCondition.samples);
         return(false);
        }
     }
   if(!InpUseSpreadCostIntelligence) { reason=""; return(true); }
   double point=g_md.Point();
   double atrPoints=(point>0.0) ? g_regime.CurrentAtr()/point : 0.0;
   SAxSpreadCostAssessment assessment;
   bool allowed=g_spreadCost.Assess(g_md.CurrentBid(),g_md.CurrentAsk(),point,
                                    atrPoints,InpEmergencySlPoints*InpDynamicTpRR,
                                    1.0,g_md.TickSize(),g_md.TickValue(),
                                    InpCommissionPerLot,InpSlippageToleranceBufferPts,
                                    assessment);
   if(!allowed)
     {
      reason=assessment.reason;
      if(InpVerboseLogging)
         PrintFormat("FLIPDEMON SPREAD COST: blocked (%s), spread=%.1f pts, median=%.1f, percentile=%.1f, slip/side=%.1f pts, fillSamples=%d empiricalP95=%s, cost/gross=%.3f, spread/ATR=%.3f",
                     reason,assessment.currentSpreadPts,assessment.medianSpreadPts,
                     assessment.percentileRank,assessment.effectiveSlippagePerSidePts,
                     assessment.empiricalSlippageSamples,
                     assessment.usedEmpiricalSlippage?"yes":"no",
                     assessment.costToGrossRatio,assessment.spreadToAtr);
      return(false);
     }
   reason="";
   return(true);
  }

//====================================================================
// GAP HOUR OBSERVATION
//====================================================================
// Samples broker/account conditions without granting trade permission.
// Reopening classification is based on an observed quote outage followed by
// a fresh quote. It is an observation label, not proof of a broker promotion.
void AxObserveGapHour(void)
  {
   SAxGapObservation observation;
   ZeroMemory(observation);

   MqlTick quote;
   bool quoteOk=SymbolInfoTick(_Symbol,quote) &&
                quote.bid>0.0 && quote.ask>=quote.bid &&
                quote.time_msc>0;
   datetime serverNow=TimeTradeServer();
   if(serverNow<=0) serverNow=TimeCurrent();
   // quote.time_msc is server-epoch milliseconds, not terminal uptime.
   // Use the same time domain for quote-age validation.
   ulong nowMsc=(ulong)serverNow*1000+999;

   observation.brokerCompany=g_brokerSnapshot.brokerCompany;
   observation.tradeServer=g_brokerSnapshot.tradeServer;
   observation.accountCurrency=g_brokerSnapshot.accountCurrency;
   observation.accountTypeLabel=g_brokerSnapshot.accountProfile;
   observation.symbol=_Symbol;
   observation.serverTime=serverNow;
   observation.quoteAvailable=quoteOk;
   observation.accountLeverage=AccountInfoInteger(ACCOUNT_LEVERAGE);
   observation.leveragePolicy=InpGapUnlimitedLeverageVerified
      ? AX_GAP_LEVERAGE_UNLIMITED_VERIFIED : AX_GAP_LEVERAGE_UNKNOWN;
   observation.unlimitedLeverageVerified=InpGapUnlimitedLeverageVerified;
   observation.leverageEligibilityVerified=InpGapLeverageEligibilityVerified;
   observation.accountTradingAllowed=(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)!=0);
   observation.expertTradingAllowed=(AccountInfoInteger(ACCOUNT_TRADE_EXPERT)!=0);
   observation.symbolTradingAllowed=(SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE)!=SYMBOL_TRADE_MODE_DISABLED &&
                                     SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE)!=SYMBOL_TRADE_MODE_CLOSEONLY);
   observation.marketStatus=observation.symbolTradingAllowed
      ? AX_GAP_MARKET_OPEN : AX_GAP_MARKET_CLOSED;

   observation.commissionPerLotRoundTrip=InpCommissionPerLot;
   observation.commissionVerified=InpGapCommissionScheduleVerified;
   observation.executionTelemetryVerified=(g_executionLatency.OrderSampleCount()>0 &&
                                            g_spreadCost.FillSlippageSampleCount()>0);
   observation.confirmedFillSamples=g_spreadCost.FillSlippageSampleCount();
   observation.orderLatencyP50Us=g_executionLatency.OrderPercentile(0.50);
   observation.orderLatencyP95Us=g_executionLatency.OrderPercentile(0.95);
   observation.orderLatencyP99Us=g_executionLatency.OrderPercentile(0.99);
   double entrySlipP95=0.0;
   double exitSlipP95=0.0;
   if(g_spreadCost.FillSlippagePercentile(0.95,entrySlipP95))
      observation.entrySlippagePoints=entrySlipP95;
   if(g_spreadCost.ExitSlippagePercentile(0.95,exitSlipP95))
      observation.exitSlippagePoints=exitSlipP95;
   observation.brokerMaxOrderVolume=g_brokerSnapshot.volumeMaximum;
   observation.brokerMinOrderVolume=g_brokerSnapshot.volumeMinimum;
   observation.brokerVolumeStep=g_brokerSnapshot.volumeStep;
   observation.brokerVolumeLimit=g_brokerSnapshot.volumeLimit;
   // MT5 has no universal property for broker-wide open-position or request-rate caps.
   // Leave these unknown until verified from broker documentation or measured limits.
   observation.brokerMaxOpenPositions=0;
   observation.brokerMaxPendingOrders=0;
   observation.brokerMaxRequestsPerSecond=0;
   observation.brokerOrderLimitsVerified=false;

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   observation.freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   observation.requiredMargin=0.0;
   observation.marginCalculationVerified=false;
   observation.referenceVolumeLots=g_brokerSnapshot.volumeMinimum;
   observation.grossNotional=0.0;
   observation.effectiveLeverage=0.0;
   string profitCurrency=SymbolInfoString(_Symbol,SYMBOL_CURRENCY_PROFIT);
   double contractSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(quoteOk && equity>0.0 && contractSize>0.0 &&
      observation.referenceVolumeLots>0.0 &&
      profitCurrency!="" && profitCurrency==observation.accountCurrency)
     {
      double midPrice=(quote.bid+quote.ask)*0.5;
      observation.grossNotional=contractSize*observation.referenceVolumeLots*midPrice;
      if(MathIsValidNumber(observation.grossNotional) && observation.grossNotional>0.0)
         observation.effectiveLeverage=observation.grossNotional/equity;
     }
   if(quoteOk && observation.referenceVolumeLots>0.0)
     {
      double required=0.0;
      if(OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,observation.referenceVolumeLots,
                         quote.ask,required) &&
         MathIsValidNumber(required) && required>=0.0)
        {
         observation.requiredMargin=required;
         observation.marginCalculationVerified=true;
        }
     }

   if(quoteOk)
     {
      observation.bid=quote.bid;
      observation.ask=quote.ask;
      observation.point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      observation.quoteTimeMsc=quote.time_msc;

      bool fresh=((nowMsc>=(ulong)quote.time_msc) &&
                  (nowMsc-(ulong)quote.time_msc)<=(ulong)InpGapQuoteFreshnessMs);
      if(fresh)
        {
         bool reopening=false;
         if(g_gapLastQuoteTimeMsc>0 &&
            quote.time_msc>g_gapLastQuoteTimeMsc &&
            (quote.time_msc-g_gapLastQuoteTimeMsc)>=(long)InpGapReopenStaleSeconds*1000)
           {
            reopening=true;
            g_gapReopenUntil=serverNow+InpGapReopenObservationSeconds;
           }
         if(g_gapReopenUntil>serverNow) reopening=true;
         observation.window=reopening
            ? AX_GAP_WINDOW_MARKET_REOPEN : AX_GAP_WINDOW_REGULAR_SESSION;
         observation.marketStatus=reopening
            ? AX_GAP_MARKET_REOPENING : AX_GAP_MARKET_OPEN;
         // This verifies the observed classification only. It does not certify
         // that the broker advertises a special Gap Hour product or promotion.
         observation.brokerWindowVerified=true;
         g_gapLastQuoteTimeMsc=quote.time_msc;
        }
     }

   observation.executionCostAssessmentVerified=false;
   observation.executionCostAcceptable=false;
   if(quoteOk && observation.point>0.0 && g_regime.CurrentAtr()>0.0)
     {
      SAxSpreadCostAssessment assessment;
      double atrPoints=g_regime.CurrentAtr()/observation.point;
      bool costOk=g_spreadCost.Assess(quote.bid,quote.ask,observation.point,
                                      atrPoints,InpEmergencySlPoints*InpDynamicTpRR,
                                      observation.referenceVolumeLots,
                                      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),
                                      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),
                                      InpCommissionPerLot,InpSlippageToleranceBufferPts,
                                      assessment);
      observation.executionCostAssessmentVerified=
         (assessment.status==AX_SCI_READY || assessment.status==AX_SCI_COST_TOO_HIGH);
      observation.executionCostAcceptable=costOk;
      observation.observedRoundTripCost=assessment.estimatedRoundTripCost;
      observation.expectedGrossProfit=assessment.expectedGrossProfit;
     }

   ENUM_AX_GAP_STATE previousState=g_gapSnapshot.state;
   ENUM_AX_GAP_WINDOW previousWindow=g_gapSnapshot.window;
   string previousReason=g_gapSnapshot.reason;
   g_gapIntelligence.Evaluate(observation,nowMsc,g_gapSnapshot);

   int analysisInterval=MathMax(1,InpGapObservationIntervalSeconds);
   if(g_gapAnalyticsReady &&
      (g_gapLastAnalysisTime==0 || serverNow-g_gapLastAnalysisTime>=analysisInterval))
     {
      if(g_gapAnalytics.Record(observation,g_gapSnapshot))
         g_gapLastAnalysisTime=serverNow;
     }

   int summaryInterval=MathMax(60,InpGapAnalyticsSummaryIntervalSeconds);
   if(g_gapAnalyticsReady &&
      (g_gapLastSummaryTime==0 || serverNow-g_gapLastSummaryTime>=summaryInterval))
     {
      if(g_gapAnalytics.WriteSummary(serverNow))
         g_gapLastSummaryTime=serverNow;
     }

   int journalInterval=MathMax(1,InpGapObservationIntervalSeconds);
   if(g_gapJournalReady &&
      (g_gapLastJournalTime==0 || serverNow-g_gapLastJournalTime>=journalInterval))
     {
      if(!g_gapJournal.Record(observation,g_gapSnapshot))
        {
         g_gapJournalReady=false;
         Print("AUTOPSY X GAP JOURNAL: persistence failed; observation remains in memory only.");
        }
      else
         g_gapLastJournalTime=serverNow;
     }
   if(InpVerboseLogging &&
      (g_gapSnapshot.state!=previousState ||
       g_gapSnapshot.window!=previousWindow ||
       g_gapSnapshot.reason!=previousReason))
      PrintFormat("AUTOPSY X GAP HOUR: state=%d window=%d market=%d symbol=%s spread=%.5f leverage=1:%I64d margin=%.5f free=%.2f commission_verified=%s costs_verified=%s reason=%s",
                  (int)g_gapSnapshot.state,(int)g_gapSnapshot.window,
                  (int)g_gapSnapshot.marketStatus,_Symbol,
                  g_gapSnapshot.spreadPoints,g_gapSnapshot.accountLeverage,
                  g_gapSnapshot.requiredMargin,g_gapSnapshot.freeMargin,
                  g_gapSnapshot.commissionVerified?"yes":"no",
                  g_gapSnapshot.executionCostAssessmentVerified?"yes":"no",
                  g_gapSnapshot.reason);
   // 'ready' is intentionally observational. No entry, batch, or risk gate
   // consumes it until a separately reviewed integration is approved.
  }

//====================================================================
// LIFECYCLE
//====================================================================
int OnInit(void)
  {
   if(!MathIsValidNumber(InpMaxAccountStopRiskPercent) || InpMaxAccountStopRiskPercent<0.05 || InpMaxAccountStopRiskPercent>100.0 ||
      !MathIsValidNumber(InpExtremeRiskPercent) || InpExtremeRiskPercent<0.05)
     {
      Print("FLIPDEMON INIT FAILED: stop-risk maximum must be 0.05..100%, and Extreme risk must be finite and >=0.05%.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   // Configure the account-wide calculator before startup reconciliation or any Scan call.
   g_accountRisk.ConfigureMaxRiskPercent(InpMaxAccountStopRiskPercent);

   // Account-wide order approval is serialized across every FLIPDEMON instance
   // attached to this MT5 terminal. Separate terminals require an external coordinator.
   if(!g_accountRiskCoordinator.Init())
     {
      Print("FLIPDEMON: account risk coordinator initialization failed; refusing to start.");
      return(INIT_FAILED);
     }

   // Capture account and symbol capabilities from live MT5 metadata. Account labels such as
   // Pro/ECN/Raw/Cent are not inferred because MT5 does not expose a universal account-type field.
   if(!g_brokerCompatibility.Capture(_Symbol,g_brokerSnapshot))
     {
      PrintFormat("FLIPDEMON UBCE: compatibility snapshot failed closed (%s).",
                  g_brokerSnapshot.validationReason);
      return(INIT_FAILED);
     }
   g_brokerCompatibility.Log(g_brokerSnapshot);

   // Retain detailed diagnostics and stricter symbol preflight. There is no broker-name allowlist:
   // broker names are descriptive metadata, while actual capabilities decide compatibility.
   if(!AxLogBrokerCompatibility())
      return(INIT_FAILED);

   // Position lifecycle compatibility is an explicit UBCE capability, not a broker-name
   // guess. Hedging and exchange modes remain blocked until their ticket-level lifecycle
   // adapters are fully validated against close, partial-close, recovery and campaign flows.
   if(g_brokerSnapshot.positionManagementCapability!=AX_CAPABILITY_SUPPORTED)
     {
      PrintFormat("AUTOPSY X: position lifecycle unsupported (%s). Analysis-only attachment is not enabled on this account model; execution remains blocked until the adapter is validated.",
                  g_brokerSnapshot.positionManagementReason);
      return(INIT_FAILED);
     }

   // Real broker orders require the authenticated cross-terminal coordinator. Analysis and
   // paper modes remain usable without a remote service; LIVE mode fails initialization closed.
   if(InpExecutionMode==AX_EXEC_LIVE)
     {
      string coordinatorInitError;
      if(!g_distributedRiskCoordinator.Init(InpRiskCoordinatorUrl,InpRiskCoordinatorKey,
                                            InpRiskCoordinatorTimeoutMs,_Symbol,InpMagicNumber,
                                            coordinatorInitError))
        {
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: LIVE mode refused (%s).",coordinatorInitError);
         return(INIT_FAILED);
        }
      SAxAccountRiskSnapshot startupRisk;
      bool startupWithinCap=false;
      bool startupSnapshotKnown=(g_accountRisk.Scan(startupRisk) && startupRisk.exposureKnown);
      if(!startupSnapshotKnown)
        {
         g_distributedRecoveryPending=true;
         g_accountRiskIntegrityLock=true;
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: startup snapshot unavailable; EA remains attached in LOCKED RECOVERY MODE (%s).",
                     startupRisk.failureReason);
        }
      else
        {
         // A prior terminal session may have stopped after the server committed a
         // reservation. Keep the EA attached and retry from OnTimer if recovery is
         // temporarily unavailable. Entry checks remain hard-blocked meanwhile.
         if(!g_distributedRiskCoordinator.RecoverPending(startupRisk,coordinatorInitError))
           {
            g_distributedRecoveryPending=true;
            g_accountRiskIntegrityLock=true;
            PrintFormat("FLIPDEMON DISTRIBUTED RISK: unresolved prior reservation; LOCKED RECOVERY MODE, retrying broker reconciliation (%s).",
                        coordinatorInitError);
           }
         if(!g_distributedRecoveryPending)
           {
            if(!g_distributedRiskCoordinator.Reconcile(startupRisk,startupWithinCap,coordinatorInitError))
              {
               g_distributedRecoveryPending=true;
               g_accountRiskIntegrityLock=true;
               PrintFormat("FLIPDEMON DISTRIBUTED RISK: startup central reconciliation unavailable; LOCKED RECOVERY MODE (%s).",
                           coordinatorInitError);
              }
            else if(!startupWithinCap)
              {
               g_accountRiskIntegrityLock=true;
               Print("FLIPDEMON DISTRIBUTED RISK: broker exposure is above the account risk budget; existing positions remain managed, new entries locked.");
              }
            else
               Print("FLIPDEMON DISTRIBUTED RISK: authenticated broker snapshot reconciled; LIVE entries may request reservations.");
           }
        }
     }

   // demo execution is typically near-instant with near-zero slippage - it will not surface the
   // live-only problems this EA specifically defends against (spread spikes, slow fills, real
   // slippage). Detected once here purely to label the dashboard/log honestly; behavior itself
   // doesn't branch on it - the execution-quality circuit breaker runs unconditionally and simply
   // won't have much to react to on a demo feed.
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   g_isLiveAccount = (tradeMode==ACCOUNT_TRADE_MODE_REAL);
   PrintFormat("AUTOPSY X: account mode = %s",g_isLiveAccount?"LIVE":(tradeMode==ACCOUNT_TRADE_MODE_CONTEST?"CONTEST":"DEMO"));

   if(!g_md.Init(_Symbol))
     {
      Print("AUTOPSY X: failed to initialize market data for ",_Symbol);
      return(INIT_FAILED);
     }
   // Snapshot export is observational. Failure to open the file must never alter execution eligibility.
   if(!g_marketSnapshotRecorder.Init(_Symbol,InpMagicNumber,InpEnableMarketSnapshots))
      Print("AUTOPSY X SNAPSHOT: recorder unavailable; strategy continues without snapshot export.");
   if(InpEnableAdvancedTrendSuite)
     {
      bool shadowReady=g_shadowRiver.ConfigurePoints(InpShadowRiverSensitivityPoints,g_md.Point(),
                                                       InpShadowRiverReversalMultiplier);
      bool alphaReady=g_alphaTrend.Init(_Symbol,InpAdvancedSignalTimeframe,
                                        InpAlphaTrendPeriod,InpAlphaTrendMultiplier);
      bool mfiReady=g_mfi.Init(_Symbol,InpAdvancedSignalTimeframe,InpMfiPeriod);
      bool slingReady=g_slingshot.Init(_Symbol,InpAdvancedSignalTimeframe,
                                       InpSlingshotFastEMA,InpSlingshotSlowEMA);
      bool chandelierReady=g_chandelier.Init(_Symbol,InpAdvancedSignalTimeframe,
                                             InpChandelierLookback,InpChandelierAtrPeriod,
                                             InpChandelierAtrMultiplier);
      g_executionFeedback.Configure(0.10);
      g_alphaTrend.Update(true);
      g_mfi.Update(true);
      g_slingshot.Update(true);
      PrintFormat("AUTOPSY X ADVANCED SUITE: ShadowRiver=%s AlphaTrend=%s MFI=%s EMA38/62=%s Chandelier=%s. Analysis-only.",
                  shadowReady?"READY":"UNAVAILABLE",alphaReady?"READY":"UNAVAILABLE",
                  mfiReady?"READY":"UNAVAILABLE",slingReady?"READY":"UNAVAILABLE",
                  chandelierReady?"READY":"UNAVAILABLE");
     }
   g_spreadCost.Configure(InpSpreadCostMinSamples,InpSpreadCostMaxCostToGross,
                          InpSpreadCostMaxSpreadToAtr);
   g_gapIntelligence.Configure(InpGapQuoteFreshnessMs);
   g_gapJournalReady=g_gapJournal.Init(_Symbol,InpMagicNumber);
   g_gapAnalyticsReady=g_gapAnalytics.Init(g_brokerSnapshot.brokerCompany,
                                               g_brokerSnapshot.tradeServer,
                                               g_brokerSnapshot.accountProfile,
                                               _Symbol,InpMagicNumber);
   if(!g_gapAnalyticsReady)
      Print("AUTOPSY X GAP ANALYTICS: initialization failed; raw observation journal remains available.");
   if(!g_gapJournalReady)
      Print("AUTOPSY X GAP JOURNAL: daily CSV unavailable; broker observation continues without persistence.");
   else
      PrintFormat("AUTOPSY X GAP JOURNAL: daily CSV ready file=%s",g_gapJournal.FileName());
   g_executionQualityJournalReady=g_executionQualityJournal.Init(_Symbol,InpMagicNumber);
   if(!g_executionQualityJournalReady)
      Print("FLIPDEMON EXECUTION JOURNAL WARNING: durable execution telemetry unavailable; trading decisions are unchanged.");
   else
      PrintFormat("FLIPDEMON EXECUTION JOURNAL: ready file=%s",g_executionQualityJournal.FileName());
   g_iq200TelemetryReady=g_iq200Telemetry.Init(_Symbol,InpMagicNumber);
   if(!g_iq200TelemetryReady)
      Print("AX IQ200 TELEMETRY WARNING: event stream unavailable; execution and risk decisions are unchanged.");
   else
      PrintFormat("AX IQ200 TELEMETRY: schema v1 ready file=%s",g_iq200Telemetry.FileName());
   if(!g_regime.Init(_Symbol,InpRegimeTimeframe))
     {
      Print("AUTOPSY X: failed to initialize regime engine (ATR handle)");
      return(INIT_FAILED);
     }
   if(!g_regimeHtf.Init(_Symbol,InpHtfTimeframe))
     {
      Print("AUTOPSY X: failed to initialize HTF regime engine (ATR handle)");
      return(INIT_FAILED);
     }
   if(InpEnableRegimeClassificationAnalysis)
     {
      g_macroRegime.Configure(60.0,40.0,20,PERIOD_M5,50.0);
      g_regimeIntelligence.Configure(20);
      g_regimeClassifier.Configure(InpRegimePersistenceBars,InpRegimePersistenceStability,
                                   InpRegimePersistenceMomentum,2.0);
      g_volatility.Configure(20.0,80.0,95.0,InpRegimeShockAccelPct);
      g_volatilityReady = g_volatility.Init(_Symbol,InpRegimeTimeframe,
                                             AX_VOL_ATR_PERIOD_DEFAULT,100);
      if(!g_volatilityReady)
         Print("FLIPDEMON REGIME RESEARCH: volatility ATR handle unavailable; R1-R8 output will remain unavailable and order flow is unchanged.");
      if(InpEnableRegimeResearchJournal)
        {
         g_regimeJournalReady=g_regimeJournal.Init(_Symbol,InpRegimeTimeframe);
         if(!g_regimeJournalReady)
            Print("FLIPDEMON REGIME JOURNAL WARNING: research journal unavailable; regime analysis continues without persistence and trade execution is unchanged.");
         else
            PrintFormat("FLIPDEMON REGIME JOURNAL: ready file=%s last_timestamp=%s",
                        g_regimeJournal.FileName(),
                        g_regimeJournal.LastTimestamp()>0 ? TimeToString(g_regimeJournal.LastTimestamp(),TIME_DATE|TIME_MINUTES) : "NONE");
        }
     }
   if(!g_structure.Init(_Symbol,InpRegimeTimeframe,300))
     {
      Print("AUTOPSY X: failed to initialize closed-bar structure engine");
      return(INIT_FAILED);
     }
   if(InpEnablePurePriceActionDiagnostics)
     {
      g_purePriceActionReady=g_purePriceAction.Init(_Symbol,InpRegimeTimeframe,InpPurePriceActionLookback,InpEnablePurePriceActionJournal);
      if(!g_purePriceActionReady)
         Print("AUTOPSY X: pure price-action diagnostics unavailable; no trading decision is affected.");
     }
   if(!g_w1Institutional.Init(_Symbol,260,30))
      PrintFormat("AUTOPSY X: W1 institutional data unavailable at startup; all new directional entries remain blocked (%s).",
                  g_w1Institutional.Summary());
   if(!g_d1Institutional.Init(_Symbol,180,30))
      PrintFormat("AUTOPSY X: D1 institutional data unavailable at startup; all new directional entries remain blocked (%s).",
                  g_d1Institutional.Summary());
   if(InpUsePremiumDiscountEngine && !g_premiumDiscount.Init(_Symbol,180,2))
      Print("AUTOPSY X: premium/discount range history unavailable at startup; location score remains neutral until valid completed-bar ranges form.");
   if(InpUseFvgRetestEngine && !g_fvg.Init(_Symbol,InpFvgTimeframe,InpFvgLookbackBars,
      InpFvgMaxAgeBars,InpFvgMinGapAtr,InpFvgMinDisplacementBodyRatio))
      Print("AUTOPSY X: ICT FVG retest engine unavailable; FVG score contribution remains zero.");
   if(InpUseOrderBlockEngine && !g_orderBlock.Init(_Symbol,InpRegimeTimeframe,
      InpOrderBlockLookbackBars,InpOrderBlockMaxAgeBars,InpOrderBlockOriginSearchBars,
      InpOrderBlockMinDisplacementBodyRatio))
      Print("AUTOPSY X: order block engine unavailable; order-block score contribution remains zero.");
   if(InpEnableMarketMakerModel && !g_marketMakerModel.Init(_Symbol,PERIOD_H4,
      InpMMXMConfirmationTimeframe,InpMMXMMaxOriginAgeBars,
      InpMMXMMinConsolidationBars,InpMMXMMaxConsolidationBars,
      InpMMXMMaxConsolidationAtr,InpMMXMBreakoutBufferAtr,
      InpMMXMReversalLookbackBars,InpMMXMMinDisplacementAtr,
      InpMMXMMinBodyRatio,InpMMXMTerminalZonePercent))
      Print("AUTOPSY X: Market Maker Buy/Sell Model initialization failed; model evidence unavailable.");
   if(InpEnableDailyExtremeProjection && !g_dailyExtremeProjection.Init(_Symbol,
      InpDailyExtremeAsiaStartNewYorkHour,InpDailyExtremeAsiaEndNewYorkHour,
      InpDailyExtremeCBDRStartNewYorkHour,InpDailyExtremeCBDREndNewYorkHour,
      InpDailyExtremeConfluenceToleranceADR,InpDailyExtremeBrokerUtcOffsetMinutes))
      PrintFormat("AUTOPSY X: New York IPDA projection unavailable (%s). Check UTC clock, broker offset and M1 history.",
                  g_dailyExtremeProjection.Summary());
   else if(InpEnableDailyExtremeProjection)
      PrintFormat("AUTOPSY X NEW YORK IPDA CLOCK: %s | Asia NY=%02d-%02d (prior evening) CBDR NY=%02d-%02d | broker offset mode=%s | observational only",
         g_dailyExtremeProjection.Summary(),InpDailyExtremeAsiaStartNewYorkHour,
         InpDailyExtremeAsiaEndNewYorkHour,InpDailyExtremeCBDRStartNewYorkHour,
         InpDailyExtremeCBDREndNewYorkHour,(InpDailyExtremeBrokerUtcOffsetMinutes==9999 ? "AUTO LIVE" : "MANUAL TESTER/REPLAY"));
   if(!g_h4TrendBreakout.Init(_Symbol,PERIOD_H4,400,20))
      PrintFormat("AUTOPSY X: H4 EMA400/range breakout data unavailable; H4 filter will fail closed when required (%s).",
                  g_h4TrendBreakout.Summary());
   if(!g_vpMacd.Init(_Symbol,InpRegimeTimeframe,InpVPMACDFastPeriod,InpVPMACDSlowPeriod,InpVPMACDSignalPeriod))
      Print("AUTOPSY X: VP-MACD initialization failed; its vote will remain unavailable.");
   else if(!g_vpMacd.Update())
      Print("AUTOPSY X: VP-MACD warming up; waiting for completed-bar volume history.");
   if(!g_newsDefense.Init(_Symbol,InpNewsMinutesBefore,InpNewsMinutesAfter,InpNewsRefreshSeconds))
      Print("AUTOPSY X: News Defense initialization failed; calendar state remains unavailable.");
   else if(!g_newsDefense.Update(true))
      PrintFormat("AUTOPSY X: News Defense data unavailable at startup (%s). LIVE entries will fail closed.",g_newsDefense.Reason());
   g_compositeDirection.Configure(55.0,InpHtfMinR2ToBlock,InpExecutionMode==AX_EXEC_LIVE);
   g_liq.Init(_Symbol,InpRegimeTimeframe);
   g_liq.RefreshLevels();
   g_regime.Update();
   g_regimeHtf.Update();
   g_structure.Update();
   if(g_purePriceActionReady)
     {
      g_purePriceAction.Update(true);
      if(InpVerboseLogging) Print("AUTOPSY X SHADOW: ",g_purePriceAction.Summary());
     }
   g_w1Institutional.Update(true);
   g_d1Institutional.Update(true);
   if(InpUsePremiumDiscountEngine) g_premiumDiscount.Update(true);
   if(InpEnableMarketMakerModel)
     {
      SAxPremiumDiscountSnapshot mmxmH4Range;
      ZeroMemory(mmxmH4Range);
      g_premiumDiscount.Read(PERIOD_H4,mmxmH4Range);
      g_marketMakerModel.Update(mmxmH4Range,true);
      PrintFormat("AUTOPSY X ICT MARKET MAKER MODEL: %s",g_marketMakerModel.Summary());
     }
   if(InpEnableDailyExtremeProjection) g_dailyExtremeProjection.Update(true);
   g_h4TrendBreakout.Update(true);
   g_vpMacd.Update();
   // Respect the calendar engine's refresh interval after the forced startup read.
   g_newsDefense.Update(false);

   g_volProfile.Init(_Symbol,InpVolumeProfileBars,InpVolumeProfileBinPoints,g_md.Point(),InpRegimeTimeframe);
   g_volProfile.Refresh();
   g_footprint.Configure(InpFootprintBinPoints,InpFootprintImbalanceRatio,InpFootprintStackedLevels,g_md.Point());
   // market depth is unavailable on most retail forex/CFD symbols via MT5 - this is expected, not
   // an error, and the dashboard/score both degrade to "N/A"/no contribution when it's not there
   if(InpUseHeatmap) g_heatmap.Init(_Symbol);

   g_scorer.Configure(InpMinScoreToAct,InpMinGapToAct);
   g_advancedSessionOrb.SetChartIdentity(_Symbol,InpMagicNumber);
   g_advancedSessionOrb.Configure(InpEnableAdvancedSessionORB,InpORBRangeMinutes,
                                  InpORBBreakoutTimeframe,InpORBAsiaServerHour,
                                  InpORBLondonServerHour,InpORBNewYorkServerHour,
                                  InpORBBufferPoints,InpORBMinBodyRatio,
                                  InpORBMinCloseLocation,InpORBMinVolumeRatio,
                                  InpORBMinRangePoints,InpORBMaxRangePoints);
   PrintFormat("AUTOPSY X ADVANCED ORB: %s | range=%dmin | breakoutTF=%s | server sessions=%02d/%02d/%02d",
               InpEnableAdvancedSessionORB?"ENABLED":"DISABLED",
               InpORBRangeMinutes,EnumToString(InpORBBreakoutTimeframe),
               InpORBAsiaServerHour,InpORBLondonServerHour,InpORBNewYorkServerHour);
   g_flip.Configure(InpFlipRequiredConfirmations,InpFlipMinConfidence);
   g_chop.Configure(InpAntiChopBaseCooldownSec,InpAntiChopMaxCooldownSec);
   g_risk.Configure(AxRiskPercentForMode(),InpDailyLossLimitPercent,InpMaxConsecutiveLosses,
                     InpMaxOpenPositions,InpMaxFlipsPerDay,
                     InpMaxTradesPerRollingPeriod,InpRollingPeriodSeconds,
                     InpMaxSpreadPoints,InpMaxSlippagePoints,InpMinFreeMarginPercent,
                     InpWeeklyLossLimitPercent,InpMaxPositionsPerSymbol,
                     InpMaxExecutionFailures,InpMaxAccountStopRiskPercent);
   g_emergency.Configure(InpExecutionMode,InpEnableTrading,InpEnableLong,InpEnableShort);

   //--- IMMEDIATE and CONFIRMED_CROSS_PLUS_STRUCTURE VWAP exit modes need live-price and structure-
   //--- engine wiring that does not exist in this EA yet (see the g_exit.Evaluate() call site) - an
   //--- operator selecting either would otherwise believe a mechanical exit is armed when it can
   //--- never actually fire. Warned loudly and forced to the one mode that IS fully wired, rather
   //--- than silently doing nothing (code-review finding). ---
   if(InpUseVWAPExit && InpVWAPExitMode!=AX_VWAP_EXIT_CONFIRMED_CROSS)
     {
      PrintFormat("AUTOPSY X WARNING: InpVWAPExitMode=%s is not yet wired to live data in this build "
                  "(needs live-tick-price and/or structure-engine integration) - it will NEVER trigger. "
                  "Forcing CONFIRMED_CROSS, the only fully-wired mode, for this session.",
                  AxVwapExitModeToString(InpVWAPExitMode));
      g_effectiveVwapExitMode = AX_VWAP_EXIT_CONFIRMED_CROSS;
     }
   else
      g_effectiveVwapExitMode = InpVWAPExitMode;

   g_entryEngine.Configure(InpMinConfidenceToEnter);
   g_executionEligibility.Configure(1.2,0.0);
   if(!g_exec.Init(_Symbol,InpMagicNumber,InpDeviationPoints,InpMaxExecRetries))
     {
      Print("FLIPDEMON INIT FAILED: broker execution filling policy is unsupported.");
      return(INIT_FAILED);
     }
   g_exit.Configure(InpEmergencySlPoints,InpDynamicTpRR,InpBreakEvenTriggerPoints,InpBreakEvenLockPoints,
                     InpTrailStartPoints,InpTrailDistancePoints,InpMaxHoldSeconds,
                     InpSpreadAbnormalMultiplier,InpOpposingExitConfidence,InpUseAtrStops,
                     InpAtrStopMultiplier,InpMaxHoldExtensionMultiplier);
   // sniper thresholds are configured in points but tracked internally in raw price units
   g_sniper.Configure(InpSniperPullbackPoints*g_md.Point(),InpSniperResumePoints*g_md.Point(),
                       InpSniperMaxWaitSeconds,InpSniperMaxChasePoints*g_md.Point());

   g_afe.Configure(InpUseAdaptiveFlipEngine,InpAfeCautionDdPct,InpAfeDefensiveDdPct,InpAfeLockedDdPct,
                    InpAfeCautionMultiplier,InpAfeDefensiveMultiplier,InpAfeMaxRiskOfRuinPct,
                    InpAfeRuinThresholdPct,InpAfeMinExpectedValueR,InpAfeMinAccountHealth,
                    InpAfeMinTradesForStats,InpAfeAssumedRewardRisk,g_risk.RiskPercent(),
                    InpCommissionPerLot,InpSlippageToleranceBufferPts,
                    InpImpactCoefficientK,InpImpactRelevanceThresholdLots,
                    InpVWAPAlignmentBonus);
   g_afe.Init(_Symbol,InpMagicNumber);

   g_accountFlip.Configure(InpEnableAccountFlipEngine,InpAccountFlipStartingEquity,
                           InpAccountFlipTargetEquity);
   if(!g_accountFlip.Init(InpMagicNumber))
      Print("FLIPDEMON ACCOUNT GROWTH: invalid equity configuration or persistent state unavailable; new entries will fail closed.");

   g_vwap.Configure(InpVWAPMode,InpVWAPRollingBars,InpVWAPSydneyHour,InpVWAPTokyoHour,
                     InpVWAPLondonHour,InpVWAPNewYorkHour,InpVWAPDeadbandATRMult);
   if(InpUseContinuationIntelligence)
     {
      bool continuationReady=g_continuationIntelligence.Init(_Symbol,InpRegimeTimeframe,InpContinuationADXPeriod);
      g_continuationIntelligence.ConfigureTrendThreshold(InpContinuationADXTrendThreshold);
      g_continuationIntelligence.ConfigureOvernight(InpOvernightStartServerHour,InpOvernightEndServerHour);
      if(!continuationReady) Print("AUTOPSY X CONTINUATION INTELLIGENCE: ADX unavailable; evidence disabled.");
      else PrintFormat("AUTOPSY X CONTINUATION INTELLIGENCE: ADX(%d), overnight %02d:00-%02d:00 server time; evidence engines ready.",InpContinuationADXPeriod,InpOvernightStartServerHour,InpOvernightEndServerHour);
     }

   if(!g_autopsy.Init("AutopsyX_FlipDemon_Extreme",_Symbol,InpMagicNumber))
      Print("AUTOPSY X: warning - could not open trade autopsy CSV log");

   // Load and reconcile restart state before allowing any new entry. A corrupt/unreadable
   // registry does not stop management of a broker position already open, but it does keep
   // new entries disabled. An untracked live position is managed defensively, never assigned
   // a fabricated historical setup thesis.
   int recoveryMatched=0, recoveryUntracked=0, recoveryStale=0;
   g_recoveryInitialized = g_restartRecovery.Init("FlipDemon_Extreme_HFT",_Symbol,InpMagicNumber);
   if(g_recoveryInitialized)
     {
      // Keep stale setup rows until the virtual-exit ledger has reconciled any
      // closed-while-offline position against its exact broker deal history.
      g_restartRecovery.Reconcile(_Symbol,InpMagicNumber,recoveryMatched,recoveryUntracked,recoveryStale,false);
      g_recoveryReady = g_restartRecovery.IsPersisting() && recoveryUntracked==0;
      PrintFormat("FLIPDEMON RECOVERY: matched=%d untracked=%d stale_removed=%d persistence=%s entries=%s",
                  recoveryMatched,recoveryUntracked,recoveryStale,
                  g_restartRecovery.IsPersisting()?"OK":"FAILED",
                  g_recoveryReady?"ENABLED":"BLOCKED");
     }
   else
     {
      g_recoveryReady = false;
      Print("FLIPDEMON RECOVERY ERROR: registry initialization failed. Existing positions will still be managed; new entries are blocked.");
     }

   g_positionStateRegistryReady=g_positionStateRegistry.Init("FlipDemon_Extreme_HFT",_Symbol,InpMagicNumber);
   if(!g_positionStateRegistryReady || !g_positionStateRegistry.IsPersisting())
     {
      g_recoveryReady=false;
      PrintFormat("FLIPDEMON POSITION STATE ERROR: durable per-position ledger unavailable (%s); existing broker positions remain protected, new entries blocked.",
                  g_positionStateRegistry.FailureReason());
     }
   else
      PrintFormat("FLIPDEMON POSITION STATE: loaded %d durable position records.",
                  g_positionStateRegistry.Count());

   g_virtualExitInitialized=g_virtualExitRegistry.Init("FlipDemon_Extreme_HFT",_Symbol,InpMagicNumber);
   if(!g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting())
     {
      g_virtualExitReady=false;
      Print("FLIPDEMON VIRTUAL EXIT ERROR: persistent state registry unavailable; existing broker positions remain managed, new entries blocked.");
     }
   else
     {
      g_virtualExitReady=true;
      PrintFormat("FLIPDEMON VIRTUAL EXIT: registry loaded (%d records); virtual execution remains disabled in this phase.",g_virtualExitRegistry.Count());
     }

   // This ledger is independent of the legacy single-position trade journal.
   // It is required before ticket-specific hedging partial-close accounting can run.
   g_hedgingPartialLedgerReady=g_hedgingPartialCloseLedger.Init(
                                  "FlipDemon_Extreme_HFT",_Symbol,InpMagicNumber);
   if(!g_hedgingPartialLedgerReady || !g_hedgingPartialCloseLedger.IsPersisting())
     {
      g_hedgingPartialLedgerReady=false;
      Print("FLIPDEMON HEDGING PARTIAL LEDGER ERROR: durable per-position ledger unavailable; multi-position partial-close lifecycle remains quarantined.");
     }
   else
      PrintFormat("FLIPDEMON HEDGING PARTIAL LEDGER: loaded %d durable slices.",
                  g_hedgingPartialCloseLedger.Count());

   // Final liquidation accounting is separate from partial slices and the
   // legacy single-position journal. Full-close recovery remains quarantined
   // until this account-scoped ledger is available and reconciled.
   g_hedgingFullCloseLedgerReady=g_hedgingFullCloseLedger.Init(
                                    "FlipDemon_Extreme_HFT",_Symbol,InpMagicNumber);
   if(!g_hedgingFullCloseLedgerReady || !g_hedgingFullCloseLedger.IsPersisting())
     {
      g_hedgingFullCloseLedgerReady=false;
      Print("FLIPDEMON HEDGING FULL-CLOSE LEDGER ERROR: durable final-liquidation journal unavailable; multi-position full-close lifecycle remains quarantined.");
     }
   else
      PrintFormat("FLIPDEMON HEDGING FULL-CLOSE LEDGER: loaded %d final position records.",
                  g_hedgingFullCloseLedger.Count());

   g_risk.OnTickHousekeeping();
   AxReconcileExistingPosition();

   // Establish the complete broker-owned position set before trusting single-position state.
   // Multiple hedging legs remain blocked from new entries until per-position exits are evaluated.
   if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber))
     {
      g_hedgingLifecycleLock=true;
      g_pyramidReady=false;
      g_recoveryReady=false;
      PrintFormat("FLIPDEMON POSITION SNAPSHOT ERROR: %s; new execution remains blocked.",
                  g_hedgingPositionManager.FailureReason());
     }
   else if(g_hedgingPositionManager.HasMultiplePositions())
     {
      // Multi-leg recovery is now handled by the per-identifier state registry
      // and ticket-specific exit managers below. Do not convert a valid multi-leg
      // snapshot into a sticky integrity lock, or the EA could never resume after
      // the campaign naturally returns to one or zero live positions.
      g_pyramidReady=false;
      PrintFormat("FLIPDEMON HEDGING RECOVERY: %d EA-owned positions detected; each leg must pass durable state and exit-ledger reconciliation before management is enabled.",
                  g_hedgingPositionManager.Count());
      if(!g_hedgingPositionManager.AllProtected())
         PrintFormat("FLIPDEMON HEDGING WARNING: at least one live leg lacks a valid broker-side stop (%s).",
                     g_hedgingPositionManager.FailureReason());
     }
   // Rehydrate complete state by stable POSITION_IDENTIFIER. Never invent
   // historical signal metadata for a broker position absent from the ledger.
   if(g_positionStateRegistryReady && g_positionStateRegistry.IsPersisting())
     {
      for(int stateIndex=0;stateIndex<g_hedgingPositionManager.Count();stateIndex++)
        {
         SAxManagedPosition liveStatePosition;
         SAxPositionLifecycleRecord savedStateRecord;
         if(!g_hedgingPositionManager.GetAt(stateIndex,liveStatePosition) ||
            !g_positionStateRegistry.FindByIdentifier(liveStatePosition.positionIdentifier,savedStateRecord) ||
            savedStateRecord.symbol!=liveStatePosition.symbol ||
            savedStateRecord.magic!=liveStatePosition.magic)
           {
            g_recoveryReady=false;
            g_hedgingLifecycleLock=true;
            PrintFormat("FLIPDEMON POSITION STATE RECOVERY: no valid durable state for live identifier=%I64u ticket=%I64u; no synthetic state created.",
                        liveStatePosition.positionIdentifier,liveStatePosition.ticket);
            continue;
           }
         if(savedStateRecord.ticket!=liveStatePosition.ticket)
           {
            savedStateRecord.ticket=liveStatePosition.ticket;
            savedStateRecord.state.ticket=liveStatePosition.ticket;
            if(!g_positionStateRegistry.Upsert(savedStateRecord.positionIdentifier,
                 savedStateRecord.ticket,savedStateRecord.symbol,savedStateRecord.magic,
                 savedStateRecord.state))
              {
               g_recoveryReady=false;
               g_hedgingLifecycleLock=true;
               PrintFormat("FLIPDEMON POSITION STATE RECOVERY: ticket refresh could not be persisted for identifier=%I64u.",
                           savedStateRecord.positionIdentifier);
               continue;
              }
           }
         if(g_hedgingPositionManager.Count()==1)
           {
            g_posState=savedStateRecord.state;
            g_positionIdentifier=savedStateRecord.positionIdentifier;
            g_haveOpenPosition=true;
           }
        }
     }
   else if(g_hedgingPositionManager.Count()>0)
     {
      g_recoveryReady=false;
      g_hedgingLifecycleLock=true;
     }

   if(g_virtualExitInitialized && g_virtualExitRegistry.IsPersisting())
     {
      if(AxRecoverLockedHedgingFullCloseActions() &&
         AxRecoverLockedPartialCloseActions())
         AxReconcileVirtualExitTickets(true);
      else
         Print("FLIPDEMON VIRTUAL EXIT: unresolved full/partial close recovery blocked startup reconciliation; broker protection remains active.");
     }

   // Recover campaign tiers only from broker-confirmed position deals. This
   // prepares the durable ledger; scale-in execution remains separately gated.
   bool pyramidRegistryReady=g_pyramidCampaignRegistry.Init("FlipDemon_Extreme_HFT",_Symbol,InpMagicNumber);
   bool pyramidEngineReady=g_pyramidEngine.Init(_Symbol,PERIOD_H1,MODE_EMA,100);
   g_precisionEntryReady=g_precisionEntry.Init(_Symbol,InpPrecisionTimeframe,20,50,14,
                                                InpPrecisionMinBodyRatio,InpPrecisionMinRangeAtr,
                                                InpPrecisionCloseLocation);
   if(!g_precisionEntryReady)
      Print("FLIPDEMON PRECISION: M15 confirmation data unavailable; fresh entries and pyramid adds remain blocked.");
   int pyramidPositions=0,pyramidRecovered=0,pyramidUnresolved=0;
   if(pyramidRegistryReady && pyramidEngineReady)
     {
      for(int p=0;p<PositionsTotal();p++)
        {
         ulong positionTicket=PositionGetTicket(p);
         if(positionTicket==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
            continue;
         pyramidPositions++;
         bool recovered=false;
         if(g_pyramidCampaignRegistry.ReconcileLivePosition(positionTicket,recovered) && recovered)
            pyramidRecovered++;
         else
           {
            pyramidUnresolved++;
            PrintFormat("FLIPDEMON PYRAMID: position ticket=%I64u could not be reconstructed from broker deal history; scale-ins remain blocked.",
                        positionTicket);
           }
        }
     }
   g_pyramidReady=(pyramidRegistryReady && pyramidEngineReady && pyramidUnresolved==0);
   if(g_pyramidReady && !AxReconcilePyramidCampaignTickets(true))
      g_pyramidReady=false;
   PrintFormat("FLIPDEMON PYRAMID RECOVERY: registry=%s engine=%s live=%d recovered=%d unresolved=%d scale_in_state=%s",
               pyramidRegistryReady?"OK":"FAILED",pyramidEngineReady?"OK":"FAILED",
               pyramidPositions,pyramidRecovered,pyramidUnresolved,
               g_pyramidReady?"READY":"BLOCKED");

   if(InpShowDashboard)
      g_dash.Init(_Symbol);
   // Recovery must keep running even when the optional dashboard is disabled.
   // IQ200 persistence and recovery require the timer even when the dashboard is hidden.
   EventSetTimer(1);

   g_engineState = AX_ENGINE_ACTIVE;
   PrintFormat("AUTOPSY X FLIPDEMON EXTREME initialized on %s | mode=%d | risk=%.2f%%",
               _Symbol,(int)InpMode,g_risk.RiskPercent());
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   datetime gapSummaryTime=TimeTradeServer();
   if(gapSummaryTime<=0) gapSummaryTime=TimeCurrent();
   if(g_gapAnalyticsReady)
      g_gapAnalytics.WriteSummary(gapSummaryTime);
   g_gapAnalytics.Deinit();
   g_continuationIntelligence.Deinit();
   g_gapJournal.Deinit();
   g_marketSnapshotRecorder.Deinit();
   g_advancedSessionOrb.Cleanup();
   EventKillTimer();
   g_executionLatency.Report();
   g_executionQualityJournal.Deinit();
   if(g_iq200TelemetryReady)
     {
      g_iq200Telemetry.Flush(AX_IQ200_QUEUE_CAPACITY);
      PrintFormat("FLIPDEMON BROKER ENTRY THROUGHPUT: confirmed_deal_slices=%I64u confirmed_volume=%.4f peak_deal_slices_per_second=%I64u first_deal_time_msc=%I64d last_deal_time_msc=%I64d. This is broker-confirmed entry-deal throughput, not order-request rate or completed-order count.",
                  g_iq200Telemetry.ConfirmedEntryDealCount(),
                  g_iq200Telemetry.ConfirmedEntryVolume(),
                  g_iq200Telemetry.PeakConfirmedEntryDealsPerSecond(),
                  g_iq200Telemetry.FirstConfirmedEntryTimeMsc(),
                  g_iq200Telemetry.LastConfirmedEntryTimeMsc());
     }
   g_iq200Telemetry.Deinit();
   g_distributedRiskCoordinator.Shutdown();
   if(!g_accountRiskCoordinator.Release())
      Print("FLIPDEMON COORDINATION ERROR: account mutex release failed during deinitialization.");
   if(InpShowDashboard)
      g_dash.RemoveAll();
   g_regimeJournal.Deinit();
   g_autopsy.ReportVWAPAlignment(InpMinTradesForValidation);
   g_autopsy.Deinit();
   g_regime.Deinit();
   g_regimeHtf.Deinit();
   g_volatility.Deinit();
   g_macroRegime.Deinit();
   g_heatmap.Deinit();
   g_alphaTrend.Deinit();
   g_mfi.Deinit();
   g_slingshot.Deinit();
   g_chandelier.Deinit();
   g_precisionEntry.Release();
   g_pyramidEngine.Release();
   g_pyramidCampaignRegistry.Deinit();
  }

// Evaluate the current tick's blended signal against every independently recovered
// hedging leg. Durable state supplies each leg's own direction and entry thesis.
// At most one exact-ticket close is issued per tick.
bool AxManageHedgingSignalExitTickets(const SAxScore &score,const bool vwapExitCheckDue,
                                      bool &closeAttempted)
  {
   closeAttempted=false;
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_positionStateRegistryReady || !g_positionStateRegistry.IsPersisting() ||
      !g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting() ||
      !g_hedgingFullCloseLedgerReady || !g_hedgingFullCloseLedger.IsPersisting())
      return(false);

   for(int i=0;i<g_hedgingPositionManager.Count();i++)
     {
      SAxManagedPosition live;
      SAxPositionLifecycleRecord saved;
      double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(!g_hedgingPositionManager.GetAt(i,live) ||
         !g_positionStateRegistry.FindByIdentifier(live.positionIdentifier,saved) ||
         !saved.state.active || saved.positionIdentifier!=live.positionIdentifier ||
         saved.ticket!=live.ticket || saved.state.ticket!=live.ticket ||
         saved.symbol!=live.symbol || saved.magic!=live.magic ||
         saved.state.dir!=live.direction ||
         tickSize<=0.0 ||
         MathAbs(saved.state.entryPrice-live.openPrice)>MathMax(tickSize*2.0,0.0000001))
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING SIGNAL EXIT: exact durable state mismatch for position id=%I64u ticket=%I64u; no close request sent.",
                     live.positionIdentifier,live.ticket);
         return(false);
        }

      const double currentPrice=(live.direction==AX_DIR_BUY)
                                ?g_md.CurrentBid():g_md.CurrentAsk();
      const ENUM_AX_VWAP_EXIT_MODE effectiveMode=
         InpUseVWAPExit?g_effectiveVwapExitMode:AX_VWAP_EXIT_OFF;
      SAxExitDecision decision=g_exit.Evaluate(saved.state,g_md,g_mom,g_micro,score,
         InpMaxSpreadPoints,effectiveMode,vwapExitCheckDue,g_vwapValue,
         g_lastClosedBarClose,currentPrice,false);
      if(!decision.shouldExit) continue;

      closeAttempted=true;
      PrintFormat("FLIPDEMON HEDGING SIGNAL EXIT: reason=%d direction=%s ticket=%I64u identifier=%I64u; closing only this leg.",
                  (int)decision.reason,
                  live.direction==AX_DIR_BUY?"BUY":"SELL",
                  live.ticket,live.positionIdentifier);
      if(!AxCloseHedgingPositionByTicket(live))
        {
         g_engineState=AX_ENGINE_PAUSED;
         return(false);
        }
      return(true);
     }
   return(true);
  }

// Forward declaration: the exact-ticket close implementation follows the
// campaign-level signal and risk-shutdown controllers.
bool AxCloseHedgingPositionByTicket(const SAxManagedPosition &live);

// Close one exact hedging leg during an account-level kill or daily-loss shutdown.
// The next tick refreshes the broker set and advances to the next leg.
bool AxCloseOneHedgingPositionForRiskShutdown(void)
  {
   if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber))
     {
      g_hedgingLifecycleLock=true;
      g_recoveryReady=false;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON HEDGING RISK SHUTDOWN: broker position snapshot incomplete; no close request sent.");
      return(false);
     }
   if(g_hedgingPositionManager.Count()==0) return(true);
   SAxManagedPosition live;
   if(!g_hedgingPositionManager.GetAt(0,live))
      return(false);
   return(AxCloseHedgingPositionByTicket(live));
  }

// Manage break-even independently for every leg in a hedging campaign.
// The single-position ExitEngine remains responsible for the one-position path.
// Exact-ticket full liquidation entry point used by both signal and risk-shutdown
// controllers. Every close is guarded by durable action state and broker confirmation.
bool AxCloseHedgingPositionByTicket(const SAxManagedPosition &live)
  {
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting() ||
      !g_hedgingFullCloseLedgerReady || !g_hedgingFullCloseLedger.IsPersisting() ||
      live.ticket==0 || live.positionIdentifier==0 || live.symbol!=_Symbol ||
      live.magic!=InpMagicNumber || !PositionSelectByTicket(live.ticket) ||
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=live.positionIdentifier ||
      (ulong)PositionGetInteger(POSITION_MAGIC)!=live.magic ||
      PositionGetString(POSITION_SYMBOL)!=live.symbol)
      return(false);

   SAxVirtualExitRecord saved;
   if(!g_virtualExitRegistry.Find(live.positionIdentifier,saved) ||
      saved.actionLocked || saved.ticket!=live.ticket || saved.symbol!=live.symbol ||
      saved.dir!=live.direction || saved.entryTime<=0 || saved.entryPrice<=0.0 ||
      saved.entryVolume<=0.0)
      return(false);

   const double baselineVolume=PositionGetDouble(POSITION_VOLUME);
   const double volumeStep=SymbolInfoDouble(live.symbol,SYMBOL_VOLUME_STEP);
   const double volumeTolerance=MathMax(volumeStep*0.51,0.0000001);
   if(baselineVolume<=0.0 || MathAbs(baselineVolume-live.volume)>volumeTolerance)
      return(false);

   if(!g_virtualExitRegistry.BeginFullCloseAction(live.positionIdentifier,baselineVolume) ||
      !g_virtualExitRegistry.IsPersisting())
      return(false);
   SAxVirtualExitRecord actionState;
   if(!g_virtualExitRegistry.Find(live.positionIdentifier,actionState) ||
      !actionState.actionLocked || actionState.actionCode!=4 ||
      MathAbs(actionState.actionBaselineVolume-baselineVolume)>volumeTolerance ||
      actionState.actionStartedAt<=0)
      return(false);

   string closeError="";
   bool outcomeUncertain=false;
   if(!g_exec.ClosePositionByTicket(live.symbol,live.ticket,live.positionIdentifier,
                                    live.magic,closeError,outcomeUncertain))
     {
      if(!outcomeUncertain)
        {
         if(!g_virtualExitRegistry.ResolveAction(live.positionIdentifier,4) ||
            !g_virtualExitRegistry.IsPersisting())
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_engineState=AX_ENGINE_PAUSED;
            return(false);
           }
         PrintFormat("FLIPDEMON HEDGING FULL CLOSE: broker definitively rejected ticket=%I64u (%s).",
                     live.ticket,closeError);
         return(true);
        }
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_recoveryReady=false;
      g_accountRiskReconciliationPending=true;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON HEDGING FULL-CLOSE QUARANTINE: ticket=%I64u id=%I64u outcome uncertain; action lock retained, no retry (%s).",
                  live.ticket,live.positionIdentifier,closeError);
      return(false);
     }

   if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber))
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_recoveryReady=false;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON HEDGING FULL-CLOSE: post-request broker snapshot incomplete; action lock retained.");
      return(false);
     }
   SAxManagedPosition stillLive;
   if(g_hedgingPositionManager.FindByIdentifier(live.positionIdentifier,stillLive))
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_recoveryReady=false;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON HEDGING FULL-CLOSE QUARANTINE: broker reported success but exact position id=%I64u is still present.",
                  live.positionIdentifier);
      return(false);
     }

   if(!AxFinalizeHedgingFullClose(actionState))
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_recoveryReady=false;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON HEDGING FULL-CLOSE QUARANTINE: final journal/registry commit incomplete for id=%I64u; action evidence retained.",
                  live.positionIdentifier);
      return(false);
     }
   return(true);
  }

// Enforce each hedging leg's persisted virtual SL/TP through its exact-ticket
// full-close transaction path. One close is attempted per tick; the broker
// snapshot is refreshed by the close routine before another leg can be considered.
bool AxManageHedgingVirtualExitTickets(void)
  {
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting() ||
      !g_hedgingFullCloseLedgerReady || !g_hedgingFullCloseLedger.IsPersisting())
      return(false);

   for(int i=0;i<g_hedgingPositionManager.Count();i++)
     {
      SAxManagedPosition live;
      if(!g_hedgingPositionManager.GetAt(i,live))
         return(false);
      SAxPositionLifecycleRecord positionState;
      if(!g_positionStateRegistryReady ||
         !g_positionStateRegistry.FindByIdentifier(live.positionIdentifier,positionState) ||
         !positionState.state.active || positionState.ticket!=live.ticket ||
         positionState.symbol!=live.symbol || positionState.magic!=live.magic ||
         positionState.state.dir!=live.direction)
         return(false);

      SAxVirtualExitRecord saved;
      if(!g_virtualExitRegistry.Find(live.positionIdentifier,saved) ||
         saved.actionLocked || saved.ticket!=live.ticket ||
         saved.symbol!=live.symbol || saved.dir!=live.direction ||
         saved.virtualSlPrice<=0.0)
         return(false);

      MqlTick quote;
      if(!SymbolInfoTick(live.symbol,quote) || quote.bid<=0.0 ||
         quote.ask<quote.bid || quote.ask<=0.0)
         return(false);

      bool stopHit=(live.direction==AX_DIR_BUY)
                   ?(quote.bid<=saved.virtualSlPrice)
                   :(live.direction==AX_DIR_SELL)
                     ?(quote.ask>=saved.virtualSlPrice):false;
      bool targetHit=(saved.virtualTpPrice>0.0 &&
                      ((live.direction==AX_DIR_BUY && quote.bid>=saved.virtualTpPrice) ||
                       (live.direction==AX_DIR_SELL && quote.ask<=saved.virtualTpPrice)));
      if(!stopHit && !targetHit) continue;

      if(!AxCloseHedgingPositionByTicket(live))
         return(false);

      // The close helper can return after a definitive broker rejection.
      // Verify the exact stable identifier before treating the leg as closed.
      if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber))
         return(false);
      SAxManagedPosition stillLive;
      if(g_hedgingPositionManager.FindByIdentifier(live.positionIdentifier,stillLive))
        {
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON HEDGING VIRTUAL EXIT: broker did not close identifier=%I64u on this attempt; no duplicate request issued in this tick.",
                        live.positionIdentifier);
         return(true);
        }
      PrintFormat("FLIPDEMON HEDGING VIRTUAL EXIT CONFIRMED: identifier=%I64u ticket=%I64u reason=%s.",
                  live.positionIdentifier,live.ticket,stopHit?"VIRTUAL_SL":"VIRTUAL_TP");
      return(true);
     }
   return(true);
  }

// Execute one profitable-only scale-out per hedging leg. This path is deliberately
// separate from the legacy g_posState journal and is only called for multi-leg accounts.
bool AxManageHedgingPartialCloseTickets(void)
  {
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting() ||
      !g_hedgingPartialLedgerReady || !g_hedgingPartialCloseLedger.IsPersisting())
      return(false);
   if(!InpEnablePartialTP) return(true);
   if(InpPartialTriggerRR<=0.0 || InpPartialClosePercent<=0.0 ||
      InpPartialClosePercent>=100.0)
     {
      Print("FLIPDEMON HEDGING PARTIAL: invalid partial-close trigger or percentage; campaign quarantined.");
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      return(false);
     }

   const double volumeStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   const double minimumVolume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   const double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(volumeStep<=0.0 || minimumVolume<=0.0 || tickSize<=0.0)
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON HEDGING PARTIAL: broker volume/tick metadata unavailable; campaign quarantined.");
      return(false);
     }
   const double volumeTolerance=MathMax(volumeStep*0.5,0.0000001);

   for(int i=0;i<g_hedgingPositionManager.Count();i++)
     {
      SAxManagedPosition live;
      if(!g_hedgingPositionManager.GetAt(i,live))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: broker snapshot row %d unavailable; campaign quarantined.",i);
         return(false);
        }

      SAxVirtualExitRecord saved;
      if(!g_virtualExitRegistry.Find(live.positionIdentifier,saved) ||
         saved.actionLocked || saved.symbol!=live.symbol || saved.dir!=live.direction ||
         saved.ticket!=live.ticket || saved.entryTime<=0 || saved.entryPrice<=0.0 ||
         saved.entryVolume<=0.0 || saved.originalRiskDistance<=0.0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: durable entry state mismatch or locked action, ticket=%I64u id=%I64u; campaign quarantined.",
                     live.ticket,live.positionIdentifier);
         return(false);
        }

      if(!live.hasValidBrokerStop)
        {
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON HEDGING PARTIAL: ticket=%I64u lacks broker stop; scale-out skipped while virtual exit remains active.",live.ticket);
         continue;
        }
      // This phase deliberately permits one scale-out per leg. A completed slice
      // must still match its independent ledger row before it is treated as settled.
      if(saved.partialCloseCount>0 || saved.partialClosedVolume>volumeTolerance ||
         saved.partialLastDealTicket>0)
        {
         SAxPartialCloseLedgerRecord accounted;
         if(saved.partialCloseCount!=1 || saved.partialLastDealTicket==0 ||
            !g_hedgingPartialCloseLedger.Find(live.positionIdentifier,
                                               saved.partialLastDealTicket,accounted) ||
            accounted.symbol!=saved.symbol || accounted.magic!=live.magic ||
            accounted.direction!=saved.dir ||
            MathAbs(accounted.entryPrice-saved.entryPrice)>tickSize*0.51 ||
            MathAbs(accounted.entryVolume-saved.entryVolume)>volumeTolerance ||
            MathAbs(accounted.closedVolume-saved.partialClosedVolume)>volumeTolerance ||
            accounted.closedVolume<=0.0 || accounted.closedVolume>=saved.entryVolume)
           {
            g_virtualExitReady=false;
            g_hedgingLifecycleLock=true;
            g_engineState=AX_ENGINE_PAUSED;
            PrintFormat("FLIPDEMON HEDGING PARTIAL: completed slice does not match per-leg ledger for id=%I64u; campaign quarantined.",
                        live.positionIdentifier);
            return(false);
           }
         continue;
        }

      if(!PositionSelectByTicket(live.ticket) ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=live.positionIdentifier ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber ||
         PositionGetString(POSITION_SYMBOL)!=live.symbol)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: exact position identity unavailable, ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      const double brokerVolume=PositionGetDouble(POSITION_VOLUME);
      if(MathAbs(brokerVolume-live.volume)>volumeTolerance ||
         MathAbs(brokerVolume-saved.entryVolume)>volumeTolerance ||
         MathAbs(PositionGetDouble(POSITION_PRICE_OPEN)-saved.entryPrice)>tickSize*0.51)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: live volume/entry differs from durable baseline, ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      MqlTick quote;
      if(!SymbolInfoTick(live.symbol,quote) || quote.bid<=0.0 ||
         quote.ask<quote.bid || quote.ask<=0.0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: quote unavailable for ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      const double executablePrice=(live.direction==AX_DIR_BUY)?quote.bid:quote.ask;
      const double favorableMove=(live.direction==AX_DIR_BUY)
                                 ?executablePrice-saved.entryPrice
                                 :saved.entryPrice-executablePrice;
      const double achievedRR=favorableMove/saved.originalRiskDistance;
      if(!MathIsValidNumber(achievedRR) || achievedRR<InpPartialTriggerRR)
         continue;

      const double requestedRaw=brokerVolume*InpPartialClosePercent/100.0;
      double closeVolume=MathFloor(requestedRaw/volumeStep+1e-9)*volumeStep;
      closeVolume=NormalizeDouble(closeVolume,8);
      const double residualVolume=brokerVolume-closeVolume;
      if(closeVolume<minimumVolume || residualVolume<minimumVolume ||
         !MathIsValidNumber(closeVolume) || closeVolume<=0.0)
        {
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON HEDGING PARTIAL: scale-out skipped for ticket=%I64u; broker minimum would be violated (close=%.8f residual=%.8f min=%.8f).",
                        live.ticket,closeVolume,residualVolume,minimumVolume);
         continue;
        }

      if(!g_virtualExitRegistry.BeginPartialCloseAction(live.positionIdentifier,brokerVolume) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: durable action lock failed for ticket=%I64u; no broker request sent.",live.ticket);
         return(false);
        }
      SAxVirtualExitRecord actionState;
      if(!g_virtualExitRegistry.Find(live.positionIdentifier,actionState) ||
         !actionState.actionLocked || actionState.actionCode!=3 ||
         actionState.actionBaselineVolume<=0.0 || actionState.actionStartedAt<=0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: persisted action lock could not be reloaded for id=%I64u.",live.positionIdentifier);
         return(false);
        }

      string closeError="";
      bool outcomeUncertain=false;
      if(!g_exec.ClosePartial(live.symbol,live.ticket,live.positionIdentifier,
                              live.magic,closeVolume,closeError,outcomeUncertain))
        {
         if(!outcomeUncertain)
           {
            // A definite rejection may release only its own lock. Do not keep
            // retrying in this tick; a later fresh quote can re-evaluate it.
            if(!g_virtualExitRegistry.ResolveAction(live.positionIdentifier,3) ||
               !g_virtualExitRegistry.IsPersisting())
              {
               g_virtualExitReady=false;
               g_hedgingLifecycleLock=true;
               g_engineState=AX_ENGINE_PAUSED;
               PrintFormat("FLIPDEMON HEDGING PARTIAL: rejected request lock could not be cleared, ticket=%I64u.",live.ticket);
               return(false);
              }
            if(InpVerboseLogging)
               PrintFormat("FLIPDEMON HEDGING PARTIAL: broker rejected ticket=%I64u scale-out (%s).",
                           live.ticket,closeError);
            return(true);
           }

         // Ambiguous outcomes retain actionCode=3. Startup/tick recovery must
         // reconcile the exact stable identifier and deal history before retry.
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_accountRiskReconciliationPending=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL QUARANTINE: ticket=%I64u id=%I64u outcome uncertain; no second close request (%s).",
                     live.ticket,live.positionIdentifier,closeError);
         return(false);
        }

      if(!PositionSelectByTicket(live.ticket) ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=live.positionIdentifier ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=live.magic ||
         PositionGetString(POSITION_SYMBOL)!=live.symbol)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL QUARANTINE: accepted scale-out lost exact live ticket identity=%I64u; action lock retained.",
                     live.positionIdentifier);
         return(false);
        }

      const double remainingVolume=PositionGetDouble(POSITION_VOLUME);
      const double actualClosed=brokerVolume-remainingVolume;
      double closePrice=0.0,grossProfit=0.0,commission=0.0,swap=0.0,historyClosedVolume=0.0;
      datetime closeTime=0;
      ulong lastDeal=saved.partialLastDealTicket;
      if(remainingVolume<=0.0 || actualClosed<=volumeTolerance ||
         MathAbs(actualClosed-closeVolume)>volumeTolerance ||
         !AxFetchCloseFinancialsByIdentifier(live.positionIdentifier,live.symbol,live.magic,
                                             live.direction,saved.partialLastDealTicket,
                                             closePrice,grossProfit,commission,swap,
                                             closeTime,lastDeal,historyClosedVolume) ||
         lastDeal<=saved.partialLastDealTicket || closeTime<actionState.actionStartedAt ||
         MathAbs(historyClosedVolume-actualClosed)>volumeTolerance ||
         saved.partialClosedVolume+historyClosedVolume>=saved.entryVolume-volumeTolerance)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL QUARANTINE: broker reduction/history mismatch for id=%I64u; durable action lock retained.",
                     live.positionIdentifier);
         return(false);
        }

      if(!AxRecordHedgingPartialCloseLedger(saved,closePrice,grossProfit,commission,swap,
                                             closeTime,lastDeal,historyClosedVolume) ||
         !g_virtualExitRegistry.RecordPartialClose(live.positionIdentifier,historyClosedVolume,lastDeal) ||
         !g_virtualExitRegistry.IsPersisting() ||
         !g_virtualExitRegistry.ResolveAction(live.positionIdentifier,3) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_recoveryReady=false;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL QUARANTINE: ledger/registry commit incomplete for id=%I64u; action lock retained for recovery.",
                     live.positionIdentifier);
         return(false);
        }

      // Update the complete position record only after broker volume, deal
      // history, partial ledger and virtual-exit cursor have all reconciled.
      SAxPositionLifecycleRecord positionState;
      if(!g_positionStateRegistryReady ||
         !g_positionStateRegistry.FindByIdentifier(live.positionIdentifier,positionState) ||
         positionState.ticket!=live.ticket || !positionState.state.active ||
         positionState.symbol!=live.symbol || positionState.magic!=live.magic)
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: durable position-state row missing for id=%I64u; lifecycle quarantined.",
                     live.positionIdentifier);
         return(false);
        }
      positionState.state.lots=remainingVolume;
      positionState.state.ticket=live.ticket;
      positionState.state.partialTaken=true;
      positionState.state.lastAccountedDealTicket=lastDeal;
      positionState.state.initialSlPrice=live.stopLoss;
      positionState.state.initialTpPrice=live.takeProfit;
      if(!g_positionStateRegistry.Upsert(live.positionIdentifier,live.ticket,
                                          live.symbol,live.magic,positionState.state) ||
         !g_positionStateRegistry.IsPersisting())
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING PARTIAL: updated position state could not be persisted for id=%I64u; lifecycle quarantined.",
                     live.positionIdentifier);
         return(false);
        }

      PrintFormat("FLIPDEMON HEDGING PARTIAL: ticket=%I64u id=%I64u RR=%.2f closed=%.8f remaining=%.8f deal=%I64u; per-leg ledger durable.",
                  live.ticket,live.positionIdentifier,achievedRR,historyClosedVolume,
                  remainingVolume,lastDeal);
      // One scale-out per leg per lifecycle phase. The caller refreshes the full
      // broker snapshot after this manager returns.
      return(true);
     }
   return(true);
  }

bool AxManageHedgingBreakEvenTickets(void)
  {
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting())
      return(false);

   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   long digits=SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   long stopsLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   if(point<=0.0 || tickSize<=0.0 || digits<0 || stopsLevel<0 || freezeLevel<0 ||
      InpBreakEvenTriggerPoints<=0.0 || InpBreakEvenLockPoints<0.0)
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON HEDGING BREAK-EVEN: invalid symbol or trigger metadata; campaign quarantined.");
      return(false);
     }

   for(int i=0;i<g_hedgingPositionManager.Count();i++)
     {
      SAxManagedPosition live;
      if(!g_hedgingPositionManager.GetAt(i,live))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: broker snapshot row %d unavailable; campaign quarantined.",i);
         return(false);
        }

      SAxVirtualExitRecord saved;
      if(!g_virtualExitRegistry.Find(live.positionIdentifier,saved) ||
         saved.actionLocked || saved.symbol!=live.symbol ||
         saved.dir!=live.direction || saved.ticket!=live.ticket ||
         saved.originalRiskDistance<=0.0 || saved.initialSlPrice<=0.0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: durable state mismatch or unresolved action, ticket=%I64u id=%I64u; campaign quarantined.",
                     live.ticket,live.positionIdentifier);
         return(false);
        }
      if(!live.hasValidBrokerStop)
        {
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: ticket=%I64u lacks broker stop; virtual exit remains active, broker protection is absent.",live.ticket);
         continue;
        }
      if(saved.breakEvenDone) continue;

      MqlTick quote;
      if(!SymbolInfoTick(live.symbol,quote) || quote.bid<=0.0 ||
         quote.ask<quote.bid || quote.ask<=0.0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: quote unavailable for ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      double exitPrice=(live.direction==AX_DIR_BUY)?quote.bid:quote.ask;
      double favorablePoints=(live.direction==AX_DIR_BUY)
                             ?(exitPrice-live.openPrice)/point
                             :(live.openPrice-exitPrice)/point;
      if(!MathIsValidNumber(favorablePoints) ||
         favorablePoints<InpBreakEvenTriggerPoints)
         continue;

      double rawCandidate=(live.direction==AX_DIR_BUY)
                          ?live.openPrice+InpBreakEvenLockPoints*point
                          :live.openPrice-InpBreakEvenLockPoints*point;
      double candidate=(live.direction==AX_DIR_BUY)
                       ?MathFloor(rawCandidate/tickSize+1e-10)*tickSize
                       :MathCeil(rawCandidate/tickSize-1e-10)*tickSize;
      candidate=NormalizeDouble(candidate,(int)digits);
      if(!MathIsValidNumber(candidate) || candidate<=0.0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: invalid candidate for ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      // Never replace an already tighter broker stop or active trailing level.
      if((live.direction==AX_DIR_BUY && candidate<=live.stopLoss+tickSize*0.5) ||
         (live.direction==AX_DIR_SELL && candidate>=live.stopLoss-tickSize*0.5))
         continue;
      if(saved.trailingActive &&
         ((live.direction==AX_DIR_BUY && candidate<saved.trailingStopPrice-tickSize*0.5) ||
          (live.direction==AX_DIR_SELL && candidate>saved.trailingStopPrice+tickSize*0.5)))
         continue;

      double reference=(live.direction==AX_DIR_BUY)?quote.bid:quote.ask;
      double stopDistance=(double)stopsLevel*point;
      double freezeDistance=(double)freezeLevel*point;
      if((live.direction==AX_DIR_BUY &&
          (candidate>=quote.bid || quote.bid-candidate+tickSize*1e-8<stopDistance)) ||
         (live.direction==AX_DIR_SELL &&
          (candidate<=quote.ask || candidate-quote.ask+tickSize*1e-8<stopDistance)))
         continue;
      if(freezeDistance>0.0 && live.stopLoss>0.0 &&
         MathAbs(reference-live.stopLoss)<=freezeDistance)
         continue;

      // Action code 1 is the existing durable break-even action code.
      if(!g_virtualExitRegistry.BeginAction(live.positionIdentifier,1) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: could not persist action lock, ticket=%I64u; no broker request sent.",
                     live.ticket);
         return(false);
        }

      string modifyError="";
      if(!g_exec.ModifyStopsByTicket(live.symbol,live.ticket,live.positionIdentifier,
                                     live.magic,candidate,live.takeProfit,modifyError))
        {
         // The outcome is treated as ambiguous. Keep the durable lock and never
         // issue a second stop request until broker/history reconciliation.
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN UNCERTAIN: ticket=%I64u id=%I64u; action lock retained (%s).",
                     live.ticket,live.positionIdentifier,modifyError);
         return(false);
        }

      if(!PositionSelectByTicket(live.ticket) ||
         PositionGetString(POSITION_SYMBOL)!=live.symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=live.positionIdentifier ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=live.magic)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: accepted request but exact position identity could not be reverified, ticket=%I64u; action lock retained.",
                     live.ticket);
         return(false);
        }

      double confirmedSl=PositionGetDouble(POSITION_SL);
      double confirmedTp=PositionGetDouble(POSITION_TP);
      bool stopConfirmed=(live.direction==AX_DIR_BUY)
                         ?(confirmedSl+tickSize*0.5>=candidate &&
                           confirmedSl+tickSize*0.5>=live.stopLoss)
                         :(confirmedSl-tickSize*0.5<=candidate &&
                           confirmedSl-tickSize*0.5<=live.stopLoss);
      bool tpPreserved=MathAbs(confirmedTp-live.takeProfit)<=tickSize*0.5;
      if(!stopConfirmed || !tpPreserved ||
         !g_virtualExitRegistry.RecordBreakEven(live.positionIdentifier,confirmedSl) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: broker result failed stop/TP or durable-state verification, ticket=%I64u; action lock retained.",
                     live.ticket);
         return(false);
        }

      if(!g_virtualExitRegistry.ResolveAction(live.positionIdentifier,1) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: confirmed stop but action lock release failed, ticket=%I64u; campaign quarantined.",
                     live.ticket);
         return(false);
        }

      SAxPositionLifecycleRecord positionState;
      if(!g_positionStateRegistryReady ||
         !g_positionStateRegistry.FindByIdentifier(live.positionIdentifier,positionState) ||
         positionState.ticket!=live.ticket || !positionState.state.active ||
         positionState.symbol!=live.symbol || positionState.magic!=live.magic)
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: durable position-state row missing for id=%I64u.",
                     live.positionIdentifier);
         return(false);
        }
      positionState.state.initialSlPrice=confirmedSl;
      positionState.state.breakEvenDone=true;
      positionState.state.ticket=live.ticket;
      if(!g_positionStateRegistry.Upsert(live.positionIdentifier,live.ticket,
                                          live.symbol,live.magic,positionState.state) ||
         !g_positionStateRegistry.IsPersisting())
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING BREAK-EVEN: state checkpoint failed for id=%I64u.",
                     live.positionIdentifier);
         return(false);
        }

      PrintFormat("FLIPDEMON HEDGING BREAK-EVEN CONFIRMED: ticket=%I64u id=%I64u stop=%.*f.",
                  live.ticket,live.positionIdentifier,(int)digits,confirmedSl);
     }
   return(true);
  }

// Advance each hedging leg's trailing stop independently. This manager only
// tightens an existing broker stop and records progress after exact-ticket
// broker confirmation. Ambiguous outcomes retain the durable action lock.
bool AxManageHedgingTrailingTickets(void)
  {
   if(!g_hedgingPositionManager.IsComplete() ||
      !g_virtualExitInitialized || !g_virtualExitRegistry.IsPersisting())
      return(false);

   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   long digits=SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   long stopsLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   if(point<=0.0 || tickSize<=0.0 || digits<0 || stopsLevel<0 || freezeLevel<0 ||
      InpTrailStartPoints<=0.0 || InpTrailDistancePoints<=0.0)
     {
      g_virtualExitReady=false;
      g_hedgingLifecycleLock=true;
      g_engineState=AX_ENGINE_PAUSED;
      Print("FLIPDEMON HEDGING TRAIL: invalid symbol metadata or trail configuration; campaign quarantined.");
      return(false);
     }

   for(int i=0;i<g_hedgingPositionManager.Count();i++)
     {
      SAxManagedPosition live;
      if(!g_hedgingPositionManager.GetAt(i,live))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: broker snapshot row %d unavailable; campaign quarantined.",i);
         return(false);
        }

      SAxVirtualExitRecord saved;
      if(!g_virtualExitRegistry.Find(live.positionIdentifier,saved) ||
         saved.actionLocked || saved.symbol!=live.symbol ||
         saved.dir!=live.direction || saved.ticket!=live.ticket ||
         saved.originalRiskDistance<=0.0 )
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: durable state mismatch or unresolved action, ticket=%I64u id=%I64u; campaign quarantined.",
                     live.ticket,live.positionIdentifier);
         return(false);
        }

      if(!live.hasValidBrokerStop)
        {
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON HEDGING TRAIL: ticket=%I64u lacks broker stop; trailing modification skipped while virtual exit remains active.",live.ticket);
         continue;
        }
      MqlTick quote;
      if(!SymbolInfoTick(live.symbol,quote) || quote.bid<=0.0 ||
         quote.ask<quote.bid || quote.ask<=0.0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: quote unavailable for ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      double exitPrice=(live.direction==AX_DIR_BUY)?quote.bid:quote.ask;
      double favorablePoints=(live.direction==AX_DIR_BUY)
                             ?(exitPrice-live.openPrice)/point
                             :(live.openPrice-exitPrice)/point;
      if(!MathIsValidNumber(favorablePoints) ||
         favorablePoints<InpTrailStartPoints)
         continue;

      double rawCandidate=(live.direction==AX_DIR_BUY)
                          ?quote.bid-InpTrailDistancePoints*point
                          :quote.ask+InpTrailDistancePoints*point;
      double candidate=(live.direction==AX_DIR_BUY)
                       ?MathFloor(rawCandidate/tickSize+1e-10)*tickSize
                       :MathCeil(rawCandidate/tickSize-1e-10)*tickSize;
      candidate=NormalizeDouble(candidate,(int)digits);
      if(!MathIsValidNumber(candidate) || candidate<=0.0)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: invalid candidate for ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      // The trail must only move in the favorable direction. It may never
      // loosen the broker stop, the break-even stop, or a prior trail.
      if(live.direction==AX_DIR_BUY)
        {
         if(candidate<=live.stopLoss+tickSize*0.5) continue;
         if(saved.breakEvenDone && candidate<live.openPrice+InpBreakEvenLockPoints*point-tickSize*0.5)
            continue;
         if(saved.trailingActive && candidate<=saved.trailingStopPrice+tickSize*0.5)
            continue;
         if(candidate>=quote.bid ||
            quote.bid-candidate+tickSize*1e-8<(double)stopsLevel*point)
            continue;
        }
      else if(live.direction==AX_DIR_SELL)
        {
         if(candidate>=live.stopLoss-tickSize*0.5) continue;
         if(saved.breakEvenDone && candidate>live.openPrice-InpBreakEvenLockPoints*point+tickSize*0.5)
            continue;
         if(saved.trailingActive && candidate>=saved.trailingStopPrice-tickSize*0.5)
            continue;
         if(candidate<=quote.ask ||
            candidate-quote.ask+tickSize*1e-8<(double)stopsLevel*point)
            continue;
        }
      else
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: unsupported direction for ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      double reference=(live.direction==AX_DIR_BUY)?quote.bid:quote.ask;
      double freezeDistance=(double)freezeLevel*point;
      if(freezeDistance>0.0 &&
         MathAbs(reference-live.stopLoss)<=freezeDistance)
         continue;

      // Action code 2 is reserved for ticket-specific trailing modifications.
      if(!g_virtualExitRegistry.BeginAction(live.positionIdentifier,2) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: could not persist action lock, ticket=%I64u; no broker request sent.",live.ticket);
         return(false);
        }

      string modifyError="";
      if(!g_exec.ModifyStopsByTicket(live.symbol,live.ticket,live.positionIdentifier,
                                     live.magic,candidate,live.takeProfit,modifyError))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL UNCERTAIN: ticket=%I64u id=%I64u; action lock retained (%s).",
                     live.ticket,live.positionIdentifier,modifyError);
         return(false);
        }

      if(!PositionSelectByTicket(live.ticket) ||
         PositionGetString(POSITION_SYMBOL)!=live.symbol ||
         (ulong)PositionGetInteger(POSITION_IDENTIFIER)!=live.positionIdentifier ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=live.magic)
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: accepted request but exact position identity could not be reverified, ticket=%I64u; action lock retained.",live.ticket);
         return(false);
        }

      double confirmedSl=PositionGetDouble(POSITION_SL);
      double confirmedTp=PositionGetDouble(POSITION_TP);
      bool stopConfirmed=(live.direction==AX_DIR_BUY)
                         ?(confirmedSl+tickSize*0.5>=candidate &&
                           confirmedSl>live.stopLoss)
                         :(confirmedSl-tickSize*0.5<=candidate &&
                           confirmedSl<live.stopLoss);
      bool tpPreserved=MathAbs(confirmedTp-live.takeProfit)<=tickSize*0.5;
      if(!stopConfirmed || !tpPreserved ||
         !g_virtualExitRegistry.RecordTrailingStop(live.positionIdentifier,confirmedSl) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: broker result failed stop/TP or durable-state verification, ticket=%I64u; action lock retained.",live.ticket);
         return(false);
        }

      if(!g_virtualExitRegistry.ResolveAction(live.positionIdentifier,2) ||
         !g_virtualExitRegistry.IsPersisting())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: confirmed stop but action lock release failed, ticket=%I64u; campaign quarantined.",live.ticket);
         return(false);
        }

      SAxPositionLifecycleRecord positionState;
      if(!g_positionStateRegistryReady ||
         !g_positionStateRegistry.FindByIdentifier(live.positionIdentifier,positionState) ||
         positionState.ticket!=live.ticket || !positionState.state.active ||
         positionState.symbol!=live.symbol || positionState.magic!=live.magic)
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: durable position-state row missing for id=%I64u.",
                     live.positionIdentifier);
         return(false);
        }
      positionState.state.initialSlPrice=confirmedSl;
      positionState.state.ticket=live.ticket;
      if(!g_positionStateRegistry.Upsert(live.positionIdentifier,live.ticket,
                                          live.symbol,live.magic,positionState.state) ||
         !g_positionStateRegistry.IsPersisting())
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         PrintFormat("FLIPDEMON HEDGING TRAIL: state checkpoint failed for id=%I64u.",
                     live.positionIdentifier);
         return(false);
        }

      PrintFormat("FLIPDEMON HEDGING TRAIL CONFIRMED: ticket=%I64u id=%I64u stop=%.*f.",
                  live.ticket,live.positionIdentifier,(int)digits,confirmedSl);
     }
   return(true);
  }

//====================================================================
// MAIN TICK LOOP: SCAN -> SCORE -> ATTACK -> MANAGE -> FLIP -> EXIT -> REASSESS
//====================================================================
void AxProcessTick(void)
  {
   bool snapshotCaptured=false;
   bool multiPositionLifecycleActive=false;
   if(!g_md.OnTickUpdate()) return;

   // Observational Hawkes update. This consumes the accepted tick only and has no execution authority.
   g_hawkesEventIntensity.Update(g_md);
   g_hawkesEventIntensity.Snapshot(g_hawkesSnapshot);

   // Capture every valid accepted tick before downstream integrity/risk gates can return early.
   // The decision snapshot is attached later if this tick reaches score evaluation.
   if(InpEnableMarketSnapshots)
     {
      MqlTick rawSnapshotTick;
      if(SymbolInfoTick(_Symbol,rawSnapshotTick))
         snapshotCaptured=g_marketSnapshotRecorder.Record(rawSnapshotTick,g_lastScore,
            (int)g_engineState,g_pendingActive,g_haveOpenPosition,(int)g_posState.dir,
            AccountInfoDouble(ACCOUNT_EQUITY),AccountInfoDouble(ACCOUNT_BALANCE),
            AccountInfoDouble(ACCOUNT_MARGIN_FREE),AccountInfoDouble(ACCOUNT_MARGIN_LEVEL));
     }
   // Check the weekly close timestamp before any entry or pyramid decision.
   // Update() performs no history copy unless a new W1 candle has closed.
   g_w1Institutional.Update();
   g_d1Institutional.Update();
       if(InpUsePremiumDiscountEngine) g_premiumDiscount.Update();
   if(InpEnableMarketMakerModel)
     {
      SAxPremiumDiscountSnapshot mmxmH4Range;
      ZeroMemory(mmxmH4Range);
      g_premiumDiscount.Read(PERIOD_H4,mmxmH4Range);
      if(g_marketMakerModel.Update(mmxmH4Range) && InpVerboseLogging)
         PrintFormat("AUTOPSY X ICT MARKET MAKER MODEL: %s",g_marketMakerModel.Summary());
     }
   if(InpEnableDailyExtremeProjection && g_dailyExtremeProjection.Update() && InpVerboseLogging)
      PrintFormat("AUTOPSY X DAILY EXTREME PROJECTION: %s",g_dailyExtremeProjection.Summary());
   g_h4TrendBreakout.Update(); // internally throttled to the latest completed H4 bar
   g_spreadCost.Observe(g_md.CurrentBid(),g_md.CurrentAsk(),g_md.Point());
   // Calendar refresh is internally throttled, never queried on every tick.
   g_newsDefense.Update(false);
   g_risk.OnTickHousekeeping();
   g_afe.OnTickHousekeeping();
   g_accountFlip.OnTickHousekeeping();

   // Refresh broker tickets each valid tick. Never run the legacy single-position
   // exit manager against an arbitrary leg in a multi-position hedging campaign.
   if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber))
     {
      g_pyramidReady=false;
      if(InpVerboseLogging)
         PrintFormat("FLIPDEMON POSITION SNAPSHOT: incomplete (%s); execution remains blocked.",
                     g_hedgingPositionManager.FailureReason());
      return;
     }
   // Recover full-liquidation actionCode=4 first, then partial actionCode=3.
   // Both paths reconcile broker history and never resend an uncertain request.
   if(!AxRecoverLockedHedgingFullCloseActions()) return;
   if(!AxRecoverLockedPartialCloseActions()) return;
   if(!AxReconcileVirtualExitTickets(false)) return;
   if(!AxReconcilePyramidCampaignTickets(false)) return;

   // Every hedging leg receives its own durable, ticket-specific break-even
   // evaluation before the multi-position quarantine blocks further execution.
   if(g_hedgingPositionManager.HasMultiplePositions())
     {
      // Persisted virtual SL/TP is checked before managers requiring a broker-side stop.
       // A missing broker stop remains explicitly unprotected, but virtual exits still run.
       if(!AxManageHedgingVirtualExitTickets())
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         Print("FLIPDEMON HEDGING VIRTUAL EXIT: ticket-specific full-close orchestration failed; campaign quarantined.");
         return;
        }
       if(!AxManageHedgingBreakEvenTickets())
         return;
      if(!AxManageHedgingTrailingTickets())
         return;
      if(!AxManageHedgingPartialCloseTickets())
         return;
      // Stop/partial-close requests invalidate the earlier broker snapshot.
      // Refresh every leg and reconcile durable cursors before campaign audit.
      if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber) ||
         !AxReconcileVirtualExitTickets(false))
        {
         g_virtualExitReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         Print("FLIPDEMON HEDGING LIFECYCLE: post-management broker reconciliation failed; campaign quarantined.");
         return;
        }
     }

   // Audit every leg against its durable exit and campaign records. Ticket-specific
   // protective exits remain active; signal exits are evaluated after this tick's
   // blended score is available, with new entries held until the campaign resolves.
   SAxHedgingCampaignSnapshot hedgingSnapshot;
   if(!g_hedgingCampaignLifecycle.Evaluate(g_hedgingPositionManager,
                                            g_virtualExitRegistry,
                                            g_pyramidCampaignRegistry,
                                            hedgingSnapshot))
     {
      g_hedgingLifecycleLock=true;
      g_pyramidReady=false;
      g_engineState=AX_ENGINE_PAUSED;
      PrintFormat("FLIPDEMON HEDGING LIFECYCLE AUDIT FAILED: %s; all new execution remains blocked.",
                  hedgingSnapshot.failureReason);
      return;
     }
   if(g_hedgingPositionManager.HasMultiplePositions())
     {
      // A verified multi-leg snapshot is an operating condition, not a state
      // corruption event. Ticket-specific managers above continue to protect
      // every leg; fresh entries and legacy single-position orchestration remain
      // blocked until the account returns to one or zero managed positions.
      // Do not set the sticky integrity lock here, or the EA would remain paused
      // permanently after the final extra leg had been closed.
      g_pyramidReady=false;
      g_engineState=AX_ENGINE_PAUSED;
      if(InpVerboseLogging)
         PrintFormat("FLIPDEMON HEDGING MULTI-LEG MANAGEMENT: %d live legs reconciled; per-ticket protective exits remain active; fresh entries are blocked pending same-tick signal evaluation.",
                     g_hedgingPositionManager.Count());
      // Defer the return until this tick's blended score is available. The
      // per-position controller evaluates each durable leg against that snapshot.
      multiPositionLifecycleActive=true;
     }
   // Rehydrate the legacy single-position controller when a managed multi-leg
   // campaign has reduced to one remaining position. The registry is authoritative;
   // never reuse the state of a leg that has already closed.
   if(g_hedgingPositionManager.Count()==1)
     {
      SAxManagedPosition remainingPosition;
      SAxPositionLifecycleRecord remainingState;
      if(!g_hedgingPositionManager.GetAt(0,remainingPosition) ||
         !g_positionStateRegistryReady || !g_positionStateRegistry.IsPersisting() ||
         !g_positionStateRegistry.FindByIdentifier(remainingPosition.positionIdentifier,remainingState) ||
         !remainingState.state.active ||
         remainingState.positionIdentifier!=remainingPosition.positionIdentifier ||
         remainingState.ticket!=remainingPosition.ticket ||
         remainingState.symbol!=remainingPosition.symbol ||
         remainingState.magic!=remainingPosition.magic ||
         remainingState.state.dir!=remainingPosition.direction)
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         g_engineState=AX_ENGINE_PAUSED;
         Print("FLIPDEMON POSITION HANDOFF: remaining position has no exact durable state; legacy exits and new entries remain blocked.");
         return;
        }
      g_posState=remainingState.state;
      g_positionIdentifier=remainingState.positionIdentifier;
      g_haveOpenPosition=true;
     }
   else if(g_hedgingPositionManager.Count()==0)
     {
      g_haveOpenPosition=false;
      g_positionIdentifier=0;
      g_posState.active=false;
     }

   if(g_hedgingLifecycleLock)
     {
      g_engineState=AX_ENGINE_PAUSED;
      return;
     }

   // Broker transactions can arrive in several callbacks and in an order that differs
   // from the original request. Re-scan the actual account snapshot on the next valid tick.
   // Keep the dirty flag set on an unknown snapshot so the next tick retries reconciliation.
   if(g_accountRiskReconciliationPending)
     {
      SAxAccountRiskSnapshot transactionRisk;
      if(!g_accountRisk.Scan(transactionRisk) || !transactionRisk.exposureKnown)
        {
         g_accountRiskIntegrityLock=true;
         if(InpVerboseLogging) PrintFormat("FLIPDEMON TRANSACTION RECONCILIATION: exposure unknown; entries locked; %s",transactionRisk.failureReason);
        }
      else
        {
         bool distributedWithinCap=true;
         string distributedReconcileError="";
         bool distributedReconciled=(InpExecutionMode!=AX_EXEC_LIVE ||
            g_distributedRiskCoordinator.Reconcile(transactionRisk,distributedWithinCap,distributedReconcileError));
         if(!distributedReconciled)
           {
            g_accountRiskIntegrityLock=true;
            if(InpVerboseLogging)
               PrintFormat("FLIPDEMON DISTRIBUTED RISK: transaction snapshot not accepted; entries locked and retry retained (%s).",
                           distributedReconcileError);
           }
         else
           {
            g_accountRiskReconciliationPending=false;
            if(transactionRisk.existingRiskMoney>transactionRisk.hardRiskBudgetMoney+0.01 ||
               !distributedWithinCap)
              {
               g_accountRiskIntegrityLock=true;
               PrintFormat("FLIPDEMON TRANSACTION RECONCILIATION: local/central configured account stop-risk breach; local=%.2f budget=%.2f centralWithinCap=%s; new entries locked.",
                           transactionRisk.existingRiskMoney,transactionRisk.hardRiskBudgetMoney,
                           distributedWithinCap?"true":"false");
              }
            else if(g_accountRiskIntegrityLock)
              {
               g_accountRiskIntegrityLock=false;
               Print("FLIPDEMON TRANSACTION RECONCILIATION: local and central broker snapshots clean; account risk lock cleared.");
              }
           }
        }
     }

   // A confirmed entry deal only schedules reconciliation. The next tick reads the
   // broker's actual net position, not request/result volume, and records the campaign
   // only when its protective stop is present on the correct side of the market.
   if(g_pyramidReconcilePending)
     {
      bool foundCampaignPosition=false;
      for(int p=0;p<PositionsTotal();p++)
        {
         ulong positionTicket=PositionGetTicket(p);
         if(positionTicket==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
            (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
            continue;

         foundCampaignPosition=true;
         double positionOpen=PositionGetDouble(POSITION_PRICE_OPEN);
         double positionSl=PositionGetDouble(POSITION_SL);
         long positionType=PositionGetInteger(POSITION_TYPE);
         bool protectedPosition=(positionSl>0.0 &&
            ((positionType==POSITION_TYPE_BUY && positionSl<positionOpen) ||
             (positionType==POSITION_TYPE_SELL && positionSl>positionOpen)));
         if(!protectedPosition)
           {
            g_pyramidReady=false;
            if(InpVerboseLogging)
               PrintFormat("FLIPDEMON PYRAMID: confirmed fill awaits a valid protective stop; ticket=%I64u. Scale-ins blocked.",
                           positionTicket);
            break;
           }

         bool reconciled=false;
         if(g_pyramidCampaignRegistry.IsPersisting() &&
            g_pyramidEngine.Ready() &&
            g_pyramidCampaignRegistry.ReconcileLivePosition(positionTicket,reconciled) &&
            reconciled)
           {
            g_pyramidReady=true;
            g_pyramidReconcilePending=false;
            PrintFormat("FLIPDEMON PYRAMID: broker-confirmed campaign reconciled; ticket=%I64u volume=%.8f SL=%.8f. No tier is inferred from request acceptance.",
                        positionTicket,PositionGetDouble(POSITION_VOLUME),positionSl);
           }
         else
           {
            g_pyramidReady=false;
            if(InpVerboseLogging)
               PrintFormat("FLIPDEMON PYRAMID: broker history/registry reconciliation incomplete for ticket=%I64u; retrying and keeping scale-ins blocked.",
                           positionTicket);
           }
         break;
        }
      // No matching position yet can mean the transaction callback arrived before the
      // terminal's position snapshot caught up. Retain the pending flag and retry next tick.
      if(!foundCampaignPosition)
         g_pyramidReady=false;
     }

   //--- roll the "poor fills today" counter at broker midnight, same day boundary RiskEngine uses ---
   MqlDateTime dtNow; TimeToStruct(TimeCurrent(),dtNow);
   datetime today = TimeCurrent()-(dtNow.hour*3600+dtNow.min*60+dtNow.sec);
   if(today!=g_lastStatsDay) { g_lastStatsDay=today; g_poorFillsToday=0; }

   // A netting reversal preserves POSITION_IDENTIFIER but replaces POSITION_TICKET.
   // Until close/open allocation and campaign reassignment are implemented, the new broker
   // position is deliberately left untouched. In particular, never run old-side flip/exit
   // logic against the residual opposite position. Account-wide risk reconciliation above
   // continues to observe the broker's actual position and new entries remain locked.
   if(g_nettingReversalQuarantined)
     {
      g_engineState=AX_ENGINE_PAUSED;
      return;
     }

   //--- position may have closed externally (SL/TP hit, manual intervention) ---
   // Resolve delayed scale-out accounting before processing the next signal.
   AxRetryPendingPartialClose();

   if(g_haveOpenPosition && !PositionSelectByTicket(g_posState.ticket))
      AxRecordExternalClose();

   //--- SCAN: cheap per-tick microstructure/momentum update ---
   g_mom.Update(g_md);
   g_micro.Update(_Symbol,g_md,g_mom);
   if(InpGapContinuousExecutionEnabled)
     {
      g_gapExecution.AssessContinuousMarket(g_md.CurrentBid(),g_md.CurrentAsk(),g_md.Point(),
         g_micro.Rolling100SpreadAvgPts(),g_micro.RollingSpreadSampleCount(),
         InpGapContinuousMinSpreadSamples,InpMaxSpreadPoints,
         InpGapContinuousNormalizationMultiple,g_gapMarketCondition);
      if(g_gapMarketCondition.state!=g_gapMarketLastState)
        {
         if(InpVerboseLogging)
            PrintFormat("AUTOPSY X GAP CONTINUOUS: state=%d spread=%.2f baseline=%.2f samples=%d allowed=%s reason=%s.",
                        (int)g_gapMarketCondition.state,g_gapMarketCondition.currentSpreadPoints,
                        g_gapMarketCondition.baselineSpreadPoints,g_gapMarketCondition.samples,
                        g_gapMarketCondition.executionConditionsAcceptable?"yes":"no",
                        g_gapMarketCondition.reason);
         g_gapMarketLastState=g_gapMarketCondition.state;
        }
     }
   else
     {
      g_gapMarketCondition.executionConditionsAcceptable=true;
      g_gapMarketCondition.reason="CONTINUOUS_GAP_MODE_DISABLED";
     }
   SAxGapExecutionSignal gapSignal;
   g_gapExecution.Update(_Symbol,TimeTradeServer(),g_md.CurrentBid(),g_md.CurrentAsk(),g_md.Point(),
                         InpGapPostGapSignalEnabled,InpGapPostGapMinPoints,
                         InpGapPostGapWaitSeconds,InpGapPostGapMaxAgeSeconds,
                         InpGapPostGapMaxSpreadPoints,InpGapSpreadNormalizationMultiple,
                         InpGapPostGapMinFollowThroughPoints,InpGapPostGapMinSweepPenetrationPoints,
                         InpGapPostGapAllowSweepReversal,InpGapRolloverSignalEnabled,InpGapRolloverStartMinute,
                         InpGapRolloverEndMinute,InpGapRolloverSpikeMultiple,
                         g_micro.Rolling100SpreadAvgPts(),g_micro.RollingSpreadSampleCount(),
                         gapSignal);
   if(gapSignal.state!=g_gapExecutionLastState || gapSignal.rolloverSpikeObserved)
     {
      if(InpVerboseLogging && (gapSignal.postGapReady || gapSignal.rolloverSpikeObserved ||
                               gapSignal.state==AX_GAP_EXEC_POST_GAP_EXPIRED))
         PrintFormat("AUTOPSY X GAP EXECUTION QUALIFIER: state=%d setup=%d dir=%s gap=%.2f pts spread=%.2f baseline=%.2f elapsed=%I64u ms confirm=%.2f pts rollover_spike=%s reason=%s. Signal-only; no order submitted.",
                     (int)gapSignal.state,(int)gapSignal.setupType,AxDirToString(gapSignal.direction),gapSignal.gapPoints,
                     gapSignal.currentSpreadPoints,gapSignal.baselineSpreadPoints,
                     gapSignal.waitElapsedMs,gapSignal.confirmationDistancePoints,
                     gapSignal.rolloverSpikeObserved?"yes":"no",gapSignal.reason);
      g_gapExecutionLastState=gapSignal.state;
     }
   g_gapExecutionSignal=gapSignal;

   // Emergency protection uses the broker's live account margin level, not the
   // leverage label. A breach closes the EA's exact managed position through the
   // existing reconciled close lifecycle, then stops processing this tick.
   double emergencyMarginLevel=0.0;
   if(g_haveOpenPosition && g_posState.active && g_posState.ticket>0 &&
      g_marginGuard.EmergencyMarginLevelBreached(InpEmergencyMarginLevel,emergencyMarginLevel))
     {
      PrintFormat("FLIPDEMON EMERGENCY MARGIN: level=%.2f%% threshold=%.2f%% ticket=%I64u; requesting reconciled protective close.",
                  emergencyMarginLevel,InpEmergencyMarginLevel,g_posState.ticket);
      if(!AxCloseAndRecord(AX_EXIT_RISK_SHUTDOWN))
         g_engineState=AX_ENGINE_PAUSED;
      return;
     }
   if(InpEnableAdvancedTrendSuite)
     {
      ENUM_AX_SHADOW_EVENT shadowEvent=g_shadowRiver.Update(g_md.CurrentMid(),TimeCurrent());
      if(InpVerboseLogging && shadowEvent!=AX_SHADOW_NONE)
         PrintFormat("AUTOPSY X SHADOW RIVER: event=%d direction=%d extreme=%.10f events=%I64u",
                     (int)shadowEvent,g_shadowRiver.Direction(),g_shadowRiver.ExtremePrice(),
                     g_shadowRiver.EventCount());
      datetime advancedBar=iTime(_Symbol,InpAdvancedSignalTimeframe,0);
      if(advancedBar>0 && advancedBar!=g_lastAdvancedSignalBar)
        {
         g_lastAdvancedSignalBar=advancedBar;
         g_alphaTrend.Update();
         g_mfi.Update();
         g_slingshot.Update();
        }
      if(g_haveOpenPosition)
         g_chandelier.Update(g_posState.dir);
     }

   //--- order flow: session CVD + rolling imbalance/absorption, every tick (O(window) scan, same ---
   //--- performance category as Microstructure's own per-tick loop above) ---
   g_orderFlow.Update(g_md);
   if(InpUseOrderFlow)
     {
      // guard barTime>0 the same way the regime/HTF bar-tracking blocks below do - a transient 0
      // from iTime (history-cache eviction/feed hiccup) must never be treated as a new bar boundary,
      // or Footprint would snapshot a partially-filled bar early and then double-count the real
      // boundary once iTime recovers, splitting one bar's grid across two history entries
      datetime fpBarTime = iTime(_Symbol,InpFootprintTimeframe,0);
      if(fpBarTime>0)
         g_footprint.OnTick(fpBarTime,g_md.CurrentMid(),g_orderFlow.LastTickBuyVol(),g_orderFlow.LastTickSellVol());
     }
   g_pulse.Update(g_mom,g_micro,g_regime,g_orderFlow);

   //--- refresh structural regime/liquidity/volume-profile levels only on a new bar - not every tick ---
   bool isNewBarThisTick = false;
   datetime barTime = iTime(_Symbol,InpRegimeTimeframe,0);
   if(barTime!=g_lastBarTime && barTime>0)
     {
      isNewBarThisTick = true;
      g_lastBarTime = barTime;
      g_regime.Update();
      if(InpEnableRegimeClassificationAnalysis)
        {
         if(g_volatilityReady) g_volatility.Update();
         bool intelSampled = g_regimeIntelligence.Sample(_Symbol,InpRegimeTimeframe,
                                                         g_regime,g_macroRegime,
                                                         InpMacroReferenceSymbol,g_regimeIntelSnapshot);
         if(intelSampled)
           {
            bool regimeDataReady = g_volatilityReady && g_volatility.CurrentAtr()>0.0
                                   && g_regime.CurrentAtr()>0.0;
            string regimeDataReason = regimeDataReady ? "" : "Volatility or base-regime history unavailable";
            if(g_regimeClassifier.Sample(_Symbol,InpRegimeTimeframe,regimeDataReady,
                                         regimeDataReason,g_regime,g_volatility,g_mom,
                                         g_regimeIntelSnapshot,g_regimeClassification))
              {
               g_regimeClassificationAvailable = g_regimeClassification.dataQualityOk;
               g_adaptiveMarketRegime.Update(g_regimeClassification);
               if(InpEnableRegimeResearchJournal && g_regimeJournalReady)
                 {
                  if(!g_regimeJournal.Record(g_regimeClassification,g_regimeIntelSnapshot,g_regime,g_volatility))
                    {
                     g_regimeJournalReady=g_regimeJournal.IsPersisting();
                     Print("FLIPDEMON REGIME JOURNAL WARNING: bar record was not durably confirmed; journal disabled for this session. Trading decisions remain unchanged.");
                    }
                 }
               if(InpVerboseLogging)
                  PrintFormat("FLIPDEMON REGIME RESEARCH: %s | confidence=%.1f | age=%d bars | transition=%s | macro=%s | evidence=%s",
                              AxRegimeClassToString(g_regimeClassification.regime),
                              g_regimeClassification.regimeConfidence,
                              g_regimeClassification.regimeAgeBars,
                              g_regimeClassification.transitionDetected ? g_regimeClassification.transitionDescription : "NONE",
                              g_regimeIntelSnapshot.macroDataAvailable ? "AVAILABLE" : "UNAVAILABLE",
                              g_regimeClassification.dataQualityOk ? "VALID" : g_regimeClassification.dataQualityReason);
              }
           }
        }
      g_structure.Update();
      if(g_purePriceActionReady)
        {
         g_purePriceAction.Update();
         if(InpVerboseLogging) Print("AUTOPSY X SHADOW: ",g_purePriceAction.Summary());
        }
      if(InpUseOrderBlockEngine)
         g_orderBlock.Update(g_md.CurrentMid(),g_structure.LastEvent(),
                             g_structure.LastEventTime(),g_structure.IsDisplacement());
      g_w1Institutional.Update();
      g_d1Institutional.Update();
       if(InpUsePremiumDiscountEngine) g_premiumDiscount.Update();
      g_vpMacd.Update();
      g_liq.RefreshLevels();
      g_volProfile.Refresh();
      g_adaptiveConfMultiplier = AxAdaptiveConfidenceMultiplier();
      g_entryEngine.Configure(InpMinConfidenceToEnter*g_adaptiveConfMultiplier);

      // VWAP Trend Engine (Zarattini & Aziz 2023) - refreshed at the same once-per-bar cadence as
      // regime/liquidity above, reusing the ATR CRegimeEngine just updated rather than computing a
      // second volatility read. g_vwapValue stays -1 (unavailable) rather than 0 when the engine
      // can't compute a real reading - AxBuildEntryReason/the dashboard/g_vwapTrend all treat that
      // as "no read", never as a price of zero.
      double closedBarCloseCandidate = iClose(_Symbol,InpRegimeTimeframe,1);
      if(closedBarCloseCandidate>0)
        {
         g_lastClosedBarClose = closedBarCloseCandidate;
         g_vwapValue = g_vwap.GetVWAP(_Symbol,InpRegimeTimeframe);
         g_vwapTrend = g_vwap.ClassifyVWAPTrend(g_lastClosedBarClose,g_vwapValue,g_regime.CurrentAtr());
        }
      else
        {
         // iClose() returning 0 means the closed bar's price genuinely isn't available yet (a
         // fresh history cache right after EA start, a brief feed/history gap) - MQL5 documents
         // this as a real, non-error return value, not an exception. A zero price is never a real
         // market price, so it must never be trusted as one: force everything downstream that
         // depends on it back to "unavailable" rather than let a spurious 0 corrupt the trend
         // classification or arm/fire the mechanical VWAP exit off bad data.
         g_vwapValue = -1.0;
         g_vwapTrend = "NEUTRAL";
        }
      if(InpUseContinuationIntelligence)
         g_continuationIntelligence.Update(TimeTradeServer()>0?TimeTradeServer():TimeCurrent(),g_vwapValue,g_regime.CurrentAtr(),g_vwapTrend,true);
     }
   //--- HTF confluence structure refreshes on its own, slower bar clock ---
   datetime htfBarTime = iTime(_Symbol,InpHtfTimeframe,0);
   if(htfBarTime!=g_lastHtfBarTime && htfBarTime>0)
     {
      g_lastHtfBarTime = htfBarTime;
      g_regimeHtf.Update();
     }
   g_liq.UpdateTick(g_md.CurrentBid(),g_md.CurrentAsk(),g_mom.DisplacementPts(),g_md.Point());
   if(InpUseFvgRetestEngine) g_fvg.Update(g_md.CurrentMid());
   if(InpUseOrderBlockEngine)
      g_orderBlock.Update(g_md.CurrentMid(),g_structure.LastEvent(),
                          g_structure.LastEventTime(),g_structure.IsDisplacement());
   // Classification consumes the last CLOSED bar only and is guarded internally against
   // repeated ticks. It labels reversal, continuation or unconfirmed sweep evidence; it does
   // not alter the scorer, execution decision or account-risk controls.
   datetime liquidityClosedBarTime=iTime(_Symbol,InpRegimeTimeframe,1);
   double liquidityClosedBarOpen=iOpen(_Symbol,InpRegimeTimeframe,1);
   double liquidityClosedBarClose=iClose(_Symbol,InpRegimeTimeframe,1);
   double liquidityPoint=g_md.Point();
   if(liquidityPoint>0.0 && liquidityClosedBarTime>0 &&
      liquidityClosedBarOpen>0.0 && liquidityClosedBarClose>0.0)
     {
      // Use the signed body of the SAME completed candle. Tick momentum is live and may point
      // the other way, so it must never confirm a historical closed-bar liquidity event.
      double closedBarDisplacementPts=(liquidityClosedBarClose-liquidityClosedBarOpen)/liquidityPoint;
      ENUM_AX_STRUCTURE_EVENT closedBarStructureEvent=AX_STRUCT_NONE;
      if(g_structure.LastEventTime()==liquidityClosedBarTime)
         closedBarStructureEvent=g_structure.LastEvent();
      g_liq.ClassifyClosedBar(liquidityClosedBarClose,closedBarDisplacementPts,
                              g_structure.IsDisplacement(),closedBarStructureEvent,
                              liquidityClosedBarTime);
     }
   datetime orbServerTime=TimeTradeServer();
   if(orbServerTime<=0) orbServerTime=TimeCurrent();
   g_advancedSessionOrb.Update(_Symbol,orbServerTime,g_md.Point());

   // Supervisory evidence shadow pass. Existing timestamped reads only.
   // No effect on score, entry, execution or account-risk authority.
   if(isNewBarThisTick)
     {
      g_evidenceArbitrator.Clear();
      SAxW1Snapshot w1EvidenceSnapshot=g_w1Institutional.Snapshot();
      SAxD1Snapshot d1EvidenceSnapshot=g_d1Institutional.Snapshot();
      g_institutionalEvidenceAdapter.AddW1(w1EvidenceSnapshot,g_evidenceArbitrator);
      g_institutionalEvidenceAdapter.AddD1(d1EvidenceSnapshot,g_evidenceArbitrator);
      int structureEvidenceAge=PeriodSeconds(InpRegimeTimeframe)*3;
      if(structureEvidenceAge<=0) structureEvidenceAge=3600;
      g_institutionalEvidenceAdapter.AddStructureEvent(
         g_structure.LastEvent(),g_structure.LastEventTime(),
         structureEvidenceAge,g_evidenceArbitrator);
      SAxArbitrationResult shadowResult=g_evidenceArbitrator.Resolve(TimeCurrent());
      if(InpVerboseLogging)
         PrintFormat("AUTOPSY X EVIDENCE SHADOW: direction=%s strength=%.1f conflict=%.3f fresh=%d stale=%d unavailable=%d groups=%d reason=%s",
                     shadowResult.direction==AX_DIR_BUY?"BUY":
                     shadowResult.direction==AX_DIR_SELL?"SELL":"WAIT",
                     shadowResult.directionalStrength,shadowResult.conflictRatio,
                     shadowResult.freshEvidenceCount,shadowResult.staleEvidenceCount,
                     shadowResult.unavailableEvidenceCount,
                     shadowResult.independentGroupCount,shadowResult.reason);
     }

   //--- SCORE ---
   SAxScore score = g_scorer.Evaluate(g_md,g_mom,g_micro,g_liq,g_regime);
   if(InpEnableAdvancedTrendSuite)
     {
      SAxAdvancedReading alphaRead=g_alphaTrend.Read();
      SAxAdvancedReading mfiRead=g_mfi.Read();
      SAxAdvancedReading slingRead=g_slingshot.Read();
      g_ultimateTrendAlpha.Evaluate(
         g_w1Institutional.AllowsDirection(AX_DIR_BUY),
         g_w1Institutional.AllowsDirection(AX_DIR_SELL),
         g_d1Institutional.AllowsDirection(AX_DIR_BUY),
         g_d1Institutional.AllowsDirection(AX_DIR_SELL),
         g_h4TrendBreakout.Bias(),alphaRead,mfiRead,slingRead,g_shadowRiver.Direction());
      if(InpVerboseLogging && isNewBarThisTick)
        {
         SAxUltimateTrendAlpha alphaSnapshot=g_ultimateTrendAlpha.Last();
         SAxAdaptiveRegimePosture regimePosture=g_adaptiveMarketRegime.Read();
         double chandelierStop=0.0;
         bool chandelierAvailable=g_haveOpenPosition && g_chandelier.Stop(g_posState.dir,chandelierStop);
         PrintFormat("AUTOPSY X ULTIMATE TREND ALPHA: available=%s direction=%s score(B/S)=%.1f/%.1f confidence=%.1f | adaptive regime=%s research multiplier=%.2f | Chandelier=%s %.10f",
                     alphaSnapshot.available?"YES":"NO",
                     alphaSnapshot.direction==AX_DIR_BUY?"BUY":alphaSnapshot.direction==AX_DIR_SELL?"SELL":"NONE",
                     alphaSnapshot.buyScore,alphaSnapshot.sellScore,alphaSnapshot.confidence,
                     regimePosture.label,regimePosture.researchMultiplier,
                     chandelierAvailable?"READY":"UNAVAILABLE",chandelierStop);
        }
     }
   AxApplyOrderFlowBonus(score);
   AxApplyH4BreakoutBonus(score);
   AxApplyAdvancedORBScoreBonus(score);
   AxApplyPremiumDiscountScoreBonus(score);
   AxApplyFvgRetestScoreBonus(score);
   AxApplyOrderBlockScoreBonus(score);
    AxApplyMarketMakerModelScoreBonus(score);
   AxApplyContinuationIntelligenceBonus(score);
   g_lastScore = score; // dashboard reads this, not g_scorer.Last(), so it shows the blended score
   // Attach the exact same-tick blended decision to the raw snapshot captured at handler entry.
   if(snapshotCaptured)
      g_marketSnapshotRecorder.UpdateLastDecision(g_lastScore,(int)g_engineState,
         g_pendingActive,g_haveOpenPosition,(int)g_posState.dir,
         AccountInfoDouble(ACCOUNT_EQUITY),AccountInfoDouble(ACCOUNT_BALANCE),
         AccountInfoDouble(ACCOUNT_MARGIN_FREE),AccountInfoDouble(ACCOUNT_MARGIN_LEVEL));
   g_accuracy.OnTickUpdate(g_md.CurrentMid());
   //--- sample into the accuracy engine on signal-direction change or at most once/second -   ---
   //--- registering every tick of a sustained signal would saturate the ring buffer on fast-  ---
   //--- ticking symbols before the longer horizons (10s/30s) get a chance to resolve          ---
   if(score.action!=AX_DIR_NONE)
     {
      bool changed = (score.action!=g_lastAccSignalDir);
      bool throttleElapsed = (TimeCurrent()-g_lastAccSignalTime)>=1;
      if(changed || throttleElapsed)
        {
         g_accuracy.RegisterSignal(TimeCurrent(),g_md.CurrentMid(),score.action);
         g_lastAccSignalDir  = score.action;
         g_lastAccSignalTime = TimeCurrent();
        }
     }
   else
      g_lastAccSignalDir = AX_DIR_NONE;

   //--- KILL SWITCH / catastrophic execution guard ---
   if(g_consecutiveExecFailures>=InpMaxConsecutiveExecFailures && !g_risk.IsKilled())
      g_risk.ActivateKillSwitch("Catastrophic execution failures");

   if(g_risk.IsKilled())
     {
      g_engineState = AX_ENGINE_KILLED;
      if(multiPositionLifecycleActive && InpCloseAllOnKill)
        {
         if(!AxCloseOneHedgingPositionForRiskShutdown())
            Print("FLIPDEMON HEDGING KILL SHUTDOWN: one-leg close did not complete; durable action state retained.");
         return;
        }
      if(g_haveOpenPosition && InpCloseAllOnKill)
         AxCloseAndRecord(AX_EXIT_MANUAL_KILL);
      return;
     }

   //--- RISK SHUTDOWN: daily loss limit ---
   if(g_risk.DailyLossLimitBreached())
     {
      g_engineState = AX_ENGINE_PAUSED;
      if(multiPositionLifecycleActive)
        {
         if(!AxCloseOneHedgingPositionForRiskShutdown())
            Print("FLIPDEMON HEDGING DAILY-LOSS SHUTDOWN: one-leg close did not complete; durable action state retained.");
         return;
        }
      if(g_haveOpenPosition)
         AxCloseAndRecord(AX_EXIT_RISK_SHUTDOWN);
      return;
     }

   // Multi-leg signal exits run after this tick's blended score and accuracy
   // snapshot, but before legacy single-position management or any entry route.
   if(multiPositionLifecycleActive)
     {
      bool hedgingCloseAttempted=false;
      if(!AxManageHedgingSignalExitTickets(g_lastScore,isNewBarThisTick,
                                            hedgingCloseAttempted))
         return;
      if(hedgingCloseAttempted)
         return; // close path refreshed broker state; re-evaluate remaining legs next tick
      g_engineState=AX_ENGINE_PAUSED;
      return;
     }

   //--- MANAGE / FLIP / EXIT ---
   if(g_haveOpenPosition)
     {
      g_engineState = AX_ENGINE_MANAGING;
      if(g_tradeLifecycle.SetupId()==g_posState.setupId &&
         g_tradeLifecycle.State()==AX_LIFECYCLE_POSITION_ACTIVE &&
         !g_tradeLifecycle.TransitionTo(AX_LIFECYCLE_POSITION_MANAGED))
        {
         g_recoveryReady=false;
         PrintFormat("FLIPDEMON LIFECYCLE ERROR: active setup %s could not enter POSITION_MANAGED (%s); new entries blocked.",
                     g_posState.setupId,g_tradeLifecycle.LastError());
        }

      // Pyramid candidate preflight. ANALYSIS_ONLY and PAPER_EXECUTION only log the
       // candidate; broker submission is separately opt-in and guarded by AX_EXEC_LIVE.
       // A candidate must be profitable, directionally valid on completed H1 bars,
       // beyond the last broker-confirmed tier by an ATR gap, and inside the fresh
       // configured account-wide stop-risk budget.
       datetime pyramidClosedBar=iTime(_Symbol,PERIOD_H1,1);
      if(InpEnablePyramidDecision && g_pyramidReady && !g_pyramidReconcilePending &&
         !g_accountRiskIntegrityLock && !g_nettingReversalQuarantined &&
         pyramidClosedBar>0 && pyramidClosedBar!=g_lastPyramidDecisionBar)
        {
         g_lastPyramidDecisionBar=pyramidClosedBar;
         SAxPyramidCampaignRecord campaign;
         if(g_pyramidCampaignRegistry.Find(g_positionIdentifier,campaign) &&
            campaign.active &&
             (InpPyramidMaxTiers<=0 || campaign.tierCount<InpPyramidMaxTiers) &&
             PositionSelectByTicket(g_posState.ticket))
           {
            double basketProfit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            ENUM_AX_DIR closedTrend=AX_DIR_NONE;
            bool trendCrossed=false;
            bool trendRead=g_pyramidEngine.ReadClosedTrend(_Symbol,closedTrend,trendCrossed);
            double atr=0.0;
            bool atrRead=g_pyramidEngine.ReadClosedAtr(atr);
            double requiredGap=atrRead?atr*InpPyramidAtrGapMultiplier:0.0;
            double candidateLots=g_pyramidEngine.CalculateTierVolume(
               campaign.baseTierLots,campaign.tierCount+1,AX_PYRAMID_MULTIPLIER,
               InpPyramidLotMultiplier,0.0,"");
            double volStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
            double volMin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
            double volMax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
            if(volStep>0.0 && candidateLots>0.0)
               candidateLots=MathFloor((candidateLots+1e-10)/volStep)*volStep;
            candidateLots=MathMin(candidateLots,volMax);
            candidateLots=NormalizeDouble(candidateLots,8);
            MqlTick pyramidTick;
            bool quoteOk=SymbolInfoTick(_Symbol,pyramidTick) &&
                         pyramidTick.bid>0.0 && pyramidTick.ask>=pyramidTick.bid;
            double closedH1=iClose(_Symbol,PERIOD_H1,1);
            bool trigger=(quoteOk && g_pyramidEngine.TierTriggerReached(
               campaign.dir,AX_PYRAMID_ATR_GAP,campaign.lastTierFillPrice,
               pyramidTick.bid,pyramidTick.ask,requiredGap,closedH1));
            bool pyramidVwapAligned=(!InpRequireVWAPDirection) ||
                                    (campaign.dir==AX_DIR_BUY && g_vwapValue>0.0 && g_vwapTrend=="BULLISH") ||
                                    (campaign.dir==AX_DIR_SELL && g_vwapValue>0.0 && g_vwapTrend=="BEARISH");
            bool eligible=(g_precisionEntryReady && g_precisionEntry.AllowsDirection(campaign.dir) &&
                           trendRead && atrRead && closedTrend==campaign.dir && pyramidVwapAligned &&
                           basketProfit>=InpPyramidMinProfitMoney &&
                           candidateLots>=volMin && candidateLots>campaign.lastTierFilledLots+volStep*0.25 &&
                           candidateLots<=volMax && trigger &&
                           campaign.lastTriggerBarTime!=pyramidClosedBar);
            if(eligible)
              {
               double stop=PositionGetDouble(POSITION_SL);
               SAxAccountRiskDecision pyramidRiskDecision;
               string pyramidRiskReason="";
               if(g_accountRisk.Evaluate(_Symbol,campaign.dir,candidateLots,stop,
                                         InpDeviationPoints,g_risk.RiskPercent(),
                                         pyramidRiskDecision,pyramidRiskReason))
                 {
                  PrintFormat("FLIPDEMON PYRAMID CANDIDATE: tier=%d/%s direction=%s addLots=%.8f basketPnl=%.2f lastTierFill=%.8f requiredGap=%.8f projectedAggregateRisk=%.2f%%.",
                               campaign.tierCount+1,
                               InpPyramidMaxTiers>0?IntegerToString(InpPyramidMaxTiers):"UNLIMITED",
                              campaign.dir==AX_DIR_BUY?"BUY":"SELL",candidateLots,
                              basketProfit,campaign.lastTierFillPrice,requiredGap,
                              (pyramidRiskDecision.existingRiskMoney+pyramidRiskDecision.proposedRiskMoney)/
                              pyramidRiskDecision.equity*100.0);
                  if(InpEnablePyramidExecution)
                     AxAttemptPyramidNettingAdd(campaign,candidateLots,pyramidClosedBar);
                 }
               else if(InpVerboseLogging)
                  PrintFormat("FLIPDEMON PYRAMID CANDIDATE BLOCKED: %s",pyramidRiskReason);
              }
           }
        }

      bool spreadOk = g_micro.SpreadAcceptable(InpMaxSpreadPoints);

      ENUM_AX_DIR oppositeDirection=(g_posState.dir==AX_DIR_BUY)?AX_DIR_SELL:AX_DIR_BUY;
      ENUM_AX_DIR confirmedH1Direction=AX_DIR_NONE;
      bool h1Crossed=false;
      datetime confirmedH1Bar=iTime(_Symbol,PERIOD_H1,1);
      bool h1TrendRead=(g_pyramidReady &&
                        g_pyramidEngine.ReadClosedTrend(_Symbol,confirmedH1Direction,h1Crossed));
      bool higherTimeframeReversalConfirmed=(h1TrendRead &&
                                              confirmedH1Direction==oppositeDirection);
      bool flipTriggered = g_flip.Evaluate(g_posState.dir,score,g_mom,g_micro,spreadOk,
                                            higherTimeframeReversalConfirmed,confirmedH1Bar);
      if(flipTriggered)
        {
         ENUM_AX_DIR newDir  = (g_posState.dir==AX_DIR_BUY) ? AX_DIR_SELL : AX_DIR_BUY;
         int newFlipSeq = g_flip.FlipGeneration();
         if(AxCloseAndRecord(AX_EXIT_FLIP))
           {
            g_risk.RegisterFlip();
            // attempt the reversal BEFORE arming this flip's own anti-chop cooldown - RegisterFlip()
            // always pushes m_cooldownUntil forward, so registering first would make AxAttemptEntry's
            // IsInCooldown() check block the very re-entry this flip is trying to make, 100% of the
            // time under default settings. The reentry is still gated by whatever cooldown PRIOR
            // events already armed; only after attempting it do we arm/extend the cooldown for the
            // NEXT flip, which is what actually throttles rapid repeated flipping.
            AxAttemptEntry(newDir,score,newFlipSeq,"FLIP");
            g_chop.RegisterFlip();
           }
        }
      else
        {
         g_exit.UpdateExcursion(g_posState,g_md.CurrentBid(),g_md.CurrentAsk(),g_md.TickValue(),g_md.TickSize());
         //--- InpUseVWAPExit is the master on/off switch (unchanged); InpVWAPExitMode governs exactly
         //--- when it fires once armed. IMMEDIATE-mode live-price and PLUS_STRUCTURE-mode structure
         //--- confirmation aren't wired to real inputs yet (StructureEngine isn't integrated into the
         //--- live tick loop) - passing 0.0/false is correct-by-construction for CONFIRMED_CROSS (the
         //--- default), which never reads either parameter; selecting IMMEDIATE or PLUS_STRUCTURE
         //--- before that wiring exists would silently never fire, which is documented here rather
         //--- than left to be discovered.
         ENUM_AX_VWAP_EXIT_MODE effectiveVwapExitMode = InpUseVWAPExit ? g_effectiveVwapExitMode : AX_VWAP_EXIT_OFF;
         SAxExitDecision dec = g_exit.Evaluate(g_posState,g_md,g_mom,g_micro,score,InpMaxSpreadPoints,
                                                effectiveVwapExitMode,isNewBarThisTick,g_vwapValue,
                                                g_lastClosedBarClose,0.0,false);
         if(dec.shouldExit)
           {
            AxCloseAndRecord(dec.reason);
           }
         else
           {
            double curPrice = (g_posState.dir==AX_DIR_BUY) ? g_md.CurrentBid() : g_md.CurrentAsk();

            double newSl;
            bool wantModify=false;
            bool isBreakEvenMove=false;
            if(g_exit.CheckBreakEven(g_posState,g_md,curPrice,newSl))
              {
               wantModify=true;
               isBreakEvenMove=true;
              }
            else if(g_exit.CheckTrailing(g_posState,g_md,curPrice,g_posState.initialSlPrice,g_mom,newSl))
              {
               wantModify=true;
              }
            if(wantModify)
              {
               // Persist the lifecycle lock before touching the broker. The stable position
               // identifier is the primary key; the current broker ticket is only a handle.
               const int actionCode=isBreakEvenMove ? 1 : 2; // 1=break-even, 2=trailing
               SAxManagedPosition managed;
               SAxVirtualExitRecord savedExit;
               if(!g_hedgingPositionManager.FindByIdentifier(g_positionIdentifier,managed) ||
                  managed.ticket==0 || managed.positionIdentifier!=g_positionIdentifier ||
                  managed.symbol!=_Symbol || managed.magic!=InpMagicNumber ||
                  managed.direction!=g_posState.dir || !managed.hasValidBrokerStop ||
                  !g_virtualExitRegistry.Find(g_positionIdentifier,savedExit) ||
                  savedExit.actionLocked)
                 {
                  g_virtualExitReady=false;
                  g_hedgingLifecycleLock=true;
                  g_engineState=AX_ENGINE_PAUSED;
                  Print("FLIPDEMON VIRTUAL EXIT ERROR: exact broker position or unlocked durable exit state unavailable; stop action blocked.");
                  return;
                 }

               if(!g_virtualExitRegistry.BeginAction(g_positionIdentifier,actionCode) ||
                  !g_virtualExitRegistry.IsPersisting())
                 {
                  g_virtualExitReady=false;
                  g_hedgingLifecycleLock=true;
                  g_engineState=AX_ENGINE_PAUSED;
                  Print("FLIPDEMON VIRTUAL EXIT ERROR: action lock could not be persisted; broker stop was not modified.");
                  return;
                 }

               string modErr;
               if(!g_exec.ModifyStopsByTicket(_Symbol,managed.ticket,managed.positionIdentifier,
                                               managed.magic,newSl,managed.takeProfit,modErr))
                 {
                  // The broker may have accepted a request whose confirmation was lost.
                  // Keep the durable action lock and quarantine. Never resend on the next tick.
                  g_virtualExitReady=false;
                  g_hedgingLifecycleLock=true;
                  g_engineState=AX_ENGINE_PAUSED;
                  PrintFormat("FLIPDEMON VIRTUAL EXIT UNCERTAIN: stop action=%d ticket=%I64u identifier=%I64u; action lock retained, no retry (%s).",
                              actionCode,managed.ticket,managed.positionIdentifier,modErr);
                  return;
                 }

               bool recorded=isBreakEvenMove
                             ? g_virtualExitRegistry.RecordBreakEven(g_positionIdentifier,newSl)
                             : g_virtualExitRegistry.RecordTrailingStop(g_positionIdentifier,newSl);
               if(!recorded || !g_virtualExitRegistry.IsPersisting())
                 {
                  g_virtualExitReady=false;
                  g_hedgingLifecycleLock=true;
                  g_engineState=AX_ENGINE_PAUSED;
                  PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: broker confirmed stop %.10f but durable lifecycle record failed; action lock retained.",
                              newSl);
                  return;
                 }

               if(!g_virtualExitRegistry.ResolveAction(g_positionIdentifier,actionCode) ||
                  !g_virtualExitRegistry.IsPersisting())
                 {
                  g_virtualExitReady=false;
                  g_hedgingLifecycleLock=true;
                  g_engineState=AX_ENGINE_PAUSED;
                  PrintFormat("FLIPDEMON VIRTUAL EXIT ERROR: stop %.10f was recorded but action lock could not be resolved; management quarantined.",
                              newSl);
                  return;
                 }

               g_posState.initialSlPrice=newSl;
               if(isBreakEvenMove) g_posState.breakEvenDone=true;
               g_posState.modifyFailCount=0;
               // Refresh the broker snapshot before another lifecycle action can be considered.
               if(!g_hedgingPositionManager.Refresh(_Symbol,InpMagicNumber) ||
                  !AxReconcileVirtualExitTickets(false))
                 {
                  g_virtualExitReady=false;
                  g_hedgingLifecycleLock=true;
                  g_engineState=AX_ENGINE_PAUSED;
                  Print("FLIPDEMON VIRTUAL EXIT ERROR: post-modification broker snapshot could not be reconciled; management paused.");
                  return;
                 }
              }
           }
        }
     }
   else
     {
      //--- ATTACK: evaluate a fresh entry. Two modes:
      //--- sniper mode arms on a confirmed signal and waits for a genuine pullback-then-resume
      //--- before committing capital (better price, no chasing); legacy mode uses a plain
      //--- one-tick confirmation delay. Either way, conditions are re-verified immediately
      //--- before committing capital.
      // A confirmed Gap Hour setup is an independent trigger, but never an
      // independent execution path. Require the live composite score to agree,
      // then send it through the same preflight and AxAttemptEntry risk pipeline.
      // Keep the ready event latched while the directional score is not aligned;
      // the gap engine expires/resets it on its own M1 lifecycle.
      if(gapSignal.postGapReady)
        {
         string gapEntryReason="";
         bool gapDirectionConfirmed=(gapSignal.direction!=AX_DIR_NONE &&
                                     score.action==gapSignal.direction);
         bool gapPreflightOk=false;
         if(!gapDirectionConfirmed)
            gapEntryReason="GAP_DIRECTION_NOT_CONFIRMED_BY_LIVE_SCORE";
         else
           {
            int gapSessionStart=InpSessionStartHour;
            int gapSessionEnd=InpSessionEndHour;
            int gapRolloverAvoidance=InpAvoidRolloverMinutes;
            if(InpGapHourBypassSessionHours)
              {
               gapSessionStart=0;
               gapSessionEnd=0;
              }
            if(InpGapHourAllowRollover)
               gapRolloverAvoidance=0;
            gapPreflightOk=(AxSpreadCostAllowed(gapEntryReason) &&
                            g_entryEngine.PreFlightCheck(_Symbol,g_md,score,g_risk,g_chop,
                                                         InpEmergencySlPoints,0,0.0,
                                                         gapSessionStart,gapSessionEnd,
                                                         gapRolloverAvoidance,gapEntryReason));
            if(gapPreflightOk && !AxHtfConfluenceOk(gapSignal.direction))
              {
               gapPreflightOk=false;
               gapEntryReason="GAP_HTF_CONFLUENCE_NOT_CONFIRMED";
              }
           }
         if(gapPreflightOk)
           {
            g_engineState=AX_ENGINE_ATTACKING;
            bool gapEntryAccepted=AxAttemptEntry(gapSignal.direction,score,0,"GAP_HOUR",true);
            // Consume after the complete shared entry pipeline has been attempted,
            // whether accepted or rejected, so a single M1 event cannot duplicate orders.
            if(!g_gapExecution.ConsumePostGapSignal())
               Print("FLIPDEMON GAP EXECUTION ERROR: qualified event could not be consumed.");
            if(InpVerboseLogging)
               PrintFormat("FLIPDEMON GAP EXECUTION: %s direction=%s setup=%d gap=%.2f pts reason=%s.",
                           gapEntryAccepted?"ENTRY_PIPELINE_ACCEPTED":"ENTRY_PIPELINE_REJECTED",
                           AxDirToString(gapSignal.direction),(int)gapSignal.setupType,
                           gapSignal.gapPoints,gapSignal.reason);
           }
         else if(InpVerboseLogging)
            PrintFormat("FLIPDEMON GAP EXECUTION: qualified event is waiting for entry confirmation (%s).",
                        gapEntryReason);
        }
      else if(InpUseSniperEntry)
        {
         if(g_sniper.IsArmed())
           {
            bool expired;
            bool triggered = g_sniper.OnTick(g_md.CurrentMid(),expired);
            if(triggered)
              {
               string finalReason;
               if(AxSpreadCostAllowed(finalReason) &&
                  g_entryEngine.FinalConfirm(g_md,g_pendingScore,score,InpMaxSpreadPoints,finalReason) &&
                  AxHtfConfluenceOk(g_pendingScore.action))
                 {
                  g_engineState = AX_ENGINE_ATTACKING;
                  AxAttemptEntry(g_pendingScore.action,score,0,"SNIPER");
                 }
               else if(InpVerboseLogging) PrintFormat("AUTOPSY X: sniper trigger cancelled (%s)",finalReason);
              }
            else if(expired)
              {
               if(InpVerboseLogging) Print("AUTOPSY X: sniper entry expired - no valid retest, standing down");
              }
            else
              {
               g_engineState = AX_ENGINE_ACTIVE; // waiting for the precise retest
              }
           }
         else
           {
            string reason;
            double stopDistPts = InpEmergencySlPoints;
            bool ok = AxSpreadCostAllowed(reason)
                      && g_entryEngine.PreFlightCheck(_Symbol,g_md,score,g_risk,g_chop,stopDistPts,0,0.0,
                                                    InpSessionStartHour,InpSessionEndHour,
                                                    InpAvoidRolloverMinutes,reason)
                      && AxHtfConfluenceOk(score.action);
            if(ok)
              {
               g_sniper.Arm(score.action,g_md.CurrentMid());
               g_pendingScore = score; // remember direction/score for FinalConfirm's "original" baseline
               g_engineState  = AX_ENGINE_ACTIVE;
              }
            else
              {
               g_engineState = g_chop.IsInCooldown() ? AX_ENGINE_COOLDOWN : AX_ENGINE_ACTIVE;
              }
           }
        }
      else
        {
         if(g_pendingActive && (TimeCurrent()-g_pendingTime)>AX_PENDING_MAX_AGE_SEC)
            g_pendingActive = false; // missed move - never chase

         if(g_pendingActive)
           {
            string finalReason;
            if(AxSpreadCostAllowed(finalReason) &&
               g_entryEngine.FinalConfirm(g_md,g_pendingScore,score,InpMaxSpreadPoints,finalReason) &&
               AxHtfConfluenceOk(score.action))
              {
               g_engineState = AX_ENGINE_ATTACKING;
               AxAttemptEntry(score.action,score,0,"ENTRY");
              }
            else if(InpVerboseLogging) PrintFormat("AUTOPSY X: entry cancelled (%s)",finalReason);
            g_pendingActive = false;
           }
         else
           {
            string reason;
            double stopDistPts = InpEmergencySlPoints;
            bool ok = AxSpreadCostAllowed(reason)
                      && g_entryEngine.PreFlightCheck(_Symbol,g_md,score,g_risk,g_chop,stopDistPts,0,0.0,
                                                    InpSessionStartHour,InpSessionEndHour,
                                                    InpAvoidRolloverMinutes,reason)
                      && AxHtfConfluenceOk(score.action);
            if(ok)
              {
               g_pendingActive = true;
               g_pendingScore  = score;
               g_pendingTime   = TimeCurrent();
               g_engineState   = AX_ENGINE_ACTIVE;
              }
            else
              {
               g_engineState = g_chop.IsInCooldown() ? AX_ENGINE_COOLDOWN : AX_ENGINE_ACTIVE;
              }
           }
        }
     }
  }

// Native event wrapper records the complete handler duration even when the
// processing function exits early. No logging, sorting or file I/O occurs here.
void OnTick(void)
  {
   ulong tickStartUs=GetMicrosecondCount();
   AxProcessTick();
   g_executionLatency.RecordTick(GetMicrosecondCount()-tickStartUs);
  }

//====================================================================
// TIMER: dashboard redraw only - never in the hot tick path
//====================================================================
void OnTimer(void)
  {
   AxObserveGapHour();
   // Checkpoint only the legacy single-position snapshot outside the tick path.
   // Hedging legs persist through their identifier-keyed state, exit and close ledgers;
   // this timer must never checkpoint a multi-position campaign through g_posState.
   if(g_haveOpenPosition && g_posState.active && g_positionIdentifier>0 &&
      g_positionStateRegistryReady && PositionSelectByTicket(g_posState.ticket) &&
      (ulong)PositionGetInteger(POSITION_IDENTIFIER)==g_positionIdentifier)
     {
      if(!g_positionStateRegistry.Upsert(g_positionIdentifier,g_posState.ticket,_Symbol,
                                         InpMagicNumber,g_posState) ||
         !g_positionStateRegistry.IsPersisting())
        {
         g_recoveryReady=false;
         g_hedgingLifecycleLock=true;
         PrintFormat("FLIPDEMON POSITION STATE ERROR: timer checkpoint failed for identifier=%I64u; new entries blocked.",
                     g_positionIdentifier);
        }
     }
   // Flush bounded snapshot batches outside the tick handler to keep file I/O off the hot path.
   if(InpEnableMarketSnapshots) g_marketSnapshotRecorder.Flush(1024);

   // This recovery clock is independent of dashboard visibility. It never sends
   // orders; it only reconciles broker truth and resolves the persisted reservation.
   if(InpExecutionMode==AX_EXEC_LIVE && g_distributedRecoveryPending)
     {
      SAxAccountRiskSnapshot recoverySnapshot;
      string recoveryError="";
      if(!g_accountRisk.Scan(recoverySnapshot) || !recoverySnapshot.exposureKnown)
        {
         g_accountRiskIntegrityLock=true;
         if(InpVerboseLogging)
            PrintFormat("FLIPDEMON DISTRIBUTED RISK: recovery retry deferred; broker exposure is unknown (%s).",
                        recoverySnapshot.failureReason);
        }
      else
        {
         bool recoveredPending=false;
         if(g_distributedRejectedCallbackPending)
           {
            // The transaction callback only records evidence. Network I/O and
            // reservation release happen here, after a fresh full-account scan.
            recoveredPending=g_distributedRiskCoordinator.ResolveDefinitiveRejection(
                               recoverySnapshot,recoveryError);
            if(recoveredPending)
               g_distributedRejectedCallbackPending=false;
           }
         else
            recoveredPending=g_distributedRiskCoordinator.RecoverPending(
                               recoverySnapshot,recoveryError);

         if(!recoveredPending)
           {
            g_accountRiskIntegrityLock=true;
            if(InpVerboseLogging)
               PrintFormat("FLIPDEMON DISTRIBUTED RISK: recovery remains locked; next timer retry will reconcile again (%s).",
                           recoveryError);
           }
         else
           {
            bool recoveryWithinCap=false;
         if(!g_distributedRiskCoordinator.Reconcile(recoverySnapshot,recoveryWithinCap,recoveryError))
           {
            g_accountRiskIntegrityLock=true;
            if(InpVerboseLogging)
               PrintFormat("FLIPDEMON DISTRIBUTED RISK: reservation resolved but fresh central reconciliation failed; entries remain locked (%s).",
                           recoveryError);
           }
         else
           {
            g_distributedRecoveryPending=false;
            if(!recoveryWithinCap ||
               recoverySnapshot.existingRiskMoney>recoverySnapshot.hardRiskBudgetMoney+0.01)
              {
               g_accountRiskIntegrityLock=true;
               Print("FLIPDEMON DISTRIBUTED RISK: reservation recovery completed, but account exposure remains above budget. New entries stay locked.");
              }
            else
               Print("FLIPDEMON DISTRIBUTED RISK: terminal reservation recovered and broker exposure reconciled.");
           }
          }
        }
     }

   if(g_iq200TelemetryReady)
     {
      double markoutValues[];
      bool markoutValid[];
      g_iq200Telemetry.ProcessDueMarkouts(markoutValues,markoutValid);
      for(int markoutIndex=0;markoutIndex<ArraySize(markoutValues);markoutIndex++)
         if(markoutIndex<ArraySize(markoutValid) && markoutValid[markoutIndex])
            g_executionFeedback.RecordMarkout(markoutValues[markoutIndex]);
      g_iq200Telemetry.Flush(1024);
     }

   if(!InpShowDashboard) return;

   // DOM refresh is heavier than a tick read and doesn't need tick-rate freshness to stay useful -
   // the dashboard/timer's 1s cadence (the only periodic clock this EA runs) is the natural home for it
   if(InpUseHeatmap)
      g_heatmap.Update(g_md.CurrentBid(),g_md.CurrentAsk(),InpHeatmapRangePoints,g_md.Point());

   double floatingPnl = 0;
   double curPrice = g_md.CurrentMid();
   int holdSeconds = 0;
   if(g_haveOpenPosition && PositionSelect(_Symbol))
     {
      floatingPnl = PositionGetDouble(POSITION_PROFIT);
      curPrice    = PositionGetDouble(POSITION_PRICE_CURRENT);
      holdSeconds = (int)(TimeCurrent()-g_posState.entryTime);
     }

   SAxStatsSnapshot snap = g_stats.Compute(g_autopsy,g_risk.DayStartEquity()>0?g_risk.DayStartEquity():AccountInfoDouble(ACCOUNT_EQUITY));
   ENUM_AX_GATE gate = g_stats.EvaluateGate(snap,InpMinTradesForGateSignal,InpMinTradesForValidation,InpMaxAcceptableDrawdownPct);

   ENUM_AX_ENGINE_STATE displayState = g_engineState;
   if(g_risk.IsKilled()) displayState = AX_ENGINE_KILLED;
   else if(g_risk.DailyLockout()) displayState = AX_ENGINE_PAUSED;
   else if(g_chop.IsInCooldown()) displayState = AX_ENGINE_COOLDOWN;

   SAxDashboardExtras extras;
   extras.htfRegime             = g_regimeHtf.Regime();
   extras.htfSlope              = g_regimeHtf.Slope();
   extras.accuracy5s            = g_accuracy.Accuracy(2); // AxAccHorizonsSec index 2 == 5 seconds
   extras.accuracy30s           = g_accuracy.Accuracy(4); // index 4 == 30 seconds
   extras.flipAccuracy          = g_accuracy.FlipAccuracy();
   extras.grossProfitFactor     = snap.grossProfitFactor;
   extras.adaptiveMultiplier    = g_adaptiveConfMultiplier;
   extras.partialTaken          = g_posState.partialTaken;
   extras.htfConfluenceEnabled  = InpRequireHtfConfluence;
   extras.isLiveAccount         = g_isLiveAccount;
   extras.avgSlippagePts        = (g_fillCount>0)? g_sumSlippagePts/g_fillCount : 0.0;
   extras.avgLatencyMs          = (g_fillCount>0)? g_sumLatencyMs/g_fillCount : 0.0;
   extras.poorFillsToday        = g_poorFillsToday;
   extras.consecutivePoorFills  = g_consecutivePoorFills;
   extras.sniperEnabled         = InpUseSniperEntry;
   extras.sniperArmed           = g_sniper.IsArmed();
   extras.sniperPullbackSeen    = g_sniper.PullbackSeen();
   extras.sniperSecondsWaiting  = g_sniper.SecondsWaiting();

   extras.orderFlowEnabled      = InpUseOrderFlow;
   extras.sessionCvd            = g_orderFlow.SessionCvd();
   extras.orderFlowImbalance    = g_orderFlow.ImbalanceRatio();
   extras.orderFlowPersistence  = g_orderFlow.FlowPersistence();
   extras.orderFlowAbsorptionStrength = g_orderFlow.AbsorptionStrength();
   extras.orderFlowDirectionalCoverage = g_orderFlow.DirectionalCoveragePct();
   extras.orderFlowEvidenceLabel = g_orderFlow.VolumeEvidenceLabel();
   extras.parentOrderPersistenceProxy = g_orderFlow.ParentOrderPersistenceProxy();
   extras.bullAbsorption        = g_orderFlow.BullishAbsorption();
   extras.bearAbsorption        = g_orderFlow.BearishAbsorption();
   extras.volProfileValid       = g_volProfile.IsValid();
   extras.volProfilePosition    = g_volProfile.Position(g_md.CurrentMid());
   extras.footprintStackedDir   = g_footprint.LastBarStackedDir();
   extras.pulseValue            = g_pulse.Value();
   extras.pulseDirection        = g_pulse.Direction();
   extras.pulseLabel            = g_pulse.Label();
   extras.heatmapEnabled        = InpUseHeatmap;
   extras.heatmapAvailable      = g_heatmap.IsAvailable();
   extras.heatmapBuyPressure    = g_heatmap.BuyWallPressure();
   extras.heatmapSellPressure   = g_heatmap.SellWallPressure();

   extras.afeEnabled             = InpUseAdaptiveFlipEngine;
   extras.afeState                = g_afe.State();
   extras.afeDrawdownFromPeakPct  = g_afe.DrawdownFromPeakPct();
   extras.afeRiskOfRuinPct        = g_afe.RiskOfRuinPct();
   extras.afeExpectedValueR       = g_afe.ExpectedValueR();
   extras.afeCostR                 = g_afe.CostR();
   extras.afeWinProbability       = g_afe.WinProbability();
   extras.afeAccountHealth        = g_afe.AccountHealth();
   extras.afeRiskMultiplier       = g_afe.LastRiskMultiplier();

   extras.impactCostEnabled       = InpUseImpactCostSizing;
   extras.impactCostPct           = g_posState.impactCostPct;

   extras.vwapTrend               = g_vwapTrend;
   extras.vwapValue               = g_vwapValue;
   extras.vwapExitEnabled         = InpUseVWAPExit;
   //--- reflects THIS position's own armed state, not just the global toggle - the exact flag        ---
   //--- CExitEngine gates its VWAP exit branch on (code-review finding: the dashboard previously      ---
   //--- showed [EXIT ARMED] off the toggle alone, even when this position's own vwapAlignedAtEntry      ---
   //--- was false and the exit could never fire for it) ---
   extras.vwapExitArmedForPosition = g_posState.active && g_posState.vwapAlignedAtEntry;

   extras.executionMode           = g_emergency.ExecutionMode();
   extras.enableTrading           = g_emergency.EnableTrading();
   extras.enableLong              = g_emergency.EnableLong();
   extras.enableShort             = g_emergency.EnableShort();
   extras.emergencyStopActive     = g_emergency.IsEmergencyStopActive();
   extras.emergencyStopReason     = g_emergency.EmergencyStopReason();

   extras.weeklyPnl               = g_risk.WeeklyPnL();
   extras.weeklyPnlPercent        = g_risk.WeeklyPnLPercent();
   extras.weeklyLockout           = g_risk.WeeklyLockout();
   extras.marginUsagePercent      = g_risk.MarginUsagePercent();

   // Closed-bar structure, volume-weighted MACD and economic-calendar news state now feed
   // the shared composite entry gate. The separate thesis eligibility and full lifecycle
   // state-machine modules remain dormant; existing live risk/reservation/execution controls remain active.
   extras.extendedEnginesIntegrated = false;

   g_dash.Render(InpMode,g_regime.Regime(),g_lastScore,g_mom.VelocityLabel(),
                 (g_mom.PersistentBull()?"BULLISH":g_mom.PersistentBear()?"BEARISH":"NEUTRAL"),
                 g_md.CurrentSpreadPts(),g_posState.dir,g_posState.entryPrice,curPrice,floatingPnl,
                 holdSeconds,g_risk.FlipsToday(),g_autopsy.Count(),snap,g_risk.DailyPnL(),
                 snap.maxDrawdownPercent,g_risk.RiskPercent(),displayState,gate,extras);
  }

//====================================================================
// CHART EVENTS: KILL ENGINE button
//====================================================================
// Broker-confirmed transaction observer. Campaign journaling below remains filtered to
// this EA's symbol+magic, while account-wide risk reconciliation observes every transaction.
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   // Every account transaction can change aggregate exposure, including manual trades,
   // other EAs, partial fills, pending-order updates/cancellations and netting reversals.
   // Do not trust request volume or callback ordering: dirty the snapshot and reconcile
   // against broker positions plus remaining pending volume on the next valid tick.
   g_accountRiskReconciliationPending=true;

   string symbol=trans.symbol;
   ulong magic=0;
   bool relevant=false;

   if(trans.type==TRADE_TRANSACTION_REQUEST)
     {
      symbol=request.symbol;
      magic=request.magic;
      relevant=(symbol==_Symbol && magic==InpMagicNumber);
     }
   else if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.deal>0 && HistoryDealSelect(trans.deal))
     {
      symbol=HistoryDealGetString(trans.deal,DEAL_SYMBOL);
      magic=(ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
      relevant=(symbol==_Symbol && magic==InpMagicNumber);

      // Entry deals dirty the campaign ledger. Do not register from request/result data:
      // defer until OnTick can read the actual broker position and validate its protective SL.
      if(relevant && HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_IN)
        {
         g_pyramidReady=false;
         g_pyramidReconcilePending=true;
        }

      // A DEAL_ADD is a broker-confirmed fill, but MT5 may deliver several deal/order
      // transactions for one request and their order is not guaranteed. Only finalize
      // when the deal is an exit, our tracked campaign is active, and the symbol no
      // longer has a live position. Partial closes leave a live position and are left
      // to the existing volume/history accounting path; entry deals never finalize.
      if(relevant && g_haveOpenPosition && g_posState.active &&
         g_positionIdentifier>0 &&
         (ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID)==g_positionIdentifier)
        {
         long dealEntry=HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
         bool isExit=(dealEntry==DEAL_ENTRY_OUT || dealEntry==DEAL_ENTRY_OUT_BY ||
                      dealEntry==DEAL_ENTRY_INOUT);
         if(dealEntry==DEAL_ENTRY_INOUT)
           {
            g_recoveryReady=false;
            g_nettingReversalQuarantined=true;
            g_accountRiskReconciliationPending=true;
            PrintFormat("FLIPDEMON RECONCILIATION ERROR: broker reported netting reversal deal %I64u; old campaign and residual opposite exposure are quarantined. No stale-side management will run.",trans.deal);
           }
         // INOUT changes the broker's net position ticket while preserving its
         // POSITION_IDENTIFIER. It is not a flat-position event. Keep the old campaign
         // quarantined instead of sending its deal history through ordinary close logic.
         if(isExit && dealEntry!=DEAL_ENTRY_INOUT && !PositionSelectByTicket(g_posState.ticket))
           {
            double closePrice=0,grossProfit=0,commission=0,swap=0;
            datetime closeTime=0;
            ulong lastDealTicket=0;
            double closedVolume=0.0;
            // Do not finalize on a transient history-cache miss: that would record a
            // zero-PnL fallback as a real result. Let OnTick retry the established
            // external-close path when complete close-deal history is available.
            if(AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket,
                                      closePrice,grossProfit,commission,swap,closeTime,lastDealTicket,closedVolume))
              {
               double distToSl=MathAbs(closePrice-g_posState.initialSlPrice);
               double distToTp=MathAbs(closePrice-g_posState.initialTpPrice);
               ENUM_AX_EXIT_REASON exitReason=(distToTp<distToSl)?AX_EXIT_TP:AX_EXIT_SL;
               PrintFormat("FLIPDEMON TRANSACTION: final exit deal=%I64u; financial history confirmed.",
                           trans.deal);
               AxFinalizeTrade(closePrice,grossProfit,commission,swap,closeTime,exitReason,lastDealTicket);
              }
            else
               PrintFormat("FLIPDEMON TRANSACTION: final exit deal=%I64u; history not ready, deferring reconciliation.",
                           trans.deal);
           }
        }
     }
   else if(trans.type==TRADE_TRANSACTION_HISTORY_ADD &&
           trans.order>0 && HistoryOrderSelect(trans.order))
     {
      // HISTORY_ADD is an order-history lifecycle event, not proof of a fill.
      // It only dirties/reconciles the broker snapshot. Deal tickets remain the
      // sole source for campaign volume, entry price and realized trade accounting.
      g_accountRiskReconciliationPending=true;
      symbol=HistoryOrderGetString(trans.order,ORDER_SYMBOL);
      magic=(ulong)HistoryOrderGetInteger(trans.order,ORDER_MAGIC);
      relevant=(symbol==_Symbol && magic==InpMagicNumber);

      // Some delayed broker outcomes arrive as order-history transactions rather
      // than a second REQUEST callback. Only a terminal rejected/cancelled/expired
      // order with this EA's exact comment can queue the same deferred resolution.
      long orderState=HistoryOrderGetInteger(trans.order,ORDER_STATE);
      string orderComment=HistoryOrderGetString(trans.order,ORDER_COMMENT);
      bool terminalWithoutFill=(orderState==ORDER_STATE_CANCELED ||
                                orderState==ORDER_STATE_REJECTED ||
                                orderState==ORDER_STATE_EXPIRED);
      if(relevant && orderComment=="AXFDX" && terminalWithoutFill &&
         g_distributedRecoveryPending && g_distributedRiskCoordinator.HasPendingJournal())
        {
         g_distributedRejectedCallbackPending=true;
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: terminal order-history rejection/cancellation observed (order=%I64u state=%d); deferred snapshot reconciliation queued.",
                     trans.order,orderState);
        }
     }

   // Only a definitive response to this EA's own fresh market-deal request
   // can resolve an ambiguous reservation. Accepted/partial/placed and transport-
   // ambiguous responses are deliberately excluded. No HTTP or file I/O occurs
   // inside this callback; OnTimer performs the fresh snapshot and release.
   if(trans.type==TRADE_TRANSACTION_REQUEST && relevant &&
      request.action==TRADE_ACTION_DEAL && request.comment=="AXFDX" &&
      g_distributedRiskCoordinator.HasPendingJournal())
     {
      bool accepted=(result.retcode==TRADE_RETCODE_DONE ||
                     result.retcode==TRADE_RETCODE_DONE_PARTIAL ||
                     result.retcode==TRADE_RETCODE_PLACED);
      bool ambiguous=(result.retcode==TRADE_RETCODE_TIMEOUT ||
                      result.retcode==TRADE_RETCODE_CONNECTION ||
                      result.retcode==0);
      if(!accepted && !ambiguous)
        {
         g_distributedRejectedCallbackPending=true;
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: definitive broker rejection callback received (retcode=%u); deferred snapshot reconciliation queued.",
                     result.retcode);
        }
     }

   if(relevant && g_iq200TelemetryReady)
     {
      SAxIQ200Event telemetryEvent;
      if(trans.type==TRADE_TRANSACTION_REQUEST)
        {
         g_iq200Telemetry.NewEvent(telemetryEvent,AX_IQ200_BROKER_ACK,symbol,magic);
         telemetryEvent.orderTicket=result.order;
         telemetryEvent.dealTicket=result.deal;
         telemetryEvent.decisionId=g_iq200Telemetry.DecisionIdForOrder(result.order);
         telemetryEvent.intentId=telemetryEvent.decisionId;
         telemetryEvent.retcode=result.retcode;
         telemetryEvent.retcodeExternal=result.retcode_external;
         telemetryEvent.requestedVolume=request.volume;
         telemetryEvent.requestedPrice=request.price;
         telemetryEvent.direction=(request.type==ORDER_TYPE_BUY)?1:
                                  (request.type==ORDER_TYPE_SELL)?-1:0;
         telemetryEvent.orderType=(int)request.type;
         telemetryEvent.reasonCode=(int)request.action;
         MqlTick ackTick;
         if(SymbolInfoTick(symbol,ackTick))
           {
            telemetryEvent.bid=ackTick.bid;
            telemetryEvent.ask=ackTick.ask;
            telemetryEvent.eventTimeMsc=(long)ackTick.time_msc;
            telemetryEvent.timeSource=1;
           }
         g_iq200Telemetry.Enqueue(telemetryEvent);
        }
      else if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.deal>0 &&
              HistoryDealSelect(trans.deal) &&
              HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_IN &&
              g_iq200Telemetry.RecordConfirmedEntryDeal(
                 trans.deal,
                 (long)HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC),
                 HistoryDealGetDouble(trans.deal,DEAL_VOLUME)))
        {
         // Capture the current deal before selecting the complete position history.
         ulong dealOrder=(ulong)HistoryDealGetInteger(trans.deal,DEAL_ORDER);
         ulong positionId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
         double dealVolume=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
         double dealPrice=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
         long dealType=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
         long dealTimeMsc=HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
         // Feed measured adverse execution slippage into the observational feedback engine.
         // If the broker does not retain a valid requested order price, skip the sample.
         double requestedOrderPrice=0.0;
         double symbolPoint=SymbolInfoDouble(symbol,SYMBOL_POINT);
         if(dealOrder>0 && HistoryOrderSelect(dealOrder))
            requestedOrderPrice=HistoryOrderGetDouble(dealOrder,ORDER_PRICE_OPEN);
         if(requestedOrderPrice>0.0 && symbolPoint>0.0 &&
            MathIsValidNumber(requestedOrderPrice) && MathIsValidNumber(dealPrice))
           {
            double signedSlippage=(dealType==DEAL_TYPE_BUY)
                                  ?(dealPrice-requestedOrderPrice)/symbolPoint
                                  :(requestedOrderPrice-dealPrice)/symbolPoint;
            g_executionFeedback.RecordFill(MathMax(0.0,signedSlippage));
           }

         // Reconcile cumulative entry volume for this exact order. A DEAL_ADD callback
         // is one execution slice, not proof that the whole order has filled.
         double cumulativeEntryVolume=0.0;
         double cumulativeEntryPriceValue=0.0;
         double requestedOrderVolume=0.0;
         if(dealOrder>0 && HistoryOrderSelect(dealOrder))
            requestedOrderVolume=HistoryOrderGetDouble(dealOrder,ORDER_VOLUME_INITIAL);
         if(positionId>0 && HistorySelectByPosition((long)positionId))
           {
            int positionDeals=HistoryDealsTotal();
            for(int dealIndex=0;dealIndex<positionDeals;dealIndex++)
              {
               ulong historyDeal=HistoryDealGetTicket(dealIndex);
               if(historyDeal==0 ||
                  (ulong)HistoryDealGetInteger(historyDeal,DEAL_ORDER)!=dealOrder ||
                  HistoryDealGetInteger(historyDeal,DEAL_ENTRY)!=DEAL_ENTRY_IN ||
                  HistoryDealGetString(historyDeal,DEAL_SYMBOL)!=symbol ||
                  (ulong)HistoryDealGetInteger(historyDeal,DEAL_MAGIC)!=magic)
                  continue;
               long historyType=HistoryDealGetInteger(historyDeal,DEAL_TYPE);
               if((dealType==DEAL_TYPE_BUY && historyType!=DEAL_TYPE_BUY) ||
                  (dealType==DEAL_TYPE_SELL && historyType!=DEAL_TYPE_SELL))
                  continue;
               double historyVolume=HistoryDealGetDouble(historyDeal,DEAL_VOLUME);
               double historyPrice=HistoryDealGetDouble(historyDeal,DEAL_PRICE);
               if(historyVolume>0.0 && historyPrice>0.0 &&
                  MathIsValidNumber(historyVolume) && MathIsValidNumber(historyPrice))
                 {
                  cumulativeEntryVolume+=historyVolume;
                  cumulativeEntryPriceValue+=historyVolume*historyPrice;
                 }
              }
           }
         double volumeStep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
         double volumeTolerance=MathMax(volumeStep*0.51,0.00000001);
         bool orderFullyFilled=(requestedOrderVolume>0.0 &&
                                cumulativeEntryVolume>0.0 &&
                                cumulativeEntryVolume+volumeTolerance>=requestedOrderVolume);
         int fillEventType=orderFullyFilled?AX_IQ200_DEAL_FILLED:AX_IQ200_DEAL_PARTIAL;

         g_iq200Telemetry.NewEvent(telemetryEvent,fillEventType,symbol,magic);
         telemetryEvent.orderTicket=dealOrder;
         telemetryEvent.dealTicket=trans.deal;
         telemetryEvent.decisionId=g_iq200Telemetry.DecisionIdForOrder(dealOrder);
         telemetryEvent.intentId=telemetryEvent.decisionId;
         telemetryEvent.positionIdentifier=positionId;
         telemetryEvent.requestedVolume=requestedOrderVolume;
         telemetryEvent.confirmedVolume=(cumulativeEntryVolume>0.0)?cumulativeEntryVolume:dealVolume;
         telemetryEvent.fillPrice=(cumulativeEntryVolume>0.0)
                                    ?cumulativeEntryPriceValue/cumulativeEntryVolume:dealPrice;
         telemetryEvent.direction=(dealType==DEAL_TYPE_BUY)?1:
                                  (dealType==DEAL_TYPE_SELL)?-1:0;
         telemetryEvent.eventTimeMsc=dealTimeMsc;
         telemetryEvent.timeSource=(dealTimeMsc>0)?1:2;
         if(dealTimeMsc<=0) telemetryEvent.missingMask|=8;
         MqlTick fillTick;
         telemetryEvent.pointSize=SymbolInfoDouble(symbol,SYMBOL_POINT);
         telemetryEvent.tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
         if(SymbolInfoTick(symbol,fillTick))
           {
            telemetryEvent.bid=fillTick.bid;
            telemetryEvent.ask=fillTick.ask;
           }
         if(requestedOrderVolume<=0.0)
            telemetryEvent.missingMask|=1;
         if(g_iq200Telemetry.Enqueue(telemetryEvent))
           {
            // Measure each confirmed deal at its own execution price and volume.
            // The CSV fill event above retains the cumulative order VWAP separately.
            SAxIQ200Event markoutBasis=telemetryEvent;
            markoutBasis.fillPrice=dealPrice;
            markoutBasis.confirmedVolume=dealVolume;
            g_iq200Telemetry.ScheduleMarkouts(markoutBasis);
           }
        }
      else if(trans.type==TRADE_TRANSACTION_DEAL_ADD && trans.deal>0 &&
              HistoryDealSelect(trans.deal) &&
              (HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_OUT ||
               HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_OUT_BY) &&
              trans.position>0 && !PositionSelectByTicket(trans.position) &&
              g_iq200Telemetry.MarkDealTicketSeen(trans.deal))
        {
         // A position-close event is emitted only after the broker position ticket
         // is absent. Partial exits are not mislabeled as completed campaigns.
         ulong closeOrder=(ulong)HistoryDealGetInteger(trans.deal,DEAL_ORDER);
         ulong positionId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
         double closeVolume=HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
         double closePrice=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
         long closeType=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
         long closeTimeMsc=HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
         g_iq200Telemetry.NewEvent(telemetryEvent,AX_IQ200_POSITION_CLOSED,symbol,magic);
         telemetryEvent.orderTicket=closeOrder;
         telemetryEvent.dealTicket=trans.deal;
         telemetryEvent.positionIdentifier=positionId;
         telemetryEvent.decisionId=g_iq200Telemetry.DecisionIdForOrder(closeOrder);
         telemetryEvent.intentId=telemetryEvent.decisionId;
         telemetryEvent.direction=(closeType==DEAL_TYPE_SELL)?1:-1;
         telemetryEvent.confirmedVolume=closeVolume;
         telemetryEvent.fillPrice=closePrice;
         telemetryEvent.pointSize=SymbolInfoDouble(symbol,SYMBOL_POINT);
         telemetryEvent.tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
         telemetryEvent.eventTimeMsc=closeTimeMsc;
         telemetryEvent.timeSource=1;
         if(closeVolume<=0.0 || closePrice<=0.0)
            telemetryEvent.missingMask|=4;
         g_iq200Telemetry.Enqueue(telemetryEvent);
        }
      else if(trans.type==TRADE_TRANSACTION_HISTORY_ADD && trans.order>0 && HistoryOrderSelect(trans.order))
        {
         long observedState=HistoryOrderGetInteger(trans.order,ORDER_STATE);
         int observedEvent=-1;
         if(observedState==ORDER_STATE_CANCELED) observedEvent=AX_IQ200_ORDER_CANCELLED;
         else if(observedState==ORDER_STATE_REJECTED) observedEvent=AX_IQ200_ORDER_REJECTED;
         else if(observedState==ORDER_STATE_EXPIRED) observedEvent=AX_IQ200_ORDER_EXPIRED;
         if(observedEvent>=0)
           {
            g_iq200Telemetry.NewEvent(telemetryEvent,observedEvent,symbol,magic);
            telemetryEvent.orderTicket=trans.order;
            telemetryEvent.decisionId=g_iq200Telemetry.DecisionIdForOrder(trans.order);
            telemetryEvent.intentId=telemetryEvent.decisionId;
            telemetryEvent.orderType=(int)HistoryOrderGetInteger(trans.order,ORDER_TYPE);
            telemetryEvent.requestedVolume=HistoryOrderGetDouble(trans.order,ORDER_VOLUME_INITIAL);
            double remainingVolume=HistoryOrderGetDouble(trans.order,ORDER_VOLUME_CURRENT);
            telemetryEvent.confirmedVolume=MathMax(0.0,telemetryEvent.requestedVolume-remainingVolume);
            telemetryEvent.reasonCode=(int)observedState;
            g_iq200Telemetry.Enqueue(telemetryEvent);
           }
        }
     }

   if(!relevant) return;
   PrintFormat("FLIPDEMON EXTREME HFT | %s",
               g_tradeReconciler.Classify(trans,request,result));
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(!g_dash.IsKillButtonClick(sparam)) return;

   g_risk.ActivateKillSwitch("Manual KILL ENGINE button");
   g_engineState = AX_ENGINE_KILLED;
   if(g_haveOpenPosition && InpCloseAllOnKill)
      AxCloseAndRecord(AX_EXIT_MANUAL_KILL);
   g_dash.ResetKillButtonState();
   Print("AUTOPSY X: KILL ENGINE activated - all new entries disabled");
  }
//+------------------------------------------------------------------+
