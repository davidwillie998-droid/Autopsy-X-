//+------------------------------------------------------------------+
//| PortfolioRiskGate.mqh                                            |
//| Account-wide, fail-closed pre-trade gate for future integration.  |
//| Advisory module only: does not submit, modify, or close orders.   |
//+------------------------------------------------------------------+
#ifndef AUTOPSYX_PORTFOLIO_RISK_GATE_MQH
#define AUTOPSYX_PORTFOLIO_RISK_GATE_MQH
#property strict

class CPortfolioRiskGate
  {
private:
   double m_max_trade_risk_pct;
   double m_max_margin_usage_pct;
   bool   m_require_flat_account;

public:
                     CPortfolioRiskGate(void)
     {
      m_max_trade_risk_pct=0.5;
      m_max_margin_usage_pct=30.0;
      m_require_flat_account=true;
     }

   bool              Configure(const double max_trade_risk_pct,
                               const double max_margin_usage_pct,
                               const bool require_flat_account=true)
     {
      if(max_trade_risk_pct<=0.0 || max_trade_risk_pct>2.0 ||
         max_margin_usage_pct<=0.0 || max_margin_usage_pct>100.0)
         return(false);
      m_max_trade_risk_pct=max_trade_risk_pct;
      m_max_margin_usage_pct=max_margin_usage_pct;
      m_require_flat_account=require_flat_account;
      return(true);
     }

   // Conservative first integration contract:
   // - only BUY/SELL market candidates are accepted;
   // - volume must satisfy current broker min/max/step;
   // - a valid stop-loss is mandatory and estimated loss must fit risk budget;
   // - account positions/orders block entry when flat-account mode is enabled;
   // - projected margin usage must remain below configured ceiling.
   // This gate is not execution authorization by itself; caller must run all
   // existing signal, session, spread, drawdown, loss-limit and final-confirm checks.
   bool              Evaluate(const string symbol,
                              const ENUM_ORDER_TYPE order_type,
                              const double volume,
                              const double entry_price,
                              const double stop_loss,
                              string &reason) const
     {
      reason="";
      if(symbol=="" || (order_type!=ORDER_TYPE_BUY && order_type!=ORDER_TYPE_SELL))
        { reason="Invalid symbol or unsupported order type"; return(false); }
      if(volume<=0.0 || entry_price<=0.0 || stop_loss<=0.0)
        { reason="Invalid volume, entry, or stop-loss"; return(false); }
      if((order_type==ORDER_TYPE_BUY && stop_loss>=entry_price) ||
         (order_type==ORDER_TYPE_SELL && stop_loss<=entry_price))
        { reason="Stop-loss is not on the loss side of entry"; return(false); }

      double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
      double vmax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
      double vstep=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
      if(vmin<=0.0 || vmax<vmin || vstep<=0.0 ||
         volume<vmin-1e-8 || volume>vmax+1e-8)
        { reason="Volume violates broker min/max/step metadata"; return(false); }
      double steps=(volume-vmin)/vstep;
      if(MathAbs(steps-MathRound(steps))>1e-6)
        { reason="Volume is not aligned to broker volume step"; return(false); }

      if(m_require_flat_account)
        {
         if(PositionsTotal()>0)
           { reason="Account is not flat; one-position-at-a-time policy blocks entry"; return(false); }
         if(OrdersTotal()>0)
           { reason="Pending orders exist; account-wide entry gate blocks new exposure"; return(false); }
        }

      double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double used_margin=AccountInfoDouble(ACCOUNT_MARGIN);
      if(equity<=0.0 || free_margin<0.0 || used_margin<0.0)
        { reason="Account equity or margin data invalid"; return(false); }

      double projected_loss=0.0;
      if(!OrderCalcProfit(order_type,symbol,volume,entry_price,stop_loss,projected_loss))
        { reason="OrderCalcProfit failed; cannot verify stop-loss risk"; return(false); }
      projected_loss=MathAbs(projected_loss);
      if(projected_loss<=0.0)
        { reason="Calculated stop-loss risk is zero or invalid"; return(false); }
      double risk_pct=(projected_loss/equity)*100.0;
      if(risk_pct>m_max_trade_risk_pct+1e-8)
        {
         reason=StringFormat("Projected stop-loss risk %.3f%% exceeds configured %.3f%%",
                             risk_pct,m_max_trade_risk_pct);
         return(false);
        }

      double additional_margin=0.0;
      if(!OrderCalcMargin(order_type,symbol,volume,entry_price,additional_margin) ||
         additional_margin<0.0)
        { reason="OrderCalcMargin failed; cannot verify projected margin"; return(false); }
      if(additional_margin>free_margin)
        { reason="Insufficient free margin for proposed volume"; return(false); }
      double projected_usage=((used_margin+additional_margin)/equity)*100.0;
      if(projected_usage>=m_max_margin_usage_pct)
        {
         reason=StringFormat("Projected margin usage %.2f%% reaches/exceeds %.2f%% ceiling",
                             projected_usage,m_max_margin_usage_pct);
         return(false);
        }

      reason="Portfolio gate passed; existing entry and execution checks still required";
      return(true);
     }

   double            MaxTradeRiskPercent(void) const { return(m_max_trade_risk_pct); }
   double            MaxMarginUsagePercent(void) const { return(m_max_margin_usage_pct); }
   bool              RequiresFlatAccount(void) const { return(m_require_flat_account); }
  };

#endif // AUTOPSYX_PORTFOLIO_RISK_GATE_MQH
