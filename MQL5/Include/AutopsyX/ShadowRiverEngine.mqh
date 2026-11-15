//+------------------------------------------------------------------+
//|                                             ShadowRiverEngine.mqh|
//|  Event-driven directional-change state engine for FlipDemon      |
//|                                                                    |
//|  This module models price movement, not candle colour. It emits  |
//|  an initial direction event, continuation events after each       |
//|  sensitivity-sized advance, and reversal events after price has  |
//|  retraced the configured multiple from the latest extreme.       |
//|                                                                    |
//|  It is an observation/filter component only. It has no trading,   |
//|  sizing, stop-placement, or execution authority.                  |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_SHADOWRIVERENGINE_MQH
#define AX_SHADOWRIVERENGINE_MQH

enum ENUM_AX_SHADOW_EVENT
  {
   AX_SHADOW_NONE = 0,
   AX_SHADOW_INITIAL_UP,
   AX_SHADOW_INITIAL_DOWN,
   AX_SHADOW_CONTINUATION_UP,
   AX_SHADOW_CONTINUATION_DOWN,
   AX_SHADOW_REVERSAL_UP,
   AX_SHADOW_REVERSAL_DOWN
  };

class CShadowRiverEngine
  {
private:
   bool              m_configured;
   double            m_sensitivityPrice;
   double            m_reversalMultiplier;
   double            m_reversalDistance;

   int               m_direction;          // +1 up, -1 down, 0 not established
   double            m_anchorPrice;        // reference before first directional event
   double            m_extremePrice;       // highest high in up leg / lowest low in down leg
   double            m_lastPointPrice;     // last emitted initial/continuation/reversal point
   datetime          m_lastUpdateTime;
   bool              m_haveUpdateTime;
   ulong             m_eventCount;

public:
                     CShadowRiverEngine(void)
     {
      m_configured=false;
      m_sensitivityPrice=0.0;
      m_reversalMultiplier=2.0;
      m_reversalDistance=0.0;
      Reset();
     }

   // Configure with an absolute price distance, already normalized for
   // the instrument's pip/tick convention by the caller.
   bool              ConfigurePriceDistance(const double sensitivityPrice,
                                             const double reversalMultiplier=2.0)
     {
      if(!MathIsValidNumber(sensitivityPrice) || sensitivityPrice<=0.0)
         return(false);
      if(!MathIsValidNumber(reversalMultiplier) || reversalMultiplier<1.0)
         return(false);

      m_sensitivityPrice=sensitivityPrice;
      m_reversalMultiplier=reversalMultiplier;
      m_reversalDistance=sensitivityPrice*reversalMultiplier;
      if(!MathIsValidNumber(m_reversalDistance) || m_reversalDistance<=0.0)
        {
         m_configured=false;
         return(false);
        }

      m_configured=true;
      Reset();
      return(true);
     }

   // Convenience configuration when the caller has a reliable MT5 point
   // size. Do not pass "pips" as points without converting them first.
   bool              ConfigurePoints(const double sensitivityPoints,
                                      const double pointSize,
                                      const double reversalMultiplier=2.0)
     {
      if(!MathIsValidNumber(sensitivityPoints) || sensitivityPoints<=0.0 ||
         !MathIsValidNumber(pointSize) || pointSize<=0.0)
         return(false);
      return(ConfigurePriceDistance(sensitivityPoints*pointSize,reversalMultiplier));
     }

   // Reset the observed price path while preserving the configured thresholds.
   void              Reset(void)
     {
      m_direction=0;
      m_anchorPrice=0.0;
      m_extremePrice=0.0;
      m_lastPointPrice=0.0;
      m_lastUpdateTime=0;
      m_haveUpdateTime=false;
      m_eventCount=0;
     }

   // Feed one valid mid-price sample. The method emits at most one event
   // per sample. A reversal takes precedence over a continuation event.
   ENUM_AX_SHADOW_EVENT Update(const double price,const datetime sampleTime)
     {
      if(!m_configured || !MathIsValidNumber(price) || price<=0.0)
         return(AX_SHADOW_NONE);

      // Reject out-of-order samples. Equal-second tick timestamps are valid.
      if(m_haveUpdateTime && sampleTime<m_lastUpdateTime)
         return(AX_SHADOW_NONE);

      m_lastUpdateTime=sampleTime;
      m_haveUpdateTime=true;

      if(m_direction==0)
        {
         if(m_anchorPrice<=0.0)
           {
            m_anchorPrice=price;
            m_extremePrice=price;
            m_lastPointPrice=price;
            return(AX_SHADOW_NONE);
           }

         if(price-m_anchorPrice>=m_sensitivityPrice)
           {
            m_direction=1;
            m_extremePrice=price;
            m_lastPointPrice=price;
            m_eventCount++;
            return(AX_SHADOW_INITIAL_UP);
           }

         if(m_anchorPrice-price>=m_sensitivityPrice)
           {
            m_direction=-1;
            m_extremePrice=price;
            m_lastPointPrice=price;
            m_eventCount++;
            return(AX_SHADOW_INITIAL_DOWN);
           }
         return(AX_SHADOW_NONE);
        }

      if(m_direction>0)
        {
         if(price>m_extremePrice)
            m_extremePrice=price;

         if(m_extremePrice-price>=m_reversalDistance)
           {
            m_direction=-1;
            m_extremePrice=price;
            m_lastPointPrice=price;
            m_eventCount++;
            return(AX_SHADOW_REVERSAL_DOWN);
           }

         if(price-m_lastPointPrice>=m_sensitivityPrice)
           {
            m_lastPointPrice=price;
            m_eventCount++;
            return(AX_SHADOW_CONTINUATION_UP);
           }
         return(AX_SHADOW_NONE);
        }

      // Established down leg.
      if(price<m_extremePrice)
         m_extremePrice=price;

      if(price-m_extremePrice>=m_reversalDistance)
        {
         m_direction=1;
         m_extremePrice=price;
         m_lastPointPrice=price;
         m_eventCount++;
         return(AX_SHADOW_REVERSAL_UP);
        }

      if(m_lastPointPrice-price>=m_sensitivityPrice)
        {
         m_lastPointPrice=price;
         m_eventCount++;
         return(AX_SHADOW_CONTINUATION_DOWN);
        }

      return(AX_SHADOW_NONE);
     }

   bool              IsConfigured(void) const { return(m_configured); }
   int               Direction(void) const { return(m_direction); }
   double            SensitivityPrice(void) const { return(m_sensitivityPrice); }
   double            ReversalMultiplier(void) const { return(m_reversalMultiplier); }
   double            ReversalDistance(void) const { return(m_reversalDistance); }
   double            ExtremePrice(void) const { return(m_extremePrice); }
   double            LastPointPrice(void) const { return(m_lastPointPrice); }
   ulong             EventCount(void) const { return(m_eventCount); }
  };

#endif // AX_SHADOWRIVERENGINE_MQH
