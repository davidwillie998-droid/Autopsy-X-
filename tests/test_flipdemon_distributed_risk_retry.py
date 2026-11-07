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
        self.assertIn("DISTRIBUTED_RISK_RECOVERY_OUTCOME_AMBIGUOUS_BROKER_EXPOSURE_INCREASED", recovery)

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

if __name__ == "__main__":
    unittest.main()
