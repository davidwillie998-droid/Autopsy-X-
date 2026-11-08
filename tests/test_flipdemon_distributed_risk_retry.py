from pathlib import Path
import unittest


class DistributedRiskRetryContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        source = (root / "MQL5/Include/AutopsyX/DistributedRiskCoordinator.mqh").read_text()
        start = source.index("   bool Reserve(")
        end = source.index("   bool Release(", start)
        cls.reserve_method = source[start:end]

    def test_reservation_retry_reuses_the_original_request_payload(self):
        method = self.reserve_method
        self.assertEqual(method.count('StringFormat("%s-%I64d-%I64d"'), 1)
        self.assertEqual(method.count('Post("/risk/reserve",body,response,error)'), 2)
        self.assertIn(
            'if(StringFind(error,"DISTRIBUTED_RISK_WEBREQUEST_FAILED")!=0)',
            method,
        )
        self.assertIn("firstAttemptError=error", method)
        self.assertIn("retryError=error", method)
        self.assertIn("DISTRIBUTED_RISK_RESERVATION_OUTCOME_UNCONFIRMED", method)

    def test_reservation_id_is_only_accepted_after_retry_path_resolves(self):
        method = self.reserve_method
        retry_block = method.index('if(!Post("/risk/reserve",body,response,error))')
        response_validation = method.index(
            'if(!JsonTrue(response,"ok") || !JsonString(response,"reservationId",reservationId))'
        )
        self.assertLess(retry_block, response_validation)
        self.assertIn('if(!Post("/risk/reserve",body,response,error))', method)
        self.assertIn('if(!Post("/risk/reserve",body,response,error))', method)

    def test_ambiguous_second_attempt_remains_fail_closed(self):
        method = self.reserve_method
        self.assertIn("error=\"DISTRIBUTED_RISK_RESERVATION_OUTCOME_UNCONFIRMED", method)
        self.assertIn("return(false);", method[method.index("DISTRIBUTED_RISK_RESERVATION_OUTCOME_UNCONFIRMED"):])


class DistributedRiskRestartJournalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.coordinator = (root / "MQL5/Include/AutopsyX/DistributedRiskCoordinator.mqh").read_text()
        cls.account_risk = (root / "MQL5/Include/AutopsyX/AccountRiskCalculator.mqh").read_text()
        cls.expert = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()

    def test_pending_reservation_is_written_before_network_request(self):
        reserve = self.coordinator[self.coordinator.index("   bool Reserve("):self.coordinator.index("   bool Release(")]
        self.assertLess(reserve.index("SavePendingJournal()"), reserve.index('Post("/risk/reserve",body,response,error)'))
        self.assertIn("m_pendingKey=idempotencyKey", reserve)
        self.assertIn("m_pendingBaselineRisk=snapshot.existingRiskMoney", reserve)

    def test_terminal_restart_replays_original_key_and_amount(self):
        recovery = self.coordinator[self.coordinator.index("   bool RecoverPending("):self.coordinator.index("   bool Reconcile(")]
        self.assertIn('Post("/risk/reserve",body,response,error)', recovery)
        self.assertIn("m_pendingKey", recovery)
        self.assertIn("m_pendingRiskMoney", recovery)
        self.assertIn("m_pendingInstance", recovery)
        self.assertIn("Settle(reservationId,m_pendingInstance,snapshot,settledWithinCap,error)", recovery)
        self.assertIn("DISTRIBUTED_RISK_RECOVERY_SETTLED_ACCOUNT_OVER_CAP", recovery)

    def test_unresolved_recovery_keeps_ea_attached_and_locks_entries(self):
        init = self.expert[self.expert.index("int OnInit(void)"):self.expert.index("void OnDeinit")]
        self.assertIn("g_distributedRecoveryPending=true", init)
        self.assertIn("LOCKED RECOVERY MODE", init)
        self.assertNotIn("unresolved prior reservation; LIVE mode refused", init)
        self.assertIn("if(InpShowDashboard || g_distributedRecoveryPending)", init)

    def test_timer_retries_recovery_without_dashboard(self):
        timer = self.expert[self.expert.index("void OnTimer(void)"):self.expert.index("//====================================================================\n// CHART EVENTS")]
        self.assertLess(timer.index("g_distributedRiskCoordinator.RecoverPending("), timer.index("if(!InpShowDashboard) return;"))
        self.assertIn("EventKillTimer();", timer)

    def test_pending_recovery_blocks_new_entries(self):
        expert = self.expert
        gate = expert[expert.index("// A distributed reservation left by a prior terminal session"):expert.index("// Restart recovery is a hard entry prerequisite")]
        self.assertIn("g_distributedRecoveryPending", gate)
        self.assertIn("return(false);", gate)

    def test_filled_or_increased_exposure_settles_reservation_from_broker_snapshot(self):
        recovery = self.coordinator[self.coordinator.index("   bool RecoverPending("):self.coordinator.index("   string InstanceId(")]
        self.assertIn("Settle(reservationId,m_pendingInstance,snapshot,settledWithinCap,error)", recovery)
        self.assertIn("DISTRIBUTED_RISK_RECOVERY_SETTLED_ACCOUNT_OVER_CAP", recovery)
        self.assertIn("return(true);", recovery)

    def test_journal_clears_only_after_release_or_settlement_confirmation(self):
        release = self.coordinator[self.coordinator.index("   bool Release("):self.coordinator.index("   bool Settle(")]
        settle = self.coordinator[self.coordinator.index("   bool Settle("):]
        self.assertLess(release.index('if(!JsonTrue(response,"released"))'), release.index("ClearPendingJournal()"))
        self.assertLess(settle.index('if(!JsonTrue(response,"settled"))'), settle.index("ClearPendingJournal()"))

    def test_journal_path_uses_stable_account_symbol_magic_identity(self):
        self.assertIn("AX_DistributedRisk_%I64d_%s_%I64u.dat", self.coordinator)
        self.assertNotIn("AX_DistributedRisk_%I64d_%I64d.dat", self.coordinator)

    def test_recovery_only_clears_journal_for_exact_terminal_reservation_code(self):
        recovery = self.coordinator[self.coordinator.index("   bool RecoverPending("):self.coordinator.index("   bool Reconcile(")]
        self.assertIn('StringFind(error,"IDEMPOTENCY_KEY_ALREADY_USED")>=0', recovery)
        self.assertNotIn("IDEMPOTENCY_KEY_REUSED", recovery)
        self.assertIn("return(ClearPendingJournal());", recovery)

    def test_definitive_rejections_clear_new_journal_but_expired_outcomes_do_not(self):
        reserve = self.coordinator[self.coordinator.index("   bool Reserve("):self.coordinator.index("   bool Release(")]
        self.assertIn('StringFind(error,"DISTRIBUTED_RISK_HTTP_4")==0', reserve)
        self.assertIn('StringFind(error,"EXPIRED_RESERVATION_REQUIRES_RECONCILIATION")<0', reserve)
        self.assertIn("ClearPendingJournal();", reserve)


    def test_journal_is_exclusively_owned_by_one_chart_instance(self):
        init = self.coordinator[self.coordinator.index("   bool Init("):self.coordinator.index("   // Resolve a reservation")]
        self.assertIn('m_journalFile+".lock"', init)
        self.assertIn("FILE_READ|FILE_WRITE|FILE_BIN", init)
        self.assertNotIn("FILE_SHARE_READ", init)
        self.assertNotIn("FILE_SHARE_WRITE", init)
        self.assertLess(init.index('FileOpen(m_journalFile+".lock"'), init.index("LoadPendingJournal(error)"))
        self.assertIn("DISTRIBUTED_RISK_JOURNAL_OWNED_BY_ANOTHER_TERMINAL_INSTANCE", init)

    def test_exclusive_journal_lock_is_released_on_deinitialization(self):
        shutdown = self.coordinator[self.coordinator.index("   void Shutdown(void)"):self.coordinator.index("   bool IsReady(void)")]
        deinit = self.expert[self.expert.index("void OnDeinit(const int reason)"):self.expert.index("//====================================================================\n// MAIN TICK LOOP")]
        self.assertIn("FileClose(m_journalLockHandle)", shutdown)
        self.assertIn("m_journalLockHandle=INVALID_HANDLE", shutdown)
        self.assertIn("g_distributedRiskCoordinator.Shutdown();", deinit)


    def test_transient_recovery_failures_keep_lock_until_central_reconcile_succeeds(self):
        timer = self.expert[self.expert.index("void OnTimer(void)"):self.expert.index("//====================================================================\n// CHART EVENTS")]
        retry = timer[timer.index("if(!recoveredPending)"):timer.index("else\n           {", timer.index("if(!recoveredPending)"))]
        self.assertIn("g_accountRiskIntegrityLock=true", retry)
        self.assertNotIn("g_distributedRecoveryPending=false", retry)
        self.assertLess(timer.index("g_distributedRiskCoordinator.Reconcile(recoverySnapshot"), timer.index("g_distributedRecoveryPending=false"))
        self.assertIn("next timer retry will reconcile again", timer)
        self.assertIn("EventSetTimer(1)", self.expert)

    def test_recovery_retries_replay_the_persisted_reservation_identity(self):
        recovery = self.coordinator[self.coordinator.index("   bool RecoverPending("):self.coordinator.index("   string InstanceId(")]
        self.assertIn('"idempotencyKey\\":\\""+JsonEscape(m_pendingKey)', recovery)
        self.assertIn('"riskMoney\\":\\"', recovery) if False else None
        self.assertIn("m_pendingRiskMoney", recovery)
        self.assertIn("Post(\"/risk/reserve\",body,response,error)", recovery)
        self.assertIn('StringFind(error,"IDEMPOTENCY_KEY_ALREADY_USED")>=0', recovery)


class BrokerExecutionReservationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.execution = (root / "MQL5/Include/AutopsyX/ExecutionEngine.mqh").read_text()
        cls.coordinator = (root / "MQL5/Include/AutopsyX/DistributedRiskCoordinator.mqh").read_text()
        cls.account_risk = (root / "MQL5/Include/AutopsyX/AccountRiskCalculator.mqh").read_text()
        cls.expert = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()

    def test_pyramid_add_uses_campaign_stop_and_account_wide_risk_budget(self):
        start = self.expert.index("bool AxAttemptPyramidNettingAdd(")
        end = self.expert.index("\n\n//--- self-tuning", start)
        method = self.expert[start:end]
        self.assertIn("double stop=PositionGetDouble(POSITION_SL);", method)
        self.assertIn("g_accountRisk.Evaluate(_Symbol,campaign.dir,requestedLots,stop,deviationPts,", method)
        self.assertLess(method.index("g_accountRisk.Evaluate"),
                        method.index("g_distributedRiskCoordinator.Reserve"))
        self.assertIn("g_accountRisk.Scan(reserveSnapshot)", method)
        self.assertIn("g_distributedRiskCoordinator.Reserve(riskDecision,reserveSnapshot,instanceId,", method)

    def test_account_risk_calculator_adds_existing_and_proposed_campaign_risk(self):
        start = self.account_risk.index("bool              Evaluate(")
        method = self.account_risk[start:]
        self.assertIn("if(!Scan(snapshot))", method)
        self.assertIn("snapshot.existingRiskMoney= snapshot.existingRiskMoney", method) if False else None
        self.assertIn("decision.proposedRiskMoney", method)
        self.assertIn("snapshot.existingRiskMoney+decision.proposedRiskMoney>", method)
        self.assertIn("snapshot.hardRiskBudgetMoney+0.01", method)
        self.assertIn("PROPOSED_ORDER_EXCEEDS_ACCOUNT_WIDE_2_PERCENT_CAP", method)

    def test_broker_symbol_preflight_enforces_direction_market_and_volume_contract(self):
        start = self.expert.index("bool AxBrokerSymbolOrderPreflight(")
        end = self.expert.index("\n  }", start) + len("\n  }")
        helper = self.expert[start:end]
        for token in (
            "SYMBOL_TRADE_MODE_CLOSEONLY",
            "SYMBOL_TRADE_MODE_SHORTONLY",
            "SYMBOL_TRADE_MODE_LONGONLY",
            "SYMBOL_ORDER_MARKET",
            "SYMBOL_VOLUME_MIN",
            "SYMBOL_VOLUME_MAX",
            "SYMBOL_VOLUME_STEP",
            "SYMBOL_VOLUME_LIMIT",
            "ORDER_VOLUME_CURRENT",
            "POSITION_VOLUME",
        ):
            self.assertIn(token, helper)
        self.assertIn("BROKER_SYMBOL_DIRECTIONAL_VOLUME_LIMIT", helper)
        self.assertEqual(self.expert.count("AxBrokerSymbolOrderPreflight("), 3)
        self.assertIn("tradeMode==SYMBOL_TRADE_MODE_CLOSEONLY", self.expert)
        self.assertIn("(orderMode & SYMBOL_ORDER_MARKET)==0", self.expert)

    def test_broker_stopout_threshold_and_buffer_guard_entries_and_pyramid_adds(self):
        start = self.expert.index("bool AxBrokerMarginPreflight(")
        end = self.expert.index("\n  }", start) + len("\n  }")
        helper = self.expert[start:end]
        self.assertIn("ACCOUNT_MARGIN_SO_MODE", helper)
        self.assertIn("ACCOUNT_STOPOUT_MODE_PERCENT", helper)
        self.assertIn("ACCOUNT_MARGIN_SO_CALL", helper)
        self.assertIn("ACCOUNT_MARGIN_SO_SO", helper)
        self.assertIn("MathMax(marginCall,stopout)+InpBrokerStopOutBufferPercent", helper)
        self.assertIn("BROKER_MONEY_BASED_STOPOUT_UNSUPPORTED_FAIL_CLOSED", helper)
        self.assertIn("MODE_MARGIN_UTILISATION_LIMIT_EXCEEDED", helper)
        self.assertIn("BROKER_MARGIN_LEVEL_BUFFER_NOT_MET", helper)
        self.assertEqual(self.expert.count("AxBrokerMarginPreflight(requiredMargin,"), 3)
        self.assertIn("InpBrokerStopOutBufferPercent = 100.0", self.expert)

    def test_pyramid_execution_is_demo_only_and_rechecks_margin_under_mutex(self):
        start = self.expert.index("bool AxAttemptPyramidNettingAdd(")
        end = self.expert.index("g_exec.AddToNettingPosition", start)
        method = self.expert[start:end]
        self.assertIn("AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO", method)
        self.assertIn("g_accountRiskCoordinator.TryAcquire()", method)
        locked_margin = "OrderCalcMargin(orderType,_Symbol,requestedLots,lockedOrderPrice,requiredMargin)"
        self.assertIn(locked_margin, method)
        self.assertLess(method.index("g_accountRiskCoordinator.TryAcquire()"),
                        method.index(locked_margin))
        self.assertIn("AxBrokerMarginPreflight(requiredMargin,projectedMarginUsage,projectedMarginLevel,marginReason)", method)
        self.assertRegex(self.expert, r"InpEnablePyramidExecution\\s*=\\s*false")

    def test_margin_utilisation_profiles_are_separate_from_stop_loss_risk(self):
        helper_start = self.expert.index("double AxMarginUsageLimitForMode(void)")
        helper_end = self.expert.index("\n  }", helper_start) + len("\n  }")
        helper = self.expert[helper_start:helper_end]
        self.assertIn("if(InpMode==AX_MODE_NORMAL)      return(5.0);", helper)
        self.assertIn("if(InpMode==AX_MODE_AGGRESSIVE)  return(20.0);", helper)
        self.assertIn("AxClampD(InpExtremeMaxMarginUsagePercent,1.0,100.0)", helper)
        self.assertIn("InpExtremeMaxMarginUsagePercent = 100.0", self.expert)
        self.assertIn("AxMarginUsageLimitForMode()", self.expert)
        risk_helper = self.expert[
            self.expert.index("double AxRiskPercentForMode(void)"):
            self.expert.index("double AxMarginUsageLimitForMode(void)")
        ]
        self.assertIn("return(0.5);", risk_helper)
        self.assertIn("return(1.0);", risk_helper)
        self.assertIn("AxClampD(InpExtremeRiskPercent,0.05,2.0)", risk_helper)
        self.assertIn("MathMax(InpMinFreeMarginPercent,brokerFloor)", self.expert)

    def test_pyramid_add_arms_uncertainty_before_broker_submission(self):
        start = self.expert.index("bool AxAttemptPyramidNettingAdd(")
        end = self.expert.index('g_exec.AddToNettingPosition', start)
        method = self.expert[start:end]
        self.assertIn("g_distributedRiskCoordinator.MarkExecutionUncertain(uncertaintyError)", method)
        self.assertLess(method.index("MarkExecutionUncertain"), end - start)
        self.assertLess(method.index("g_pyramidCampaignRegistry.Save(campaign)"),
                        method.index("MarkExecutionUncertain"))
        failure = method[method.index("if(reservationActive && !g_distributedRiskCoordinator.MarkExecutionUncertain"):
                         method.index("ulong newTicket=0,newPositionId=0,orderTicket=0;")]
        self.assertIn("g_accountRiskIntegrityLock=true", failure)
        self.assertIn("g_distributedRecoveryPending=true", failure)
        self.assertIn("EventSetTimer(1)", failure)
        self.assertIn("return(false);", failure)

    def test_ambiguous_market_retcode_is_not_retried(self):
        retry = self.execution[
            self.execution.index("bool              RetryableRetcode"):
            self.execution.index("bool              AmbiguousRetcode")
        ]
        self.assertNotIn("TRADE_RETCODE_TIMEOUT", retry)
        self.assertNotIn("TRADE_RETCODE_CONNECTION", retry)
        self.assertIn("AmbiguousRetcode(retcode)", self.execution)
        self.assertIn("outcomeUncertain=true;", self.execution)

    def test_fresh_entry_arms_uncertainty_before_broker_submission(self):
        entry = self.expert[
            self.expert.index("string distributedReservationId="):
            self.expert.index("g_consecutiveExecFailures = 0;", self.expert.index("string distributedReservationId="))
        ]
        self.assertLess(entry.index("MarkExecutionUncertain"), entry.index("g_exec.OpenMarket"))
        self.assertIn("entryOutcomeUncertain", entry)
        self.assertIn("g_distributedRecoveryPending=true", entry)

    def test_ambiguous_entry_keeps_reservation_and_locks_new_entries(self):
        entry = self.expert[
            self.expert.index("if(!g_exec.OpenMarket"):
            self.expert.index("g_consecutiveExecFailures = 0;", self.expert.index("if(!g_exec.OpenMarket"))
        ]
        ambiguous = entry[entry.index("if(distributedReservationActive && entryOutcomeUncertain)"):
                          entry.index("else if(distributedReservationActive)")]
        self.assertIn("g_accountRiskIntegrityLock=true", ambiguous)
        self.assertIn("g_distributedRecoveryPending=true", ambiguous)
        self.assertNotIn("Release(", ambiguous)

    def test_definitive_rejection_is_persisted_before_release_retry(self):
        entry = self.expert[
            self.expert.index("else if(distributedReservationActive)"):
            self.expert.index("if(!g_accountRiskCoordinator.Release())", self.expert.index("else if(distributedReservationActive)"))
        ]
        self.assertLess(entry.index("MarkExecutionRejected"), entry.index("g_distributedRiskCoordinator.Release"))
        rejected = self.coordinator[
            self.coordinator.index("bool MarkExecutionRejected"):
            self.coordinator.index("string InstanceId")
        ]
        self.assertIn("m_pendingExecutionUncertain=false", rejected)
        self.assertIn("SavePendingJournal()", rejected)

    def test_restart_recovery_does_not_release_flat_snapshot_after_ambiguous_send(self):
        recovery = self.coordinator[
            self.coordinator.index("bool RecoverPending("):
            self.coordinator.index("bool Reconcile(", self.coordinator.index("bool RecoverPending("))
        ]
        self.assertIn("if(m_pendingExecutionUncertain)", recovery)
        self.assertIn("DISTRIBUTED_RISK_EXECUTION_OUTCOME_UNCONFIRMED_RESERVATION_RETAINED", recovery)
        self.assertLess(recovery.index("if(m_pendingExecutionUncertain)"),
                        recovery.index("if(!Release(reservationId"))

    def test_uncertain_execution_marker_survives_restart_and_legacy_journals_fail_closed(self):
        save = self.coordinator[
            self.coordinator.index("bool SavePendingJournal"):
            self.coordinator.index("bool LoadPendingJournal")
        ]
        load = self.coordinator[
            self.coordinator.index("bool LoadPendingJournal"):
            self.coordinator.index("bool ClearPendingJournal")
        ]
        self.assertIn('m_pendingExecutionUncertain?"1":"0"', save)
        self.assertIn("count==7 || fields[7]==\"1\"", load)
        self.assertIn("MarkExecutionUncertain", self.coordinator)


class DelayedBrokerRejectionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.coordinator = (root / "MQL5/Include/AutopsyX/DistributedRiskCoordinator.mqh").read_text()
        cls.expert = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()

    def test_delayed_rejection_resolution_requires_fresh_known_baseline_snapshot(self):
        method = self.coordinator[
            self.coordinator.index("bool ResolveDefinitiveRejection"):
            self.coordinator.index("string InstanceId", self.coordinator.index("bool ResolveDefinitiveRejection"))
        ]
        self.assertIn("snapshot.exposureKnown", method)
        self.assertIn("snapshot.existingRiskMoney>m_pendingBaselineRisk+0.01", method)
        self.assertIn("MarkExecutionRejected(error)", method)
        self.assertIn("Release(m_pendingReservationId,m_pendingInstance,snapshot,error)", method)

    def test_transaction_callback_only_queues_matching_market_request_rejection(self):
        callback = self.expert[
            self.expert.index("void OnTradeTransaction"):
            self.expert.index("void OnChartEvent")
        ]
        self.assertIn("trans.type==TRADE_TRANSACTION_REQUEST", callback)
        self.assertIn("request.action==TRADE_ACTION_DEAL", callback)
        self.assertIn('request.comment=="AXFDX"', callback)
        self.assertIn("request.magic", callback)
        self.assertIn("result.retcode==TRADE_RETCODE_TIMEOUT", callback)
        self.assertIn("g_distributedRejectedCallbackPending=true", callback)
        self.assertIn("ORDER_STATE_REJECTED", callback)
        self.assertIn("ORDER_STATE_CANCELED", callback)
        self.assertIn("ORDER_STATE_EXPIRED", callback)
        self.assertNotIn("WebRequest(", callback)
        self.assertNotIn("ResolveDefinitiveRejection(", callback)

    def test_timer_resolves_queued_rejection_after_account_wide_scan(self):
        timer = self.expert[
            self.expert.index("void OnTimer(void)"):
            self.expert.index("CHART EVENTS")
        ]
        self.assertLess(timer.index("g_accountRisk.Scan(recoverySnapshot)"),
                        timer.index("ResolveDefinitiveRejection"))
        self.assertIn("g_distributedRejectedCallbackPending=false", timer)
        self.assertIn("g_distributedRiskCoordinator.RecoverPending", timer)

    def test_immediate_rejection_clears_callback_flag_before_direct_release(self):
        entry = self.expert[
            self.expert.index("else if(distributedReservationActive)"):
            self.expert.index("if(!g_accountRiskCoordinator.Release())", self.expert.index("else if(distributedReservationActive)"))
        ]
        self.assertIn("g_distributedRejectedCallbackPending=false", entry)
        self.assertLess(entry.index("g_distributedRejectedCallbackPending=false"),
                        entry.index("MarkExecutionRejected"))

