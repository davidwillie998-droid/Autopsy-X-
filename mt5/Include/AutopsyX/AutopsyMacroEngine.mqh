//+------------------------------------------------------------------+
//|                                        AutopsyMacroEngine.mqh     |
//|  AUTOPSY X — Macro Confirmation Engine (spec section 8)            |
//|                                                                     |
//|  IMPORTANT DATA-AVAILABILITY NOTE                                  |
//|  MT5 has no native feed for Treasury yields, real yields, or Fed   |
//|  rate-expectations — those simply don't exist as terminal symbols  |
//|  on the vast majority of brokers. DXY (or a USD index CFD) often   |
//|  does exist as a symbol, so that leg is read directly.             |
//|                                                                     |
//|  For the rest, this engine reads a small, documented set of        |
//|  GlobalVariables that an EXTERNAL feeder is responsible for        |
//|  keeping fresh (see mt5/README.md). The repo's existing            |
//|  server/server.js bridge is a natural place to add that feed —     |
//|  it already talks to the terminal for the live MT5 panel.          |
//|  Until something is writing them, these fields simply read as      |
//|  DEGRADED and drop out of the composite score rather than being    |
//|  guessed at.                                                       |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyXCommon.mqh"

#define AX_GV_US02Y_LEVEL        "Ax_US02Y_Level"
#define AX_GV_US02Y_CHG_BPS      "Ax_US02Y_ChangeBps"
#define AX_GV_US10Y_LEVEL        "Ax_US10Y_Level"
#define AX_GV_US10Y_CHG_BPS      "Ax_US10Y_ChangeBps"
#define AX_GV_REALYIELD_LEVEL    "Ax_RealYield10Y_Level"
#define AX_GV_REALYIELD_CHG_BPS  "Ax_RealYield10Y_ChangeBps"
#define AX_GV_FED_EXPECT_SCORE   "Ax_FedExpectations_Score"   // -100 (dovish surprise) .. +100 (hawkish surprise), externally computed
#define AX_GV_MACRO_LAST_UPDATE  "Ax_Macro_LastUpdateUnix"

struct AxMacroState
  {
   double              dxyChangePct;      // % change over the configured lookback, or 0 if unavailable
   bool                dxyOk;
   double              us02yChangeBps;
   bool                us02yOk;
   double              us10yChangeBps;
   bool                us10yOk;
   double              realYieldChangeBps;
   bool                realYieldOk;
   double              fedExpectationsScore; // as fed externally, -100..100
   bool                fedExpectationsOk;
   double              macroScore;        // -100 (headwind) .. +100 (tailwind) for the current risk-on read
   int                 componentsAvailable;
   ENUM_AX_DATA_STATUS dataStatus;
  };

