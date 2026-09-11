//+------------------------------------------------------------------+
//| StructureEngine.mqh                                               |
//| Objective, rule-based market structure: swing points, BOS/CHOCH/  |
//| MSS, fair value gaps and order blocks. Every structure carries a  |
//| measurable quality score - nothing here is a "looks like" call.   |
//+------------------------------------------------------------------+
#property strict
#ifndef AX_CORE_STRUCTUREENGINE_MQH
#define AX_CORE_STRUCTUREENGINE_MQH
#include "Types.mqh"
#include "MarketState.mqh"

class CStructureEngine
  {
private:
   CMarketState *m_market;
   int           m_leftBars;
   int           m_rightBars;

   bool IsSwingHigh(ENUM_TIMEFRAMES tf, int shift) const
     {
      double h = m_market.High(tf, shift);
      for(int i=1;i<=m_leftBars;i++)
         if(m_market.High(tf, shift+i) >= h) return false;
      for(int i=1;i<=m_rightBars;i++)
         if(m_market.High(tf, shift-i) >= h) return false;
      return true;
     }

   bool IsSwingLow(ENUM_TIMEFRAMES tf, int shift) const
     {
      double l = m_market.Low(tf, shift);
      for(int i=1;i<=m_leftBars;i++)
         if(m_market.Low(tf, shift+i) <= l) return false;
      for(int i=1;i<=m_rightBars;i++)
         if(m_market.Low(tf, shift-i) <= l) return false;
      return true;
     }

public:
   void Init(CMarketState *market, int leftBars=3, int rightBars=3)
     {
      m_market   = market;
      m_leftBars = leftBars;
      m_rightBars= rightBars;
     }

   //--- collect the most recent swing points on a timeframe, most recent first
   int GetSwings(ENUM_TIMEFRAMES tf, AXSwingPoint &out[], int maxSwings=20) const
     {
      ArrayResize(out, 0);
      int bars = m_market.Bars(tf);
      int lastShift = bars - m_leftBars - 1;
      for(int shift=m_rightBars; shift<lastShift && ArraySize(out)<maxSwings; shift++)
        {
         if(IsSwingHigh(tf, shift))
           {
            AXSwingPoint sp;
            sp.time=m_market.Time(tf,shift); sp.price=m_market.High(tf,shift);
            sp.isHigh=true; sp.barShift=shift; sp.taken=false;
            int n=ArraySize(out); ArrayResize(out,n+1); out[n]=sp;
           }
         else if(IsSwingLow(tf, shift))
           {
            AXSwingPoint sp;
            sp.time=m_market.Time(tf,shift); sp.price=m_market.Low(tf,shift);
            sp.isHigh=false; sp.barShift=shift; sp.taken=false;
            int n=ArraySize(out); ArrayResize(out,n+1); out[n]=sp;
           }
        }
      return ArraySize(out);
     }

   //--- classify structure using the two most recent swing highs and lows
   AXStructureSnapshot GetSnapshot(ENUM_TIMEFRAMES tf) const
     {
      AXStructureSnapshot snap;
      snap.lastEvent = STRUCT_NONE;
      snap.lastEventTime = 0;
      snap.lastEventPrice = 0.0;
      snap.bullishStructure = true;
      snap.lastSwingHigh = 0.0;
      snap.lastSwingLow  = 0.0;

      AXSwingPoint swings[];
      GetSwings(tf, swings, 12);
      if(ArraySize(swings) < 4) return snap;

      double highs[]; double lows[];
      datetime highTimes[]; datetime lowTimes[];
      ArrayResize(highs,0); ArrayResize(lows,0);
      for(int i=0;i<ArraySize(swings);i++)
        {
         if(swings[i].isHigh) { int n=ArraySize(highs); ArrayResize(highs,n+1); ArrayResize(highTimes,n+1); highs[n]=swings[i].price; highTimes[n]=swings[i].time; }
         else                 { int n=ArraySize(lows);  ArrayResize(lows,n+1);  ArrayResize(lowTimes,n+1);  lows[n]=swings[i].price;  lowTimes[n]=swings[i].time; }
        }
      if(ArraySize(highs)>=1) snap.lastSwingHigh = highs[0];
      if(ArraySize(lows)>=1)  snap.lastSwingLow  = lows[0];

      bool higherHighs = (ArraySize(highs)>=2) && (highs[0] > highs[1]);
      bool higherLows  = (ArraySize(lows)>=2)  && (lows[0]  > lows[1]);
      bool lowerHighs  = (ArraySize(highs)>=2) && (highs[0] < highs[1]);
      bool lowerLows   = (ArraySize(lows)>=2)  && (lows[0]  < lows[1]);

      if(higherHighs && higherLows)      snap.bullishStructure = true;
      else if(lowerHighs && lowerLows)   snap.bullishStructure = false;

      double closeNow = m_market.Close(tf, 0);

      //--- BOS: close beyond the prior swing in the direction of existing structure
      //--- CHOCH: close beyond the prior swing against existing structure (first break)
      //--- MSS: CHOCH confirmed by a second break in the new direction (structure flip)
      if(ArraySize(highs)>=1 && closeNow > highs[0])
        {
         if(snap.bullishStructure)
           { snap.lastEvent=STRUCT_BOS_BULL; snap.lastEventPrice=highs[0]; snap.lastEventTime=TimeCurrent(); }
         else
           { snap.lastEvent=(lowerLows? STRUCT_MSS_BULL: STRUCT_CHOCH_BULL); snap.lastEventPrice=highs[0]; snap.lastEventTime=TimeCurrent(); snap.bullishStructure=true; }
        }
      else if(ArraySize(lows)>=1 && closeNow < lows[0])
        {
         if(!snap.bullishStructure)
           { snap.lastEvent=STRUCT_BOS_BEAR; snap.lastEventPrice=lows[0]; snap.lastEventTime=TimeCurrent(); }
         else
           { snap.lastEvent=(higherHighs? STRUCT_MSS_BEAR: STRUCT_CHOCH_BEAR); snap.lastEventPrice=lows[0]; snap.lastEventTime=TimeCurrent(); snap.bullishStructure=false; }
        }

      return snap;
     }

   //--- three-candle fair value gap detection over the last `lookback` closed bars
   int GetFVGs(ENUM_TIMEFRAMES tf, AXFairValueGap &out[], int lookback=80) const
     {
      ArrayResize(out, 0);
      int bars = MathMin(lookback, m_market.Bars(tf)-3);
      for(int shift=1; shift<bars; shift++)
        {
         // bullish FVG: candle[shift+1].high < candle[shift-1].low, displacement candle in the middle
         double h2 = m_market.High(tf, shift+1);
         double l0 = m_market.Low(tf, shift-1);
         if(h2 < l0)
           {
            AXFairValueGap gap; gap.top=l0; gap.bottom=h2; gap.time=m_market.Time(tf,shift);
            gap.bullish=true; gap.mitigated=false; gap.mitigationPct=0.0;
            EvaluateMitigation(tf, shift-1, gap);
            int n=ArraySize(out); ArrayResize(out,n+1); out[n]=gap;
            continue;
           }
         double l2 = m_market.Low(tf, shift+1);
         double h0 = m_market.High(tf, shift-1);
         if(l2 > h0)
           {
            AXFairValueGap gap; gap.top=l2; gap.bottom=h0; gap.time=m_market.Time(tf,shift);
            gap.bullish=false; gap.mitigated=false; gap.mitigationPct=0.0;
            EvaluateMitigation(tf, shift-1, gap);
            int n=ArraySize(out); ArrayResize(out,n+1); out[n]=gap;
           }
        }
      return ArraySize(out);
     }

   //--- last opposite-color candle before a displacement leg = order block candidate
   int GetOrderBlocks(ENUM_TIMEFRAMES tf, AXOrderBlock &out[], int lookback=80) const
     {
      ArrayResize(out, 0);
      double atr = m_market.ATR(tf, 1);
      if(atr<=0.0) return 0;
      int bars = MathMin(lookback, m_market.Bars(tf)-2);
      for(int shift=2; shift<bars; shift++)
        {
         double o = m_market.Open(tf, shift), c = m_market.Close(tf, shift);
         double dispHigh = m_market.High(tf, shift-1);
         double dispLow  = m_market.Low(tf, shift-1);
         double dispRange = dispHigh - dispLow;
         bool displacementUp   = (m_market.Close(tf,shift-1) - m_market.Open(tf,shift-1)) > atr*0.8;
         bool displacementDown = (m_market.Open(tf,shift-1) - m_market.Close(tf,shift-1)) > atr*0.8;

         if(displacementUp && c < o) // bearish candle followed by bullish displacement = bullish OB
           {
            AXOrderBlock ob; ob.top=MathMax(o,c); ob.bottom=MathMin(o,c);
            ob.time=m_market.Time(tf,shift); ob.bullish=true; ob.mitigated=false; ob.tf=tf;
            ob.qualityScore = ScoreOrderBlock(dispRange, atr, shift, bars);
            int n=ArraySize(out); ArrayResize(out,n+1); out[n]=ob;
           }
         else if(displacementDown && c > o) // bullish candle followed by bearish displacement = bearish OB
           {
            AXOrderBlock ob; ob.top=MathMax(o,c); ob.bottom=MathMin(o,c);
            ob.time=m_market.Time(tf,shift); ob.bullish=false; ob.mitigated=false; ob.tf=tf;
            ob.qualityScore = ScoreOrderBlock(dispRange, atr, shift, bars);
            int n=ArraySize(out); ArrayResize(out,n+1); out[n]=ob;
           }
        }
      return ArraySize(out);
     }

private:
   void EvaluateMitigation(ENUM_TIMEFRAMES tf, int fromShift, AXFairValueGap &gap) const
     {
      double size = gap.top - gap.bottom;
      if(size<=0.0) return;
      double deepest = gap.bullish ? gap.top : gap.bottom;
      for(int i=fromShift; i>=0; i--)
        {
         double lo = m_market.Low(tf,i), hi = m_market.High(tf,i);
         if(gap.bullish)
           {
            if(lo < deepest) deepest = lo;
            if(lo <= gap.bottom) { gap.mitigated=true; gap.mitigationPct=1.0; return; }
           }
         else
           {
            if(hi > deepest) deepest = hi;
            if(hi >= gap.top) { gap.mitigated=true; gap.mitigationPct=1.0; return; }
           }
        }
      double penetration = gap.bullish ? (gap.top-deepest) : (deepest-gap.bottom);
      gap.mitigationPct = MathMax(0.0, MathMin(1.0, penetration/size));
     }

   //--- quality: bigger displacement relative to ATR and fresher age score higher
   double ScoreOrderBlock(double dispRange, double atr, int shift, int totalBars) const
     {
      double dispScore = MathMin(100.0, (dispRange/atr) * 40.0);
      double ageFactor  = 1.0 - (double)shift/MathMax(1,totalBars); // fresher = closer to 1
      double ageScore   = ageFactor * 60.0;
      return MathMax(0.0, MathMin(100.0, dispScore*0.5 + ageScore*0.5));
     }
  };
#endif // AX_CORE_STRUCTUREENGINE_MQH