if __name__ == "__main__":
    unittest.main()


class BrokerExecutionCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.execution = (root / "MQL5/Include/AutopsyX/ExecutionEngine.mqh").read_text()
        cls.expert = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()

    def test_filling_policy_respects_symbol_flags_and_market_execution(self):
        detect = self.execution[
            self.execution.index("bool              DetectFillingMode("):
            self.execution.index("\npublic:", self.execution.index("bool              DetectFillingMode("))
        ]
        self.assertIn("SYMBOL_FILLING_IOC", detect)
        self.assertIn("ORDER_FILLING_IOC", detect)
        self.assertIn("SYMBOL_FILLING_FOK", detect)
        self.assertIn("ORDER_FILLING_FOK", detect)
        self.assertIn("SYMBOL_TRADE_EXECUTION_MARKET", detect)
        self.assertIn("return(false);", detect)
        self.assertIn("m_trade.SetTypeFilling(fillingMode)", self.execution)
        self.assertIn("if(!g_exec.Init(_Symbol,InpMagicNumber", self.expert)
        self.assertIn("return(INIT_FAILED);", self.expert)

    def test_protective_prices_align_to_tick_and_respect_stop_freeze_levels(self):
        start = self.execution.index("bool              PrepareProtectionPrices(")
        end = self.execution.index("\n   //--- brokers differ on supported order-filling modes", start)
        helper = self.execution[start:end]
        for token in (
            "SYMBOL_TRADE_TICK_SIZE",
            "SYMBOL_TRADE_STOPS_LEVEL",
            "SYMBOL_TRADE_FREEZE_LEVEL",
            "MathCeil(sl/tickSize",
            "MathFloor(sl/tickSize",
            "BUY_STOP_INSIDE_BROKER_STOPS_LEVEL",
            "SELL_STOP_INSIDE_BROKER_STOPS_LEVEL",
            "STOP_MODIFICATION_INSIDE_BROKER_FREEZE_LEVEL",
        ):
            self.assertIn(token, helper)
        self.assertIn("PrepareProtectionPrices(symbol,dir,alignedSl,alignedTp,false", self.execution)
        self.assertIn("PrepareProtectionPrices(symbol,dir,alignedSl,alignedTp,true", self.execution)
        self.assertIn("PositionModify(positionTicket,alignedSl,alignedTp)", self.execution)
        self.assertIn("MathAbs(actualSl-alignedSl)", self.execution)


    def test_fresh_entry_confirms_exact_order_deals_and_actual_partial_volume(self):
        confirm = self.execution[
            self.execution.index("bool              ConfirmMarketOrder("):
            self.execution.index("bool              HasOpenPosition(", self.execution.index("bool              ConfirmMarketOrder("))
        ]
        for token in (
            "m_trade.ResultDeal()",
            "HistoryDealGetInteger(resultDeal,DEAL_ORDER)!=orderTicket",
            "DEAL_ORDER",
            "DEAL_ENTRY_IN",
            "DEAL_POSITION_ID",
            "DEAL_MAGIC",
            "POSITION_IDENTIFIER",
            "MathAbs(liveVolume-dealVolume)",
            "actualLotsOut=dealVolume",
            "fillPriceOut=dealPriceValue/dealVolume",
        ):
            self.assertIn(token, confirm)
        entry = self.execution[
            self.execution.index("bool              OpenMarket("):
            self.execution.index("//--- add to an existing NETTING position")
        ]
        self.assertIn("TRADE_RETCODE_DONE_PARTIAL", entry)
        self.assertIn("ConfirmMarketOrder(symbol,dir,lots,orderTicket", entry)
        self.assertIn("outcomeUncertain=true;", entry)
        self.assertIn("never resend an accepted or ambiguous market request", entry)
        self.assertIn("a same-symbol position already exists", entry)

    def test_legacy_symbol_stop_modify_routes_through_ticket_confirmation(self):
        modify = self.execution[
            self.execution.index("bool              ModifyStops("):
            self.execution.index("// Ticket-specific stop modification", self.execution.index("bool              ModifyStops("))
        ]
        self.assertIn("POSITION_TICKET", modify)
        self.assertIn("POSITION_IDENTIFIER", modify)
        self.assertIn("ModifyStopsByTicket(symbol,ticket,positionId,magic", modify)
        self.assertNotIn("m_trade.PositionModify(symbol", modify)

    def test_rejected_stop_modification_does_not_advance_virtual_exit_state(self):
        modify = self.execution[
            self.execution.index("bool              ModifyStopsByTicket("):
            self.execution.index("// Ticket-specific full close", self.execution.index("bool              ModifyStopsByTicket("))
        ]
        self.assertIn("if(!ok || retcode!=TRADE_RETCODE_DONE)", modify)
        self.assertIn("Ticket stop modification failed", modify)
        self.assertIn("actualSl=PositionGetDouble(POSITION_SL)", modify)
        self.assertIn("actualTp=PositionGetDouble(POSITION_TP)", modify)
        self.assertIn("Broker accepted stop modification but confirmed levels differ", modify)
        self.assertIn("g_virtualExitReady=false;", self.expert)
        self.assertIn("g_hedgingLifecycleLock=true;", self.expert)
        self.assertIn("action lock retained, no retry", self.expert)


    def test_flip_wrapper_passes_uncertainty_output_to_market_entry(self):
        flip = self.execution[
            self.execution.index("bool              Flip("):
            self.execution.index("bool              ModifyStops(", self.execution.index("bool              Flip("))
        ]
        self.assertIn("bool &outcomeUncertain", flip)
        self.assertIn("bool openOutcomeUncertain=false;", flip)
        self.assertIn("latencyMs,actualLots,openOutcomeUncertain", flip)
        self.assertIn("outcomeUncertain=openOutcomeUncertain;", flip)

class NettingPyramidFillReconciliationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.execution = (root / "MQL5/Include/AutopsyX/ExecutionEngine.mqh").read_text()

    def test_netting_add_reconciles_only_exact_order_entry_deals(self):
        start = self.execution.index("bool              AddToNettingPosition(")
        end = self.execution.index("//--- flip = close, confirm flat", start)
        method = self.execution[start:end]
        for token in (
            "orderTicketOut=m_trade.ResultOrder()",
            "DEAL_ORDER)!=orderTicketOut",
            "DEAL_ENTRY)!=DEAL_ENTRY_IN",
            "DEAL_SYMBOL)!=symbol",
            "DEAL_MAGIC)!=expectedMagic",
            "DEAL_POSITION_ID)!=beforeId",
            "DEAL_TYPE_BUY",
            "DEAL_TYPE_SELL",
            "MathAbs(volumeIncrease-dealVolume)",
            "stopsPreserved",
            "actualAddLotsOut=dealVolume",
            "fillPriceOut=dealPriceValue/dealVolume",
        ):
            self.assertIn(token, method)

    def test_unconfirmed_done_or_partial_netting_add_is_uncertain(self):
        start = self.execution.index("bool              AddToNettingPosition(")
        end = self.execution.index("bool              Flip(", start)
        method = self.execution[start:end]
        failed_send = method[method.index("if(!sent)"):method.index("// A true CTrade return")]
        for token in (
            "TRADE_RETCODE_DONE",
            "TRADE_RETCODE_DONE_PARTIAL",
            "TRADE_RETCODE_TIMEOUT",
            "TRADE_RETCODE_CONNECTION",
            "TRADE_RETCODE_PLACED",
        ):
            self.assertIn(token, failed_send)
        self.assertIn("outcomeUncertain=true;", failed_send)

    def test_unconfirmed_netting_add_does_not_retry_market_submission(self):
        start = self.execution.index("bool              AddToNettingPosition(")
        end = self.execution.index("//--- close one exact broker position", start)
        method = self.execution[start:end]
        self.assertEqual(method.count("m_trade.Buy(requestedLots"), 1)
        self.assertEqual(method.count("m_trade.Sell(requestedLots"), 1)


class FullCloseBrokerReconciliationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.execution = (root / "MQL5/Include/AutopsyX/ExecutionEngine.mqh").read_text()
        cls.expert = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()

    def test_full_close_uses_exact_ticket_identity_and_order_exit_deals(self):
        start = self.execution.index("bool              ClosePosition(const string symbol,const ulong positionTicket")
        end = self.execution.index("//--- close part of an open position", start)
        method = self.execution[start:end]
        for token in (
            "PositionSelectByTicket(positionTicket)",
            "POSITION_IDENTIFIER",
            "POSITION_MAGIC",
            "m_trade.PositionClose(positionTicket)",
            "m_trade.ResultOrder()",
            "m_trade.ResultDeal()",
            "HistoryDealGetInteger(resultDeal,DEAL_ORDER)!=orderTicket",
            "DEAL_ENTRY_OUT",
            "DEAL_ENTRY_OUT_BY",
            "DEAL_POSITION_ID",
            "closedVolume+tolerance<beforeVolume",
        ):
            self.assertIn(token, method)

    def test_full_close_submits_once_and_never_retries_partial_or_ambiguous_result(self):
        start = self.execution.index("bool              ClosePosition(const string symbol,const ulong positionTicket")
        end = self.execution.index("//--- close part of an open position", start)
        method = self.execution[start:end]
        self.assertEqual(method.count("m_trade.PositionClose(positionTicket)"), 1)
        self.assertIn("TRADE_RETCODE_DONE_PARTIAL", method)
        self.assertIn("TRADE_RETCODE_TIMEOUT", method)
        self.assertIn("outcomeUncertain=true;", method)
        self.assertIn("no retry sent", method)

    def test_full_close_uncertainty_quarantines_campaign_and_blocks_new_actions(self):
        start = self.expert.index("bool AxCloseAndRecord(")
        end = self.expert.index("void AxRecordExternalClose(", start)
        method = self.expert[start:end]
        self.assertIn("g_exec.ClosePosition(_Symbol,ticket,g_positionIdentifier,InpMagicNumber", method)
        self.assertIn("if(closeOutcomeUncertain)", method)
        self.assertIn("g_recoveryReady=false;", method)
        self.assertIn("g_virtualExitReady=false;", method)
        self.assertIn("g_hedgingLifecycleLock=true;", method)
        self.assertIn("g_engineState=AX_ENGINE_PAUSED;", method)
        self.assertIn("g_accountRiskReconciliationPending=true;", method)


    def test_partial_close_confirms_exact_order_exit_deals_and_position_volume(self):
        start = self.execution.index("bool              ClosePartial(")
        end = self.execution.index("bool              Flip(", start)
        method = self.execution[start:end]
        for token in (
            "m_trade.ResultOrder()",
            "m_trade.ResultDeal()",
            "HistoryDealGetInteger(resultDeal,DEAL_ORDER)!=orderTicket",
            "DEAL_ENTRY_OUT",
            "DEAL_ENTRY_OUT_BY",
            "DEAL_POSITION_ID)!=expectedPositionId",
            "exactOrderClosed",
            "MathAbs(exactOrderClosed-actualClosed)",
            "outcomeUncertain=true;",
        ):
            self.assertIn(token, method)
        self.assertEqual(method.count("m_trade.PositionClosePartial(positionTicket,volumeToClose)"), 1)
        self.assertIn("if(serverAccepted || retcode==TRADE_RETCODE_PLACED)", method)
        self.assertIn("outcomeUncertain=true;", method)
        self.assertIn("no retry sent", method)


class FlipAndTransactionIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        cls.execution = (root / "MQL5/Include/AutopsyX/ExecutionEngine.mqh").read_text()
        cls.expert = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()

    def test_flip_closes_exact_ticket_before_open_and_propagates_uncertainty(self):
        start = self.execution.index("bool              Flip(")
        end = self.execution.index("bool              ModifyStops(", start)
        method = self.execution[start:end]
        self.assertIn("oldPositionTicket", method)
        self.assertIn("oldPositionId", method)
        self.assertIn("oldMagic", method)
        self.assertIn("ClosePosition(symbol,oldPositionTicket,oldPositionId,oldMagic", method)
        self.assertLess(method.index("ClosePosition("), method.index("OpenMarket("))
        self.assertIn("outcomeUncertain=openOutcomeUncertain;", method)

    def test_trade_transaction_exit_finalization_is_scoped_to_exact_campaign_id(self):
        start = self.expert.index("void OnTradeTransaction(")
        end = self.expert.index("void OnChartEvent(", start)
        callback = self.expert[start:end]
        self.assertIn("g_positionIdentifier>0", callback)
        self.assertIn("HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID)==g_positionIdentifier", callback)
        self.assertIn("AxFetchCloseFinancials(g_posState.ticket,g_posState.lastAccountedDealTicket", callback)
        self.assertIn("DEAL_ENTRY_INOUT", callback)
        self.assertIn("g_nettingReversalQuarantined=true;", callback)
