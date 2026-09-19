//+------------------------------------------------------------------+
//| AutopsyMomentumEngine.mqh                                           |
//| Cross-sectional Formation/Skip/Holding (F/S/H) momentum and       |
//| contrarian engine, adapted from Patnaik & Thomas, "Profitability  |
//| of Trading Strategies on High-Frequency Data, with Trading Costs" |
//| (SSRN 568363, 2004): rank a configured basket by formation-period |
//| return, form winner/loser groups, and only signal a trade when    |
//| the winner-loser spread survives REAL transaction costs. The      |
//| paper's central finding is that "paper profits" evaporate once     |
//| real, non-proportional trading costs (price impact / spread) are  |
//| subtracted - this engine refuses to signal any edge that wouldn't |
//| have survived that same test.                                     |
//|                                                                    |
//| "Current tech": the paper's only way to get a real, non-fabricated|
//| buy/sell price in 2004 was a monthly CD of NSE limit-order-book    |
//| snapshots, sampled four times a day. This engine instead reads    |
//| this account's own LIVE bid/ask spread and its own observed        |
//| execution slippage (when the caller's execution engine supplies   |
//| it) every time it evaluates - an always-current cost model a      |
//| static historical snapshot could never match.                     |
//|                                                                    |
//| Also exposes the Lo & MacKinlay (1990) profit decomposition as a  |
//| diagnostic: how much of the cross-sectional edge is dispersion in |
//| mean returns vs. idiosyncratic (own-return) serial correlation    |
//| vs. cross-serial (lead-lag) correlation between basket members -  |
//| the paper's own answer to WHY a momentum/contrarian edge exists,  |
//| not just whether it does. This is computed fresh from this        |
//| account's own current data, not assumed from the 2004 Indian      |
//| result (which found momentum dominant there and then - that does  |
//| not mean momentum is the right style for a different market and   |
//| era, so this engine measures it rather than hard-codes it).       |
//+------------------------------------------------------------------+
#property strict
#ifndef AUTOPSYX_MOMENTUMENGINE_MQH
#define AUTOPSYX_MOMENTUMENGINE_MQH
#include "AutopsyTypes.mqh"

enum ENUM_AXM_STYLE { AXM_MOMENTUM, AXM_CONTRARIAN };

//--- one symbol's cross-sectional standing and cost-gated signal
struct AXMSignal
  {
   bool   valid;
   int    direction;         // +1 long, -1 short, 0 = no signal (either mid-pack or fails the cost gate)
   double formationReturn;   // this symbol's own formation-period return
   double groupSpread;       // winner-group mean return - loser-group mean return, as a %, the raw edge
   double roundTripCostPct;  // real, live round-trip cost estimate for this symbol right now
   double netEdgePct;        // |groupSpread| minus (roundTripCostPct x safety multiple) - what survives
   int    rank;              // 1 = strongest winner .. N = strongest loser
   int    universeSize;
   string reason;
  };

//--- Lo & MacKinlay (1990) decomposition, eq 22 in the paper
struct AXMDecomposition
  {
   double crossSectionalVarianceOfMeans; // sigma^2(mu): dispersion in basket members' own mean returns
   double meanSerialCovariance;          // O_k proxy: mean own-return lag-1 autocovariance (idiosyncratic)
   double crossSerialCovariance;         // C_k proxy: mean cross-symbol lag-1 covariance (lead-lag)
   int    sampleSize;
   string interpretation;
  };

