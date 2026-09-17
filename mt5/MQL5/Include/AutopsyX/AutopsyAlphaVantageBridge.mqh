//+------------------------------------------------------------------+
//|                               AutopsyAlphaVantageBridge.mqh      |
//|  AUTOPSY X — Alpha Vantage macro/breadth data via the bridge     |
//|  server's GET /macro/snapshot.                                   |
//|                                                                    |
//|  This does NOT call Alpha Vantage directly — MT5's WebRequest()   |
//|  is synchronous and has no server-side caching of its own, and    |
//|  Alpha Vantage's free tier is 25 requests/day, so hitting it      |
//|  straight from an EA would burn the quota in minutes. Instead     |
//|  this calls the same Node bridge server.js already runs           |
//|  (server/alphaVantage.js), which fetches from Alpha Vantage once  |
//|  and caches for hours — every EA on every terminal polling this   |
//|  bridge shares that one cache.                                     |
//|                                                                    |
//|  Setup required in MT5: Tools -> Options -> Expert Advisors ->    |
//|  "Allow WebRequest for listed URL", and add your bridge server's  |
//|  URL there. Without that, WebRequest() always fails with          |
//|  error 4060, and this prints exactly that guidance when it does.  |
//+------------------------------------------------------------------+
#property strict
#include "AutopsyTypes.mqh"

struct AxAlphaVantageSnapshot
  {
   bool     ok;             // the HTTP call itself succeeded and returned parseable JSON
   datetime fetched_at;

   bool     has_us10y;
   double   us10y_level;
   double   us10y_momentum_bps;

   bool     has_us2y_momentum;
   double   us2y_momentum_bps;

   bool     has_fed_funds_momentum;
   double   fed_funds_momentum_bps;

   bool     has_cpi;
   double   cpi_yoy_pct;

   bool     has_breadth;
   double   breadth_advancers;
   double   breadth_decliners;
   double   breadth_sample_size; // out of ~20 — Alpha Vantage's top-actives list, not the whole market

   bool     has_news;
   double   news_sentiment_score; // roughly -1 (bearish) .. +1 (bullish)

   //+------------------------------------------------------------+
   //| Converts this into the provider-agnostic shape               |
   //| AutopsyMacroEngine.mqh actually consumes.                    |
   //+------------------------------------------------------------+
   AxExternalMacroInputs ToMacroInputs() const
     {
      AxExternalMacroInputs ext;
      ext.Clear();
      ext.has_us10y               = has_us10y;
      ext.us10y_level              = us10y_level;
      ext.us10y_momentum_bps       = us10y_momentum_bps;
      ext.has_us2y_momentum        = has_us2y_momentum;
      ext.us2y_momentum_bps        = us2y_momentum_bps;
      ext.has_fed_funds_momentum   = has_fed_funds_momentum;
      ext.fed_funds_momentum_bps   = fed_funds_momentum_bps;
      ext.has_cpi                  = has_cpi;
      ext.cpi_yoy_pct              = cpi_yoy_pct;
      ext.as_of                    = fetched_at;
      return ext;
     }
  };

class CAxAlphaVantageBridge
  {
private:
   string m_bridge_url; // e.g. "http://127.0.0.1:8787" or your Render URL — no trailing slash
   string m_bridge_key;

public:
   void Init(const string bridge_url, const string bridge_key)
     {
      m_bridge_url = bridge_url;
      // Strip a trailing slash so "url + /macro/snapshot" never doubles up.
      if(StringLen(m_bridge_url) > 0 && StringGetCharacter(m_bridge_url, StringLen(m_bridge_url) - 1) == '/')
         m_bridge_url = StringSubstr(m_bridge_url, 0, StringLen(m_bridge_url) - 1);
      m_bridge_key = bridge_key;
     }

   bool IsConfigured() const { return StringLen(m_bridge_url) > 0; }

   //+---------------------------------------------------------------+
   //| Blocking network call — WebRequest() always is. Call this      |
   //| periodically (once every H1-D1 bar is plenty; the underlying   |
   //| data itself only updates a few times a day), never every tick. |
   //+---------------------------------------------------------------+
   bool Fetch(AxAlphaVantageSnapshot &out)
     {
      out.ok = false;
      out.has_us10y = false; out.has_us2y_momentum = false; out.has_fed_funds_momentum = false;
      out.has_cpi = false; out.has_breadth = false; out.has_news = false;
      out.fetched_at = TimeCurrent();

      if(!IsConfigured())
        {
         Print("AutopsyX AlphaVantage bridge: no bridge URL configured — skipping.");
         return false;
        }

      char request_body[];
      char response_body[];
      string response_headers;
      const string headers = "x-bridge-key: " + m_bridge_key + "\r\n";
      const string url = m_bridge_url + "/macro/snapshot";

      ResetLastError();
      const int status = WebRequest("GET", url, headers, 5000, request_body, response_body, response_headers);
      if(status == -1)
        {
         const int err = GetLastError();
         if(err == 4060)
            Print("AutopsyX AlphaVantage bridge: WebRequest blocked (error 4060). Add '", m_bridge_url,
                  "' under Tools > Options > Expert Advisors > 'Allow WebRequest for listed URL', then retry.");
         else
            Print("AutopsyX AlphaVantage bridge: WebRequest failed, error ", err);
         return false;
        }
      if(status != 200)
        {
         Print("AutopsyX AlphaVantage bridge: HTTP ", status, " from ", url,
               " — check the bridge server is running and BRIDGE_KEY/ALPHA_VANTAGE_API_KEY are set.");
         return false;
        }

      const string json = CharArrayToString(response_body, 0, WHOLE_ARRAY, CP_UTF8);
      if(StringLen(json) == 0)
        {
         Print("AutopsyX AlphaVantage bridge: empty response body.");
         return false;
        }

      double us10y_level, us10y_momentum;
      const bool has_us10y_level    = AxJsonExtractNumber(json, "us10y_level", us10y_level);
      const bool has_us10y_momentum = AxJsonExtractNumber(json, "us10y_momentum_bps_10d", us10y_momentum);
      out.has_us10y = has_us10y_level && has_us10y_momentum;
      if(has_us10y_level)    out.us10y_level = us10y_level;
      if(has_us10y_momentum) out.us10y_momentum_bps = us10y_momentum;

      out.has_us2y_momentum      = AxJsonExtractNumber(json, "us2y_momentum_bps_10d", out.us2y_momentum_bps);
      out.has_fed_funds_momentum = AxJsonExtractNumber(json, "fed_funds_momentum_bps_30d", out.fed_funds_momentum_bps);
      out.has_cpi                = AxJsonExtractNumber(json, "cpi_yoy_pct", out.cpi_yoy_pct);

      double adv, dec;
      if(AxJsonExtractNumber(json, "breadth_advancers", adv) && AxJsonExtractNumber(json, "breadth_decliners", dec))
        {
         out.has_breadth = true;
         out.breadth_advancers = adv;
         out.breadth_decliners = dec;
         double sample;
         out.breadth_sample_size = AxJsonExtractNumber(json, "breadth_sample_size", sample) ? sample : (adv + dec);
        }

      out.has_news = AxJsonExtractNumber(json, "news_sentiment_score", out.news_sentiment_score);

      out.ok = true;
      return true;
     }
  };
