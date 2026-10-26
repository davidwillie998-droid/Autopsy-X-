//+------------------------------------------------------------------+
//| MultiSymbolAnalysisPool.mqh                                      |
//| Bounded orchestration for independent scan-only analysis slots.  |
//| No order placement and no account-risk authorization.             |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_MULTI_SYMBOL_ANALYSIS_POOL_MQH
#define AUTOPSYX_MULTI_SYMBOL_ANALYSIS_POOL_MQH

#include "MarketScanner.mqh"
#include "SymbolAnalysisSlot.mqh"

#define AX_MAX_ANALYSIS_SLOTS 32

class CMultiSymbolAnalysisPool
  {
private:
   CSymbolAnalysisSlot *m_slots[];
   int                  m_count;
   int                  m_max_symbols;
   ENUM_TIMEFRAMES      m_tf;
   double               m_min_score;
   double               m_min_gap;
   string               m_last_error;

   int FindSlot(const string symbol) const
     {
      for(int i=0;i<m_count;i++)
         if(CheckPointer(m_slots[i])==POINTER_DYNAMIC && m_slots[i].Symbol()==symbol)
            return(i);
      return(-1);
     }

   void ClearSlots(void)
     {
      for(int i=0;i<m_count;i++)
        {
         if(CheckPointer(m_slots[i])==POINTER_DYNAMIC)
           {
            m_slots[i].Deinit();
            delete m_slots[i];
           }
        }
      ArrayResize(m_slots,0);
      m_count=0;
     }

public:
                     CMultiSymbolAnalysisPool(void)
     {
      m_count=0;
      m_max_symbols=8;
      m_tf=PERIOD_M1;
      m_min_score=60.0;
      m_min_gap=15.0;
      m_last_error="";
     }

                    ~CMultiSymbolAnalysisPool(void) { ClearSlots(); }

   bool              Configure(const int max_symbols,
                               const ENUM_TIMEFRAMES timeframe=PERIOD_M1,
                               const double min_score=60.0,
                               const double min_gap=15.0)
     {
      if(max_symbols<1 || max_symbols>AX_MAX_ANALYSIS_SLOTS ||
         min_score<0.0 || min_score>100.0 || min_gap<0.0 || min_gap>100.0)
        {
         m_last_error="Invalid pool configuration";
         return(false);
        }
      ClearSlots();
      m_max_symbols=max_symbols;
      m_tf=timeframe;
      m_min_score=min_score;
      m_min_gap=min_gap;
      m_last_error="";
      return(true);
     }

   // Scanner candidates are already sorted by relative spread. The pool caps
   // work per cycle and retains independent state for each active symbol.
   bool              Refresh(CMarketScanner &scanner)
     {
      m_last_error="";
      if(scanner.Count()<=0)
        {
         m_last_error="Scanner returned no eligible candidates";
         return(false);
        }

      string wanted[];
      int wanted_count=0;
      // Retain current members while they remain in the eligible candidate list.
      for(int i=0;i<m_count && wanted_count<m_max_symbols;i++)
        {
         string active=m_slots[i].Symbol();
         bool eligible=false;
         for(int j=0;j<scanner.Count();j++)
           {
            SAxScanCandidate candidate;
            if(scanner.Get(j,candidate) && candidate.symbol==active)
              { eligible=true; break; }
           }
         if(!eligible) continue;
         int resized=ArrayResize(wanted,wanted_count+1);
         if(resized!=wanted_count+1) { m_last_error="Unable to allocate symbol list"; return(false); }
         wanted[wanted_count]=active;
         wanted_count++;
        }
      // Fill spare capacity by scanner rank; existing members are not duplicated.
      for(int j=0;j<scanner.Count() && wanted_count<m_max_symbols;j++)
        {
         SAxScanCandidate candidate;
         if(!scanner.Get(j,candidate) || StringLen(candidate.symbol)==0) continue;
         bool duplicate=false;
         for(int k=0;k<wanted_count;k++) if(wanted[k]==candidate.symbol) { duplicate=true; break; }
         if(duplicate) continue;
         int resized=ArrayResize(wanted,wanted_count+1);
         if(resized!=wanted_count+1) { m_last_error="Unable to allocate symbol list"; return(false); }
         wanted[wanted_count]=candidate.symbol;
         wanted_count++;
        }
      if(wanted_count==0)
        {
         m_last_error="No candidate symbols were usable";
         return(false);
        }

      // Retain existing slot state for symbols that remain in the capped set;
      // release slots that dropped out, then initialize new symbols.
      for(int i=m_count-1;i>=0;i--)
        {
         bool keep=false;
         for(int j=0;j<wanted_count;j++)
            if(m_slots[i].Symbol()==wanted[j]) { keep=true; break; }
         if(!keep)
           {
            if(CheckPointer(m_slots[i])==POINTER_DYNAMIC)
              {
               m_slots[i].Deinit();
               delete m_slots[i];
              }
            for(int k=i;k<m_count-1;k++) m_slots[k]=m_slots[k+1];
            ArrayResize(m_slots,m_count-1);
            m_count--;
           }
        }

      for(int j=0;j<wanted_count;j++)
        {
         if(FindSlot(wanted[j])>=0) continue;
         if(m_count>=m_max_symbols) break;
         CSymbolAnalysisSlot *slot=new CSymbolAnalysisSlot;
         if(CheckPointer(slot)!=POINTER_DYNAMIC)
           {
            m_last_error="Unable to allocate analysis slot";
            return(false);
           }
         if(!slot.Init(wanted[j],m_tf,m_min_score,m_min_gap))
           {
            slot.Deinit();
            delete slot;
            continue;
           }
         int resized=ArrayResize(m_slots,m_count+1);
         if(resized!=m_count+1)
           {
            slot.Deinit();
            delete slot;
            m_last_error="Unable to allocate slot registry";
            return(false);
           }
         m_slots[m_count]=slot;
         m_count++;
        }

      // Update each independent slot. Invalid results remain invalid and do
      // not get silently promoted to directional signals.
      for(int i=0;i<m_count;i++)
         if(CheckPointer(m_slots[i])==POINTER_DYNAMIC)
            m_slots[i].Update();

      return(m_count>0);
     }

   int               Count(void) const { return(m_count); }
   string            LastError(void) const { return(m_last_error); }

   bool              GetResult(const int index,SAxSymbolAnalysis &out) const
     {
      if(index<0 || index>=m_count) return(false);
      if(CheckPointer(m_slots[index])!=POINTER_DYNAMIC) return(false);
      return(m_slots[index].GetResult(out));
     }

   // Return the best valid analytical proposal by score confidence. This is
   // NOT risk approval and must never be wired directly to order submission.
   bool              BestAnalyticalCandidate(SAxSymbolAnalysis &out) const
     {
      bool found=false;
      double best=-1.0;
      for(int i=0;i<m_count;i++)
        {
         if(CheckPointer(m_slots[i])!=POINTER_DYNAMIC) continue;
         SAxSymbolAnalysis result;
         if(!m_slots[i].GetResult(result) || !result.valid || result.action==AX_DIR_NONE)
            continue;
         if(result.confidence>best)
           {
            best=result.confidence;
            out=result;
            found=true;
           }
        }
      return(found);
     }
  };

#endif // AUTOPSYX_MULTI_SYMBOL_ANALYSIS_POOL_MQH
