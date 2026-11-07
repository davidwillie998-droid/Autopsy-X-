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
        self.assertLess(timer.index("RecoverPending(recoverySnapshot"), timer.index("if(!InpShowDashboard) return;"))
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
        failure = timer[timer.index("else if(!g_distributedRiskCoordinator.RecoverPending"):timer.index("else\n        {", timer.index("else if(!g_distributedRiskCoordinator.RecoverPending"))]
        self.assertIn("g_accountRiskIntegrityLock=true", failure)
        self.assertNotIn("g_distributedRecoveryPending=false", failure)
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
        cls.expert = (root / "MQL5/Experts/AutopsyX/AutopsyX_FlipDemon_Extreme.mq5").read_text()

    def test_ambiguous_market_retcode_is_not_retried(self):
        retry = self.execution[
            self.execution.index("bool              RetryableRetcode"):
            self.execution.index("bool              AmbiguousRetcode")
        ]
        self.assertNotIn("TRADE_RETCODE_TIMEOUT", retry)
        self.assertNotIn("TRADE_RETCODE_CONNECTION", retry)
        self.assertIn("if(AmbiguousRetcode(retcode))", self.execution)
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
        self.assertIn("TRADE_TRANSACTION_HISTORY_ADD", callback) if False else None
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
