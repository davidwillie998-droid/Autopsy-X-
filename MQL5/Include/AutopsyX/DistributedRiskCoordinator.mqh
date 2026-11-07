//+------------------------------------------------------------------+
//| DistributedRiskCoordinator.mqh                                    |
//| Authenticated HTTPS adapter for the persistent account risk API. |
//| Live execution fails closed when the coordinator is unavailable. |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DISTRIBUTED_RISK_COORDINATOR_MQH
#define AX_DISTRIBUTED_RISK_COORDINATOR_MQH

class CDistributedRiskCoordinator
  {
private:
   string m_baseUrl;
   string m_key;
   string m_instanceId;
   int    m_timeoutMs;
   long   m_lastSnapshotMs;
   ulong  m_requestCounter;
   bool   m_ready;
   string m_journalFile;
   string m_pendingKey;
   string m_pendingInstance;
   string m_pendingReservationId;
   double m_pendingRiskMoney;
   double m_pendingBaselineRisk;
   bool   m_journalPending;

   bool SavePendingJournal(void)
     {
      if(!m_journalPending) return(true);
      string tempName=m_journalFile+".tmp";
      int handle=FileOpen(tempName,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE) return(false);
      string line=(string)AccountInfoInteger(ACCOUNT_LOGIN)+"|"+
                  AccountInfoString(ACCOUNT_SERVER)+"|"+
                  m_pendingInstance+"|"+m_pendingKey+"|"+
                  DoubleToString(m_pendingRiskMoney,8)+"|"+
                  DoubleToString(m_pendingBaselineRisk,8)+"|"+
                  m_pendingReservationId+"\r\n";
      uint expected=(uint)StringLen(line);
      uint written=FileWriteString(handle,line);
      FileFlush(handle);
      FileClose(handle);
      if(written!=expected) return(false);
      ResetLastError();
      if(!FileMove(tempName,0,m_journalFile,FILE_REWRITE))
        {
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: reservation journal replace failed (%s, error=%d).",
                     m_journalFile,GetLastError());
         return(false);
        }
      return(true);
     }

   bool LoadPendingJournal(string &error)
     {
      m_journalPending=false;
      if(!FileIsExist(m_journalFile)) return(true);
      int handle=FileOpen(m_journalFile,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
      if(handle==INVALID_HANDLE)
        {
         error="DISTRIBUTED_RISK_JOURNAL_EXISTS_BUT_CANNOT_BE_READ";
         return(false);
        }
      string line=FileReadString(handle);
      FileClose(handle);
      string fields[];
      int count=StringSplit(line,'|',fields);
      if(count!=7 ||
         fields[0]!=(string)AccountInfoInteger(ACCOUNT_LOGIN) ||
         fields[1]!=AccountInfoString(ACCOUNT_SERVER) ||
         StringLen(fields[2])==0 || StringLen(fields[3])<8 ||
         StringToDouble(fields[4])<=0.0 || StringToDouble(fields[5])<0.0)
        {
         error="DISTRIBUTED_RISK_JOURNAL_INVALID_OR_WRONG_ACCOUNT";
         return(false);
        }
      m_pendingInstance=fields[2];
      m_pendingKey=fields[3];
      m_pendingRiskMoney=StringToDouble(fields[4]);
      m_pendingBaselineRisk=StringToDouble(fields[5]);
      m_pendingReservationId=fields[6];
      m_journalPending=true;
      return(true);
     }

   bool ClearPendingJournal(void)
     {
      if(FileIsExist(m_journalFile) && !FileDelete(m_journalFile))
        {
         PrintFormat("FLIPDEMON DISTRIBUTED RISK: could not remove resolved reservation journal (%s, error=%d).",
                     m_journalFile,GetLastError());
         return(false);
        }
      m_pendingKey="";
      m_pendingInstance="";
      m_pendingReservationId="";
      m_pendingRiskMoney=0.0;
      m_pendingBaselineRisk=0.0;
      m_journalPending=false;
      return(true);
     }

   string BuildInstanceId(void) const
     {
      // Chart IDs are only unique inside one terminal. Mix in the terminal data
      // directory so two terminals on the same machine cannot impersonate owners.
      string path=TerminalInfoString(TERMINAL_DATA_PATH);
      uint hash=2166136261;
      for(int i=0;i<StringLen(path);i++)
         hash=(hash ^ (uint)StringGetCharacter(path,i))*16777619;
      return(StringFormat("MT5-%08X-%I64d",hash,ChartID()));
     }

   string JsonEscape(const string value) const
     {
      string out="";
      for(int i=0;i<StringLen(value);i++)
        {
         ushort ch=StringGetCharacter(value,i);
         if(ch==34) out+="\\\"";
         else if(ch==92) out+="\\\\";
         else if(ch==10) out+="\\n";
         else if(ch==13) out+="\\r";
         else if(ch==9) out+="\\t";
         else out+=ShortToString(ch);
        }
      return(out);
     }

   bool Post(const string path,const string body,string &response,string &error) const
     {
      response="";
      error="";
      if(!m_ready)
        {
         error="DISTRIBUTED_RISK_COORDINATOR_NOT_CONFIGURED";
         return(false);
        }

      char requestData[];
      int byteCount=StringToCharArray(body,requestData,0,WHOLE_ARRAY,CP_UTF8);
      if(byteCount<=1)
        {
         error="DISTRIBUTED_RISK_REQUEST_ENCODING_FAILED";
         return(false);
        }
      ArrayResize(requestData,byteCount-1);

      char responseData[];
      string responseHeaders;
      string headers="Content-Type: application/json\r\n"+
                     "x-risk-coordinator-key: "+m_key+"\r\n";
      ResetLastError();
      int status=WebRequest("POST",m_baseUrl+path,headers,m_timeoutMs,
                            requestData,responseData,responseHeaders);
      if(status==-1)
        {
         error=StringFormat("DISTRIBUTED_RISK_WEBREQUEST_FAILED terminal_error=%d; check HTTPS URL allowlist and connectivity",
                            GetLastError());
         return(false);
        }
      response=CharArrayToString(responseData,0,WHOLE_ARRAY,CP_UTF8);
      if(status<200 || status>=300)
        {
         error=StringFormat("DISTRIBUTED_RISK_HTTP_%d response=%s",status,response);
         return(false);
        }
      return(true);
     }

   bool JsonTrue(const string json,const string field) const
     {
      return(StringFind(json,"\""+field+"\":true")>=0 ||
             StringFind(json,"\""+field+"\": true")>=0);
     }

   bool JsonString(const string json,const string field,string &value) const
     {
      value="";
      string token="\""+field+"\":\"";
      int start=StringFind(json,token);
      if(start<0) return(false);
      start+=StringLen(token);
      int finish=StringFind(json,"\"",start);
      if(finish<=start) return(false);
      value=StringSubstr(json,start,finish-start);
      return(StringLen(value)>0);
     }

   long NextSnapshotTimeMs(void)
     {
      long candidate=(long)TimeGMT()*1000+(long)(GetTickCount64()%1000);
      if(candidate<=m_lastSnapshotMs) candidate=m_lastSnapshotMs+1;
      m_lastSnapshotMs=candidate;
      return(candidate);
     }

   string AccountFields(void) const
     {
      return("\"login\":\""+(string)AccountInfoInteger(ACCOUNT_LOGIN)+"\","+
             "\"server\":\""+JsonEscape(AccountInfoString(ACCOUNT_SERVER))+"\"");
     }

   bool SnapshotBody(const SAxAccountRiskSnapshot &snapshot,string &body,string &error)
     {
      body="";
      if(!snapshot.exposureKnown || snapshot.equity<=0.0 ||
         !MathIsValidNumber(snapshot.equity) ||
         snapshot.existingRiskMoney<0.0 ||
         !MathIsValidNumber(snapshot.existingRiskMoney))
        {
         error="DISTRIBUTED_RISK_SNAPSHOT_UNKNOWN_OR_INVALID";
         return(false);
        }
      long snapshotAtMs=NextSnapshotTimeMs();
      string snapshotId=StringFormat("AX-%I64d-%I64d",ChartID(),snapshotAtMs);
      body="{"+AccountFields()+","+
           "\"equity\":"+DoubleToString(snapshot.equity,8)+","+
           "\"existingRiskMoney\":"+DoubleToString(snapshot.existingRiskMoney,8)+","+
           "\"snapshotAtMs\":"+(string)snapshotAtMs+","+
           "\"snapshotId\":\""+snapshotId+"\"}";
      return(true);
     }

public:
   CDistributedRiskCoordinator(void)
     {
      m_baseUrl="";
      m_key="";
      m_instanceId="";
      m_timeoutMs=3000;
      m_lastSnapshotMs=0;
      m_requestCounter=0;
      m_ready=false;
      m_journalFile="";
      m_pendingKey="";
      m_pendingInstance="";
      m_pendingReservationId="";
      m_pendingRiskMoney=0.0;
      m_pendingBaselineRisk=0.0;
      m_journalPending=false;
     }

   bool Init(const string baseUrl,const string key,const int timeoutMs,
             const string symbol,const ulong magic,string &error)
     {
      m_ready=false;
      m_baseUrl=baseUrl;
      m_key=key;
      m_instanceId=BuildInstanceId();
      m_timeoutMs=timeoutMs;
      // Use stable EA identity, not ChartID, for the journal filename.
      // Chart IDs can change when a terminal/chart is recreated after a restart.
      m_journalFile=StringFormat("AX_DistributedRisk_%I64d_%s_%I64u.dat",
                                 (long)AccountInfoInteger(ACCOUNT_LOGIN),symbol,magic);
      if(StringFind(m_baseUrl,"https://")!=0 || StringLen(m_baseUrl)<12 ||
         StringLen(m_key)<32 || m_timeoutMs<500 || m_timeoutMs>10000)
        {
         error="DISTRIBUTED_RISK_REQUIRES_HTTPS_URL_KEY_32_CHARS_AND_TIMEOUT_500_TO_10000MS";
         return(false);
        }
      while(StringLen(m_baseUrl)>0 &&
            StringGetCharacter(m_baseUrl,StringLen(m_baseUrl)-1)==47)
         m_baseUrl=StringSubstr(m_baseUrl,0,StringLen(m_baseUrl)-1);
      m_ready=true;
      error="";
      if(!LoadPendingJournal(error))
        {
         m_ready=false;
         return(false);
        }
      return(true);
     }

   bool IsReady(void) const { return(m_ready); }
   bool HasPendingJournal(void) const { return(m_journalPending); }

   // Resolve a reservation left by a terminal restart before allowing any new
   // order. The broker snapshot is reconciled first. The exact original key and
   // amount are then replayed, so the server returns the same reservation rather
   // than creating a second claim. A terminal idempotency conflict means the
   // original reservation has already reached a terminal state through expiry
   // reconciliation, so the fresh broker snapshot is authoritative.
   bool RecoverPending(const SAxAccountRiskSnapshot &snapshot,string &error)
     {
      if(!m_journalPending) return(true);
      if(!snapshot.exposureKnown || snapshot.equity<=0.0 ||
         !MathIsValidNumber(snapshot.existingRiskMoney))
        {
         error="DISTRIBUTED_RISK_RECOVERY_SNAPSHOT_UNKNOWN";
         return(false);
        }

      bool withinCap=false;
      // Reconcile first, but do not abandon an active reservation merely because
      // the broker snapshot is currently over budget. The exact idempotent replay
      // below determines whether the claim is still active or already terminal.
      if(!Reconcile(snapshot,withinCap,error))
         return(false);

      string body="{"+AccountFields()+","+
                  "\"instanceId\":\""+JsonEscape(m_pendingInstance)+"\","+
                  "\"idempotencyKey\":\""+JsonEscape(m_pendingKey)+"\","+
                  "\"riskMoney\":"+DoubleToString(m_pendingRiskMoney,8)+"}";
      string response,reservationId;
      if(!Post("/risk/reserve",body,response,error))
        {
         if(StringFind(error,"IDEMPOTENCY_KEY_ALREADY_USED")>=0)
            return(ClearPendingJournal());
         return(false);
        }
      if(!JsonTrue(response,"ok") || !JsonString(response,"reservationId",reservationId))
        {
         error="DISTRIBUTED_RISK_RECOVERY_RESERVATION_REJECTED "+response;
         return(false);
        }
      m_pendingReservationId=reservationId;
      if(!SavePendingJournal())
        {
         error="DISTRIBUTED_RISK_RECOVERY_JOURNAL_WRITE_FAILED";
         return(false);
        }

      // Increased broker stop-risk means the submitted order may have filled.
      // Settle against the fresh account-wide broker snapshot instead of leaving
      // a permanent reservation lock. Settlement records actual exposure and
      // reports an over-budget result without pretending the account is safe.
      if(snapshot.existingRiskMoney>m_pendingBaselineRisk+0.01)
        {
         bool settledWithinCap=false;
         if(!Settle(reservationId,m_pendingInstance,snapshot,settledWithinCap,error))
            return(false);
         if(!settledWithinCap)
            error="DISTRIBUTED_RISK_RECOVERY_SETTLED_ACCOUNT_OVER_CAP";
         return(true);
        }

      if(!Release(reservationId,m_pendingInstance,snapshot,error)) return(false);
      return(true);
     }
   string InstanceId(void) const { return(m_instanceId); }

   bool Reconcile(const SAxAccountRiskSnapshot &snapshot,bool &withinCap,string &error)
     {
      withinCap=false;
      string body,response;
      if(!SnapshotBody(snapshot,body,error)) return(false);
      if(!Post("/risk/reconcile",body,response,error)) return(false);
      if(!JsonTrue(response,"ok"))
        {
         error="DISTRIBUTED_RISK_RECONCILE_REJECTED "+response;
         return(false);
        }
      withinCap=JsonTrue(response,"withinCap");
      return(true);
     }

   bool Reserve(const SAxAccountRiskDecision &decision,
                const SAxAccountRiskSnapshot &snapshot,
                const string instanceId,string &reservationId,string &error)
     {
      reservationId="";
      if(m_journalPending)
        {
         error="DISTRIBUTED_RISK_PENDING_JOURNAL_MUST_BE_RECOVERED_BEFORE_NEW_RESERVATION";
         return(false);
        }
      string snapshotBody,response;
      if(!SnapshotBody(snapshot,snapshotBody,error)) return(false);
      if(!Post("/risk/reconcile",snapshotBody,response,error)) return(false);
      if(!JsonTrue(response,"ok") || !JsonTrue(response,"withinCap"))
        {
         error="DISTRIBUTED_RISK_PRE_RESERVATION_RECONCILE_REJECTED "+response;
         return(false);
        }

      m_requestCounter++;
      string idempotencyKey=StringFormat("%s-%I64d-%I64d",m_instanceId,
                                         (long)TimeGMT(),(long)m_requestCounter);
      string body="{"+AccountFields()+","+
                  "\"instanceId\":\""+JsonEscape(instanceId)+"\","+
                  "\"idempotencyKey\":\""+idempotencyKey+"\","+
                  "\"riskMoney\":"+DoubleToString(decision.proposedRiskMoney,8)+"}";
      m_pendingInstance=instanceId;
      m_pendingKey=idempotencyKey;
      m_pendingRiskMoney=decision.proposedRiskMoney;
      m_pendingBaselineRisk=snapshot.existingRiskMoney;
      m_pendingReservationId="";
      m_journalPending=true;
      if(!SavePendingJournal())
        {
         m_journalPending=false;
         error="DISTRIBUTED_RISK_RESERVATION_JOURNAL_WRITE_FAILED";
         return(false);
        }
      // A transport timeout is ambiguous: the server may have committed the
      // reservation before the terminal lost its response. Retry the exact same
      // payload and idempotency key once. The ledger then returns the original
      // reservation instead of creating a second risk claim.
      if(!Post("/risk/reserve",body,response,error))
        {
         if(StringFind(error,"DISTRIBUTED_RISK_WEBREQUEST_FAILED")!=0)
           {
            // A definitive client rejection did not create this reservation.
            // Keep only the expired-reservation case, which may refer to an
            // earlier committed request and must be resolved by startup recovery.
            if(StringFind(error,"DISTRIBUTED_RISK_HTTP_4")==0 &&
               StringFind(error,"EXPIRED_RESERVATION_REQUIRES_RECONCILIATION")<0)
               ClearPendingJournal();
            return(false);
           }

         string firstAttemptError=error;
         response="";
         error="";
         if(!Post("/risk/reserve",body,response,error))
           {
            string retryError=error;
            if(StringFind(retryError,"DISTRIBUTED_RISK_HTTP_4")==0 &&
               StringFind(retryError,"EXPIRED_RESERVATION_REQUIRES_RECONCILIATION")<0)
               ClearPendingJournal();
            error="DISTRIBUTED_RISK_RESERVATION_OUTCOME_UNCONFIRMED first_attempt="+
                  firstAttemptError+" retry="+retryError;
            return(false);
           }
        }
      if(!JsonTrue(response,"ok") || !JsonString(response,"reservationId",reservationId))
        {
         error="DISTRIBUTED_RISK_RESERVATION_REJECTED "+response;
         reservationId="";
         return(false);
        }
      m_pendingReservationId=reservationId;
      if(!SavePendingJournal())
        {
         error="DISTRIBUTED_RISK_RESERVATION_ID_JOURNAL_WRITE_FAILED";
         reservationId="";
         return(false);
        }
      return(true);
     }

   bool Release(const string reservationId,const string instanceId,
                const SAxAccountRiskSnapshot &snapshot,string &error)
     {
      string snapshotBody,response;
      if(!SnapshotBody(snapshot,snapshotBody,error)) return(false);
      // The ledger requires a fresh broker snapshot newer than the reservation.
      string body=StringSubstr(snapshotBody,0,StringLen(snapshotBody)-1)+","+
                  "\"reservationId\":\""+JsonEscape(reservationId)+"\","+
                  "\"instanceId\":\""+JsonEscape(instanceId)+"\"}";
      if(!Post("/risk/release",body,response,error)) return(false);
      if(!JsonTrue(response,"released"))
        {
         error="DISTRIBUTED_RISK_RELEASE_REJECTED "+response;
         return(false);
        }
      if(m_journalPending && m_pendingReservationId==reservationId &&
         !ClearPendingJournal())
        {
         error="DISTRIBUTED_RISK_RELEASED_BUT_LOCAL_JOURNAL_CLEAR_FAILED";
         return(false);
        }
      return(true);
     }

   bool Settle(const string reservationId,const string instanceId,
               const SAxAccountRiskSnapshot &snapshot,bool &withinCap,string &error)
     {
      withinCap=false;
      string snapshotBody,response;
      if(!SnapshotBody(snapshot,snapshotBody,error)) return(false);
      string body=StringSubstr(snapshotBody,0,StringLen(snapshotBody)-1)+","+
                  "\"reservationId\":\""+JsonEscape(reservationId)+"\","+
                  "\"instanceId\":\""+JsonEscape(instanceId)+"\"}";
      if(!Post("/risk/settle",body,response,error)) return(false);
      if(!JsonTrue(response,"settled"))
        {
         error="DISTRIBUTED_RISK_SETTLEMENT_REJECTED "+response;
         return(false);
        }
      withinCap=JsonTrue(response,"withinCap");
      if(m_journalPending && m_pendingReservationId==reservationId &&
         !ClearPendingJournal())
        {
         error="DISTRIBUTED_RISK_SETTLED_BUT_LOCAL_JOURNAL_CLEAR_FAILED";
         return(false);
        }
      return(true);
     }
  };

#endif