class CAxMacroEngine
  {
private:
   string          m_dxySymbol;       // "" disables the direct DXY read
   ENUM_TIMEFRAMES m_tf;
   int             m_dxyLookbackBars;
   int             m_staleAfterSeconds; // GlobalVariable-fed data older than this reads DEGRADED

   //--- component weights (renormalized over whatever is actually available)
   double m_wDxy, m_wYields, m_wFed;

   bool GvReadDouble(string name, double &out)
     {
      if(!GlobalVariableCheck(name))
         return false;
      out = GlobalVariableGet(name);
      return true;
     }

public:
   CAxMacroEngine()
     {
      m_dxySymbol        = "";
      m_tf               = PERIOD_D1;
      m_dxyLookbackBars  = 5;
      m_staleAfterSeconds = 24 * 3600; // one day; tighten for an intraday deployment

      m_wDxy    = 0.30;
      m_wYields = 0.40;
      m_wFed    = 0.30;
     }

   void SetInstrument(string dxySymbol, ENUM_TIMEFRAMES tf, int dxyLookbackBars = 5)
     {
      m_dxySymbol       = dxySymbol;
      m_tf              = tf;
      m_dxyLookbackBars = MathMax(1, dxyLookbackBars);
     }

   void SetWeights(double wDxy, double wYields, double wFed)
     {
      double sum = wDxy + wYields + wFed;
      if(sum <= 0.0) { m_wDxy = 0.30; m_wYields = 0.40; m_wFed = 0.30; return; }
      m_wDxy = wDxy / sum; m_wYields = wYields / sum; m_wFed = wFed / sum;
     }

   void SetStalenessLimit(int seconds) { m_staleAfterSeconds = MathMax(60, seconds); }

   AxMacroState Update()
     {
      AxMacroState s;
      s.dxyChangePct = 0.0; s.dxyOk = false;
      s.us02yChangeBps = 0.0; s.us02yOk = false;
      s.us10yChangeBps = 0.0; s.us10yOk = false;
      s.realYieldChangeBps = 0.0; s.realYieldOk = false;
      s.fedExpectationsScore = 0.0; s.fedExpectationsOk = false;
      s.macroScore = 0.0; s.componentsAvailable = 0;
      s.dataStatus = AX_DATA_OK;

      //--- DXY: read directly from the terminal if a symbol was configured
      if(StringLen(m_dxySymbol) > 0 && SymbolSelect(m_dxySymbol, true))
        {
         double now  = iClose(m_dxySymbol, m_tf, 0);
         double then = iClose(m_dxySymbol, m_tf, m_dxyLookbackBars);
         if(now > 0.0 && then > 0.0)
           {
            s.dxyChangePct = (now - then) / then * 100.0;
            s.dxyOk = true;
           }
        }

      //--- Freshness gate for everything fed externally
      double lastUpdate = 0.0;
      bool haveTimestamp = GvReadDouble(AX_GV_MACRO_LAST_UPDATE, lastUpdate);
      bool feedFresh = haveTimestamp && (TimeCurrent() - (datetime)lastUpdate) <= m_staleAfterSeconds;

      double v;
      if(feedFresh && GvReadDouble(AX_GV_US02Y_CHG_BPS, v)) { s.us02yChangeBps = v; s.us02yOk = true; }
      if(feedFresh && GvReadDouble(AX_GV_US10Y_CHG_BPS, v)) { s.us10yChangeBps = v; s.us10yOk = true; }
      if(feedFresh && GvReadDouble(AX_GV_REALYIELD_CHG_BPS, v)) { s.realYieldChangeBps = v; s.realYieldOk = true; }
      if(feedFresh && GvReadDouble(AX_GV_FED_EXPECT_SCORE, v)) { s.fedExpectationsScore = AxClamp(v, -100.0, 100.0); s.fedExpectationsOk = true; }

      //--- Compose. Rising real yields, a strengthening dollar, and a hawkish
      //    Fed surprise are treated as headwinds for a long-duration, growth-
      //    heavy index like Nasdaq — each pulls the score negative. This is a
      //    directional convention, not a law of markets; if your read of the
      //    macro regime differs, invert the sign at the feeder, not here.
      double weightedSum = 0.0, weightUsed = 0.0;

      if(s.dxyOk)
        {
         double dxyComp = -AxClamp(s.dxyChangePct / 1.5, -1.0, 1.0) * 100.0; // +1.5% DXY move treated as a full-scale headwind
         weightedSum += dxyComp * m_wDxy;
         weightUsed  += m_wDxy;
         s.componentsAvailable++;
        }

      if(s.us02yOk || s.us10yOk || s.realYieldOk)
        {
         double yieldSum = 0.0; int yieldN = 0;
         if(s.us02yOk)     { yieldSum += -AxClamp(s.us02yChangeBps / 25.0, -1.0, 1.0); yieldN++; }
         if(s.us10yOk)     { yieldSum += -AxClamp(s.us10yChangeBps / 25.0, -1.0, 1.0); yieldN++; }
         if(s.realYieldOk) { yieldSum += -AxClamp(s.realYieldChangeBps / 20.0, -1.0, 1.0); yieldN++; } // real yields matter most for duration-sensitive tech, tighter band
         double yieldComp = (yieldN > 0 ? (yieldSum / yieldN) * 100.0 : 0.0);
         weightedSum += yieldComp * m_wYields;
         weightUsed  += m_wYields;
         s.componentsAvailable++;
        }

      if(s.fedExpectationsOk)
        {
         weightedSum += (-s.fedExpectationsScore) * m_wFed; // hawkish surprise (+) -> headwind (-)
         weightUsed  += m_wFed;
         s.componentsAvailable++;
        }

      if(weightUsed > 0.0)
         s.macroScore = AxClamp(weightedSum / weightUsed, -100.0, 100.0);
      else
         s.macroScore = 0.0;

      if(s.componentsAvailable == 0)
         s.dataStatus = AX_DATA_UNAVAILABLE;
      else if(s.componentsAvailable < 3 || (haveTimestamp && !feedFresh))
         s.dataStatus = AX_DATA_DEGRADED;

      return s;
     }
  };