class CAutopsyMomentumEngine
  {
private:
   string          m_universe[];
   ENUM_TIMEFRAMES m_tf;
   int             m_formationBars;
   int             m_skipBars;
   double          m_winnerFraction;
   double          m_minRoundTripCostSafetyMultiple;
   ENUM_AXM_STYLE  m_style;

   void ParseUniverse(const string csv)
     {
      ArrayResize(m_universe, 0);
      string parts[];
      int n = StringSplit(csv, ',', parts);
      for(int i=0;i<n;i++)
        {
         string s = parts[i];
         StringTrimLeft(s); StringTrimRight(s);
         if(s=="" || !SymbolSelect(s,true)) continue;
         int k = ArraySize(m_universe);
         ArrayResize(m_universe, k+1);
         m_universe[k] = s;
        }
     }

   //--- formation-period return on confirmed D1 closes, ending `skipBars` bars before "now" - the skip
   //--- gap keeps the ranking measurement from overlapping the instant the live signal actually acts on
   double FormationReturn(const string sym) const
     {
      double pNow  = iClose(sym, m_tf, m_skipBars+1);
      double pPast = iClose(sym, m_tf, m_skipBars+1+m_formationBars);
      if(pNow<=0.0 || pPast<=0.0) return 0.0;
      return (pNow-pPast)/pPast;
     }

   //--- real, live round-trip cost: today's actual quoted spread (paid entering) plus any observed
   //--- execution slippage the caller supplies (in points, from its own ExecutionEngine-style tracking),
   //--- doubled since the position must eventually exit too. Unresolvable quotes are treated as
   //--- prohibitively costly, never as free - consistent with this whole codebase's fail-safe stance.
   double RoundTripCostPct(const string sym, double extraSlippagePoints) const
     {
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      if(bid<=0.0 || ask<=0.0) return 1.0;
      double mid = (bid+ask)/2.0;
      if(mid<=0.0) return 1.0;
      double spreadCostPct   = (ask-bid)/mid*100.0;
      double slippageCostPct = (extraSlippagePoints*point)/mid*100.0;
      return (spreadCostPct + slippageCostPct) * 2.0;
     }

public:
   void Init(const string universeCsv, ENUM_TIMEFRAMES tf=PERIOD_D1,
             int formationBars=25, int skipBars=1, double winnerFraction=0.3,
             double minRoundTripCostSafetyMultiple=2.0, ENUM_AXM_STYLE style=AXM_MOMENTUM)
     {
      ParseUniverse(universeCsv);
      m_tf = tf;
      m_formationBars = MathMax(2, formationBars);
      m_skipBars = MathMax(0, skipBars);
      m_winnerFraction = MathMax(0.05, MathMin(0.5, winnerFraction));
      m_minRoundTripCostSafetyMultiple = MathMax(1.0, minRoundTripCostSafetyMultiple);
      m_style = style;
     }

   int UniverseSize() const { return ArraySize(m_universe); }
   void SetStyle(ENUM_AXM_STYLE style) { m_style = style; }
   ENUM_AXM_STYLE Style() const { return m_style; }

   //--- ranks the whole configured universe by formation-period return, descending (index 0 = strongest
   //--- winner). Small basket sizes (tens of symbols) make simple insertion sort plenty fast here.
   int RankUniverse(string &sortedSymbolsOut[], double &sortedReturnsOut[]) const
     {
      int n = ArraySize(m_universe);
      ArrayResize(sortedSymbolsOut, n);
      ArrayResize(sortedReturnsOut, n);
      for(int i=0;i<n;i++) { sortedSymbolsOut[i]=m_universe[i]; sortedReturnsOut[i]=FormationReturn(m_universe[i]); }

      for(int i=1;i<n;i++)
        {
         string sk = sortedSymbolsOut[i];
         double rk = sortedReturnsOut[i];
         int j = i-1;
         while(j>=0 && sortedReturnsOut[j]<rk)
           {
            sortedSymbolsOut[j+1]=sortedSymbolsOut[j];
            sortedReturnsOut[j+1]=sortedReturnsOut[j];
            j--;
           }
         sortedSymbolsOut[j+1]=sk; sortedReturnsOut[j+1]=rk;
        }
      return n;
     }

   //--- the winner-group / loser-group mean-return spread - the raw, pre-cost cross-sectional edge
   double ComputeGroupSpread(string &sortedSymbolsOut[], double &sortedReturnsOut[]) const
     {
      int n = RankUniverse(sortedSymbolsOut, sortedReturnsOut);
      if(n<4) return 0.0;
      int groupSize = MathMax(1, (int)MathRound(n*m_winnerFraction));

      double winnerSum=0.0, loserSum=0.0;
      for(int i=0;i<groupSize;i++) winnerSum += sortedReturnsOut[i];
      for(int i=n-groupSize;i<n;i++) loserSum += sortedReturnsOut[i];
      return winnerSum/groupSize - loserSum/groupSize;
     }

   //--- the actual, cost-gated signal for ONE symbol. Neither winner nor loser this period, or an edge
   //--- that doesn't clear its own live round-trip cost by the configured safety multiple, both come
   //--- back as direction=0 - "no signal" is the default outcome here, same as everywhere else in AUTOPSY X.
   AXMSignal GetSignal(const string symbol, double extraSlippagePoints=0.0) const
     {
      AXMSignal s;
      s.valid=false; s.direction=0; s.formationReturn=0.0; s.groupSpread=0.0;
      s.roundTripCostPct=0.0; s.netEdgePct=0.0; s.rank=0; s.universeSize=0; s.reason="";

      string symbols[]; double returns[];
      int n = RankUniverse(symbols, returns);
      s.universeSize = n;
      if(n<4) { s.reason="Universe too small to rank (need >=4 symbols)"; return s; }

      int idx=-1;
      for(int i=0;i<n;i++) if(symbols[i]==symbol) { idx=i; break; }
      if(idx<0) { s.reason=StringFormat("%s is not in the configured universe", symbol); return s; }

      s.rank = idx+1;
      s.formationReturn = returns[idx];
      int groupSize = MathMax(1, (int)MathRound(n*m_winnerFraction));
      bool isWinner = idx<groupSize;
      bool isLoser  = idx>=n-groupSize;
      if(!isWinner && !isLoser)
        { s.reason="Middle of the pack - neither a winner nor a loser this formation period"; return s; }

      double winnerSum=0.0, loserSum=0.0;
      for(int i=0;i<groupSize;i++) winnerSum += returns[i];
      for(int i=n-groupSize;i<n;i++) loserSum += returns[i];
      double spread = winnerSum/groupSize - loserSum/groupSize;
      s.groupSpread = spread*100.0;

      // momentum: ride winners, fade losers (recent trend continues); contrarian: the opposite (mean reversion)
      int rawDirection = isWinner ? 1 : -1;
      s.direction = (m_style==AXM_MOMENTUM) ? rawDirection : -rawDirection;

      s.roundTripCostPct = RoundTripCostPct(symbol, extraSlippagePoints);
      s.netEdgePct = MathAbs(s.groupSpread) - s.roundTripCostPct*m_minRoundTripCostSafetyMultiple;

      if(s.netEdgePct<=0.0)
        {
         s.direction=0;
         s.reason = StringFormat("Raw edge %.3f%% does not clear %.1fx round-trip cost %.3f%% - paper profit only, not a real one",
                                  s.groupSpread, m_minRoundTripCostSafetyMultiple, s.roundTripCostPct);
         return s;
        }

      s.valid = true;
      s.reason = StringFormat("%s rank %d/%d, formation return %.3f%%, group spread %.3f%%, net edge %.3f%% after %.1fx live cost",
                               (m_style==AXM_MOMENTUM?"Momentum":"Contrarian"), s.rank, n, s.formationReturn*100.0,
                               s.groupSpread, s.netEdgePct, m_minRoundTripCostSafetyMultiple);
      return s;
     }

   //--- Lo & MacKinlay (1990), eq 22: decomposes the cross-sectional edge into cross-sectional
   //--- dispersion in mean returns, mean own-return lag-1 autocovariance (idiosyncratic reaction), and
   //--- mean cross-symbol lag-1 covariance (lead-lag). Uses a flat row-major buffer (symbol i's return
   //--- at bar t lives at rets[i*usableBars+t]) since MQL5 has no true jagged 2D dynamic array. O(n^2 x
   //--- bars) for the cross-covariance term - call this occasionally (e.g. once a day) as a diagnostic,
   //--- not every tick.
   AXMDecomposition ComputeProfitDecomposition(int sampleBars=252) const
     {
      AXMDecomposition d;
      d.crossSectionalVarianceOfMeans=0.0; d.meanSerialCovariance=0.0; d.crossSerialCovariance=0.0;
      d.sampleSize=0; d.interpretation="Insufficient data";

      int n = ArraySize(m_universe);
      if(n<4) return d;

      int usableBars = sampleBars;
      for(int i=0;i<n;i++)
        {
         int bars = iBars(m_universe[i], m_tf);
         if(bars < usableBars+2) usableBars = MathMax(0, bars-2);
        }
      if(usableBars<20) return d;

      double rets[]; // flat, row-major: symbol i's return at bar t is rets[i*usableBars+t]
      ArrayResize(rets, n*usableBars);
      for(int i=0;i<n;i++)
        {
         MqlRates rates[];
         int copied = CopyRates(m_universe[i], m_tf, 1, usableBars+1, rates);
         if(copied<usableBars+1)
           {
            for(int t=0;t<usableBars;t++) rets[i*usableBars+t]=0.0;
            continue;
           }
         ArraySetAsSeries(rates, true);
         for(int t=0;t<usableBars;t++)
           {
            double a=rates[t].close, b=rates[t+1].close;
            rets[i*usableBars+t] = (a>0.0 && b>0.0) ? MathLog(a/b) : 0.0;
           }
        }

      double mean[]; ArrayResize(mean, n);
      double grandMean=0.0;
      for(int i=0;i<n;i++)
        {
         double sum=0.0;
         for(int t=0;t<usableBars;t++) sum += rets[i*usableBars+t];
         mean[i]=sum/usableBars; grandMean+=mean[i];
        }
      grandMean/=n;

      double sigma2Mu=0.0;
      for(int i=0;i<n;i++) sigma2Mu += (mean[i]-grandMean)*(mean[i]-grandMean);
      sigma2Mu/=n;

      double sumOwnCov=0.0;
      for(int i=0;i<n;i++)
        {
         double cov=0.0;
         for(int t=0;t<usableBars-1;t++)
            cov += (rets[i*usableBars+t]-mean[i])*(rets[i*usableBars+t+1]-mean[i]);
         cov /= (usableBars-1);
         sumOwnCov += cov;
        }
      double meanOwnCov = sumOwnCov/n;

      double sumCrossCov=0.0; int pairCount=0;
      for(int i=0;i<n;i++)
         for(int j=0;j<n;j++)
           {
            if(i==j) continue;
            double cov=0.0;
            for(int t=0;t<usableBars-1;t++)
               cov += (rets[j*usableBars+t]-mean[j])*(rets[i*usableBars+t+1]-mean[i]);
            cov /= (usableBars-1);
            sumCrossCov += cov; pairCount++;
           }
      double meanCrossCov = pairCount>0 ? sumCrossCov/pairCount : 0.0;

      d.crossSectionalVarianceOfMeans = sigma2Mu;
      d.meanSerialCovariance = meanOwnCov;
      d.crossSerialCovariance = meanCrossCov;
      d.sampleSize = usableBars;

      double absOwn = MathAbs(meanOwnCov), absCross = MathAbs(meanCrossCov);
      if(absOwn>=absCross && absOwn>sigma2Mu)
         d.interpretation = meanOwnCov<0.0
            ? "Dominated by idiosyncratic (own-return) under-reaction - supports MOMENTUM"
            : "Dominated by idiosyncratic (own-return) over-reaction/mean-reversion - supports CONTRARIAN";
      else if(absCross>sigma2Mu)
         d.interpretation = meanCrossCov<0.0
            ? "Dominated by cross-serial (lead-lag) effects between basket members - supports MOMENTUM"
            : "Dominated by cross-serial (lead-lag) effects between basket members - supports CONTRARIAN";
      else
         d.interpretation = "Dominated by cross-sectional dispersion in mean returns, not serial structure - edge may not persist";
      return d;
     }

   //--- data-driven style recommendation from the decomposition above, rather than assuming the 2004
   //--- Indian-equities paper's own finding (momentum dominant there) transfers to a different market,
   //--- instrument set, and era: negative own/cross-serial covariance is what the Lo-MacKinlay math says
   //--- actually drives momentum profits; positive values say the basket is mean-reverting instead.
   ENUM_AXM_STYLE RecommendedStyleFromDecomposition(const AXMDecomposition &d) const
     {
      double signal = d.meanSerialCovariance + d.crossSerialCovariance;
      return (signal<0.0) ? AXM_MOMENTUM : AXM_CONTRARIAN;
     }
  };
#endif // AUTOPSYX_MOMENTUMENGINE_MQH
