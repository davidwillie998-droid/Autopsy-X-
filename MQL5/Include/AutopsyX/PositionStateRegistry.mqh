//+------------------------------------------------------------------+
//| PositionStateRegistry.mqh: dynamic ticket-isolated lifecycle map  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_POSITIONSTATEREGISTRY_MQH
#define AX_POSITIONSTATEREGISTRY_MQH
#include "Defs.mqh"

struct SAxPositionLifecycleRecord
  {
   ulong positionIdentifier;
   ulong ticket;
   string symbol;
   ulong magic;
   SAxPositionState state;
  };

class CPositionStateRegistry
  {
private:
   SAxPositionLifecycleRecord m_records[];
   int m_count;
   bool m_ready;
   string m_failureReason;

   int FindIndex(const ulong id) const
     {
      if(id==0) return(-1);
      for(int i=0;i<m_count;i++)
         if(m_records[i].positionIdentifier==id) return(i);
      return(-1);
     }

public:
   CPositionStateRegistry(void)
     {
      m_count=0;
      m_ready=(ArrayResize(m_records,0)==0);
      m_failureReason=m_ready ? "" : "POSITION_STATE_STORAGE_INIT_FAILED";
     }

   void Reset(void)
     {
      m_count=0;
      m_ready=(ArrayResize(m_records,0)==0);
      m_failureReason=m_ready ? "" : "POSITION_STATE_STORAGE_RESET_FAILED";
     }

   bool Upsert(const ulong id,const ulong ticket,const string symbol,
               const ulong magic,const SAxPositionState &state)
     {
      if(!m_ready) return(false);
      if(id==0 || ticket==0 || StringLen(symbol)==0 || magic==0 ||
         !state.active || state.ticket!=ticket || state.lots<=0.0 ||
         !MathIsValidNumber(state.lots))
        {
         m_failureReason="INVALID_POSITION_STATE_RECORD";
         return(false);
        }
      int index=FindIndex(id);
      if(index>=0)
        {
         if(m_records[index].symbol!=symbol || m_records[index].magic!=magic)
           {
            m_failureReason="POSITION_IDENTITY_OWNERSHIP_CONFLICT";
            return(false);
           }
         m_records[index].ticket=ticket;
         m_records[index].state=state;
         return(true);
        }
      int next=m_count+1;
      if(ArrayResize(m_records,next)!=next)
        {
         m_ready=false;
         m_failureReason="POSITION_STATE_ALLOCATION_FAILED";
         return(false);
        }
      m_records[m_count].positionIdentifier=id;
      m_records[m_count].ticket=ticket;
      m_records[m_count].symbol=symbol;
      m_records[m_count].magic=magic;
      m_records[m_count].state=state;
      m_count=next;
      return(true);
     }

   bool FindByIdentifier(const ulong id,SAxPositionLifecycleRecord &out) const
     {
      if(!m_ready) return(false);
      int index=FindIndex(id);
      if(index<0) return(false);
      out=m_records[index];
      return(true);
     }

   bool FindByTicket(const ulong ticket,SAxPositionLifecycleRecord &out) const
     {
      if(!m_ready || ticket==0) return(false);
      for(int i=0;i<m_count;i++)
         if(m_records[i].ticket==ticket)
           {
            out=m_records[i];
            return(true);
           }
      return(false);
     }

   bool Remove(const ulong id)
     {
      if(!m_ready) return(false);
      int index=FindIndex(id);
      if(index<0) return(true);
      for(int i=index;i<m_count-1;i++) m_records[i]=m_records[i+1];
      m_count--;
      if(ArrayResize(m_records,m_count)!=m_count)
        {
         m_ready=false;
         m_failureReason="POSITION_STATE_COMPACTION_FAILED";
         return(false);
        }
      return(true);
     }

   bool GetAt(const int index,SAxPositionLifecycleRecord &out) const
     {
      if(!m_ready || index<0 || index>=m_count) return(false);
      out=m_records[index];
      return(true);
     }

   int Count(void) const { return(m_count); }
   bool IsReady(void) const { return(m_ready); }
   string FailureReason(void) const { return(m_failureReason); }
  };
#endif
