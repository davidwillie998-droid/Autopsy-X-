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
   int    m_timeoutMs;
   long   m_lastSnapshotMs;
   ulong  m_requestCounter;
   bool   m_ready;

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
      m_timeoutMs=3000;
      m_lastSnapshotMs=0;
      m_requestCounter=0;
      m_ready=false;
     }

   bool Init(const string baseUrl,const string key,const int timeoutMs,string &error)
     {
      m_ready=false;
      m_baseUrl=baseUrl;
      m_key=key;
      m_timeoutMs=timeoutMs;
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
      return(true);
     }

   bool IsReady(void) const { return(m_ready); }

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
      string snapshotBody,response;
      if(!SnapshotBody(snapshot,snapshotBody,error)) return(false);
      if(!Post("/risk/reconcile",snapshotBody,response,error)) return(false);
      if(!JsonTrue(response,"ok") || !JsonTrue(response,"withinCap"))
        {
         error="DISTRIBUTED_RISK_PRE_RESERVATION_RECONCILE_REJECTED "+response;
         return(false);
        }

      m_requestCounter++;
      string idempotencyKey=StringFormat("AX-%I64d-%I64d-%I64d",ChartID(),
                                         (long)TimeGMT(),(long)m_requestCounter);
      string body="{"+AccountFields()+","+
                  "\"instanceId\":\""+JsonEscape(instanceId)+"\","+
                  "\"idempotencyKey\":\""+idempotencyKey+"\","+
                  "\"riskMoney\":"+DoubleToString(decision.proposedRiskMoney,8)+"}";
      if(!Post("/risk/reserve",body,response,error)) return(false);
      if(!JsonTrue(response,"ok") || !JsonString(response,"reservationId",reservationId))
        {
         error="DISTRIBUTED_RISK_RESERVATION_REJECTED "+response;
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
      return(true);
     }
  };

#endif
