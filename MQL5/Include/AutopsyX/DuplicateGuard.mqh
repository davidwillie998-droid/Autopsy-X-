//+------------------------------------------------------------------+
//|                                                DuplicateGuard.mqh|
//|  Duplicate Order Protection (FLIPDEMON EXTREME upgrade, spec     |
//|  section 20) - a setup must never execute twice because of tick   |
//|  repetition, OnTick re-entry, EA restart, VPS reconnect, chart    |
//|  reload, or timeframe change.                                     |
//|                                                                    |
//|  Two independent layers, because they fail differently:            |
//|   1. An in-memory recent-SetupID registry - catches the same       |
//|      thesis being submitted twice within one running session       |
//|      (e.g. re-entrant OnTick logic). Resets on EA restart, which   |
//|      is exactly why layer 2 exists.                                |
//|   2. A live broker-state check (HasExistingExposure) - inspects    |
//|      actual open positions and pending orders for this symbol/     |
//|      magic/direction combination directly from MT5, every time.    |
//|      This layer survives EA restart, VPS reconnect and chart       |
//|      reload, because none of those change what the broker actually |
//|      has open - it is the real protection; layer 1 is a fast-path  |
//|      convenience on top of it, never a substitute for it.          |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_DUPLICATEGUARD_MQH
#define AX_DUPLICATEGUARD_MQH
#include "Defs.mqh"

#define AX_DUP_GUARD_BUFFER 128

class CDuplicateGuard
  {
private:
   string            m_recentSetupIds[AX_DUP_GUARD_BUFFER];
   int               m_count;

   void              Push(const string id)
     {
      if(m_count<AX_DUP_GUARD_BUFFER) { m_recentSetupIds[m_count]=id; m_count++; }
      else
        {
         for(int i=1;i<AX_DUP_GUARD_BUFFER;i++) m_recentSetupIds[i-1]=m_recentSetupIds[i];
         m_recentSetupIds[AX_DUP_GUARD_BUFFER-1]=id;
        }
     }

public:
                     CDuplicateGuard(void) { m_count=0; }

   bool              IsDuplicateSetupId(const string setupId) const
     {
      for(int i=0;i<m_count;i++) if(m_recentSetupIds[i]==setupId) return(true);
      return(false);
     }

   void              RegisterSetupId(const string setupId)
     {
      Push(setupId);
     }

   //--- restart recovery (Phase 6) re-populates this registry from the journal after a fresh start -
   //--- this method exists so that step doesn't need private access to m_recentSetupIds directly. ---
   void              RestoreSetupId(const string setupId)
     {
      Push(setupId);
     }

   //--- the real, broker-backed check. Returns true if a position OR pending order already exists ---
   //--- for this exact symbol/magic/direction combination - a fresh entry attempt in that same     ---
   //--- direction would be a duplicate regardless of what SetupID it carries. ---
   bool              HasExistingExposure(const string symbol,const ulong magic,const ENUM_AX_DIR dir) const
     {
      //--- iterate ALL positions by index (PositionsTotal/PositionGetTicket), not PositionSelect  ---
      //--- (symbol) alone - on a hedging-mode account a symbol can carry multiple simultaneous     ---
      //--- positions under different magic numbers, and PositionSelect(symbol) is only guaranteed  ---
      //--- to select ONE of them (which one is unspecified). Scanning by index the same way the    ---
      //--- pending-order loop already does is what actually sees every position on this symbol. ---
      int posTotal = PositionsTotal();
      for(int i=0;i<posTotal;i++)
        {
         ulong posTicket = PositionGetTicket(i);
         if(posTicket==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=symbol) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC)!=magic) continue;
         long type = PositionGetInteger(POSITION_TYPE);
         ENUM_AX_DIR posDir = (type==POSITION_TYPE_BUY) ? AX_DIR_BUY : AX_DIR_SELL;
         if(posDir==dir) return(true);
        }

      int total = OrdersTotal();
      for(int i=0;i<total;i++)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket==0) continue;
         if(OrderGetString(ORDER_SYMBOL)!=symbol) continue;
         if((ulong)OrderGetInteger(ORDER_MAGIC)!=magic) continue;

         long otype = OrderGetInteger(ORDER_TYPE);
         bool isBuySide  = (otype==ORDER_TYPE_BUY  || otype==ORDER_TYPE_BUY_STOP  ||
                            otype==ORDER_TYPE_BUY_LIMIT  || otype==ORDER_TYPE_BUY_STOP_LIMIT);
         bool isSellSide = (otype==ORDER_TYPE_SELL || otype==ORDER_TYPE_SELL_STOP ||
                            otype==ORDER_TYPE_SELL_LIMIT || otype==ORDER_TYPE_SELL_STOP_LIMIT);
         if((dir==AX_DIR_BUY && isBuySide) || (dir==AX_DIR_SELL && isSellSide)) return(true);
        }
      return(false);
     }

   //--- combined gate for the entry call site: checks both layers, returns false with a reason the  ---
   //--- instant either one objects. Does NOT register the SetupID itself - the caller registers it   ---
   //--- only after the order is actually confirmed, so a rejected/failed attempt doesn't permanently ---
   //--- burn a SetupID that never actually traded.                                                    ---
   //--- KNOWN LIMITATION (code-review finding, deliberately not engineered around): there is a       ---
   //--- time-of-check-to-time-of-use gap between this call and RegisterSetupId - within a SINGLE EA   ---
   //--- instance this is not a real race, since one MT5 chart's OnTick is synchronous and single-     ---
   //--- threaded, so CanAttemptEntry -> order submission -> RegisterSetupId always completes as one   ---
   //--- atomic sequence before the next tick's OnTick call. It WOULD be a real race only if two        ---
   //--- separate EA instances (e.g. the same symbol/magic run on two terminals during a VPS failover)  ---
   //--- called this within the same broker round-trip window - HasExistingExposure's live broker-state ---
   //--- check is what eventually catches that case, just not necessarily before both have submitted.   ---
   //--- Running two live instances with the same magic number on the same symbol is already a          ---
   //--- misconfiguration this EA does not otherwise support - documented here rather than silently.    ---
   bool              CanAttemptEntry(const string setupId,const string symbol,const ulong magic,
                                      const ENUM_AX_DIR dir,string &reasonOut) const
     {
      if(IsDuplicateSetupId(setupId))
        { reasonOut="Duplicate SetupID already attempted this session"; return(false); }
      if(HasExistingExposure(symbol,magic,dir))
        { reasonOut="Existing position or pending order already open in this direction"; return(false); }
      reasonOut="";
      return(true);
     }
  };
//+------------------------------------------------------------------+
#endif // AX_DUPLICATEGUARD_MQH
