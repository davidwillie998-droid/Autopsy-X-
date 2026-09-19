//+------------------------------------------------------------------+
//|                                    AutopsyMacroFeeder.mq5         |
//|  AUTOPSY X — closes the macro/yields data gap documented in       |
//|  mt5/README.md by polling this repo's Node bridge (server.js's    |
//|  new GET /macro endpoint, which itself pulls Alpha Vantage) and   |
//|  writing the result into the GlobalVariables AutopsyMacroEngine   |
//|  reads.                                                            |
//|                                                                     |
//|  Run this ALONGSIDE your real trading EA on the same account/     |
//|  terminal, once. It does nothing but poll and set GlobalVariables |
//|  — it never touches a position.                                   |
//|                                                                     |
//|  REQUIRED ONE-TIME SETUP: MT5 blocks all outbound WebRequest calls|
//|  by default. In the terminal: Tools -> Options -> Expert Advisors |
//|  -> "Allow WebRequest for listed URL" -> add your bridge's URL    |
//|  (e.g. https://autopsy-x-bridge.onrender.com or                   |
//|  http://127.0.0.1:8787 for a locally-run bridge). Without this,   |
//|  every request fails with error 4060 — this script prints exactly|
//|  that if it happens, so it's easy to diagnose.                    |
//|                                                                     |
//|  Deliberately absent: Fed-expectations and breadth GlobalVariables|
//|  — the bridge's /macro endpoint doesn't send them (Alpha Vantage  |
//|  has no genuine source for either), so this feeder never writes   |
//|  Ax_FedExpectations_Score or Ax_Breadth_Score. The macro/regime    |
//|  engines already treat an unset GlobalVariable as "unavailable"   |
//|  and degrade gracefully rather than guessing.                     |
//+------------------------------------------------------------------+
#property copyright "AUTOPSY X"
#property strict
#property version   "1.00"

input string BridgeUrl    = "http://127.0.0.1:8787"; // no trailing slash
input string BridgeKey    = "";                       // must match the bridge's BRIDGE_KEY
input int    PollMinutes  = 360;                       // matches the bridge's 6h Alpha Vantage cache — polling faster just re-reads the same cache
input int    RequestTimeoutMs = 8000;

datetime g_lastSuccessAt = 0;
string   g_lastStatus    = "not polled yet";

int OnInit()
  {
   if(StringLen(BridgeKey) == 0)
      Print("AutopsyMacroFeeder: WARNING — BridgeKey is empty. This will only work if the bridge has BRIDGE_KEY unset too (dev mode).");

   EventSetTimer(MathMax(60, PollMinutes * 60));
   PollMacro(); // don't wait a full interval for the first read
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   PollMacro();
  }

void OnTick()
  {
   Comment("AutopsyMacroFeeder\nLast success: " + (g_lastSuccessAt > 0 ? TimeToString(g_lastSuccessAt, TIME_DATE | TIME_MINUTES) : "never") +
           "\nLast status: " + g_lastStatus);
  }

//--- Splits `text` on `\n`, then each line on the first `=`, and calls
//    GlobalVariableSet(key, value) for every line that parses cleanly.
//    Lines that don't parse (e.g. a JSON error body from the bridge) are
//    silently skipped — existing GlobalVariables are left exactly as they
//    were, so a bridge outage degrades via the macro engine's own staleness
//    check instead of wiping out the last known-good values immediately.
int ApplyKvPayload(string text)
  {
   StringReplace(text, "\r", "");
   ushort lineSep = StringGetCharacter("\n", 0);
   ushort kvSep   = StringGetCharacter("=", 0);

   string lines[];
   int lineCount = StringSplit(text, lineSep, lines);

   int applied = 0;
   for(int i = 0; i < lineCount; i++)
     {
      string line = lines[i];
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) == 0)
         continue;

      string kv[];
      int n = StringSplit(line, kvSep, kv);
      if(n < 2)
         continue;

      string key = kv[0];
      StringTrimLeft(key); StringTrimRight(key);
      string valueStr = kv[1];
      StringTrimLeft(valueStr); StringTrimRight(valueStr);
      if(StringLen(key) == 0 || StringLen(valueStr) == 0)
         continue;

      double value = StringToDouble(valueStr);
      GlobalVariableSet(key, value);
      applied++;
     }
   return applied;
  }

void PollMacro()
  {
   string url = BridgeUrl + "/macro?format=kv";
   string headers = "x-bridge-key: " + BridgeKey + "\r\n";
   char   postData[];
   char   result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("GET", url, headers, RequestTimeoutMs, postData, result, resultHeaders);

   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4060)
        {
         g_lastStatus = "BLOCKED (4060) — add " + BridgeUrl + " under Tools > Options > Expert Advisors > Allow WebRequest for listed URL";
         Print("AutopsyMacroFeeder: ", g_lastStatus);
        }
      else
        {
         g_lastStatus = "WebRequest failed, error " + IntegerToString(err);
         Print("AutopsyMacroFeeder: ", g_lastStatus, " (url=", url, ")");
        }
      return;
     }

   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   if(status != 200)
     {
      g_lastStatus = "HTTP " + IntegerToString(status) + ": " + body;
      Print("AutopsyMacroFeeder: bridge returned ", g_lastStatus);
      return;
     }

   int applied = ApplyKvPayload(body);
   if(applied == 0)
     {
      g_lastStatus = "HTTP 200 but nothing parsed — check the bridge's /macro?format=kv output directly. Body: " + body;
      Print("AutopsyMacroFeeder: ", g_lastStatus);
      return;
     }

   g_lastSuccessAt = TimeCurrent();
   g_lastStatus = "OK — wrote " + IntegerToString(applied) + " global variable(s)";
   Print("AutopsyMacroFeeder: ", g_lastStatus);
  }
