//+------------------------------------------------------------------+
//|                                      ClaudeMarketAnalyzer.mq5     |
//|                        AMOS Level 50 - EA Factory (Layer 06)      |
//|                                                                  |
//|  Rework of GPT_Hybrid_Analyzer_8: the analysis agent is Claude    |
//|  (Anthropic Messages API) instead of GPT, and Discord delivery   |
//|  is removed. Results are shown in an on-chart panel, written to  |
//|  MQL5/Files/ClaudeAnalysis_<symbol>.txt and printed to Experts.  |
//|                                                                  |
//|  Setup:                                                          |
//|   1. Tools > Options > Expert Advisors > "Allow WebRequest for   |
//|      listed URL" and add:  https://api.anthropic.com             |
//|   2. Put your Anthropic API key into InpAnthropicKey.            |
//|                                                                  |
//|  Notes:                                                          |
//|   - WebRequest is synchronous: the chart blocks for the duration |
//|     of the call (usually a few seconds; timeout 60s).            |
//|   - The output is market commentary, NOT a validated trading     |
//|     signal. Per docs/inbox/mathematical_framework.md, an LLM     |
//|     opinion adds no measured edge until Phase C proves it.       |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "1.00"
#property strict

input group "Anthropic API"
input string InpAnthropicKey     = "";                  // API key (sk-ant-...)
input string InpModel            = "claude-opus-4-8";   // model ID
input int    InpMaxTokens        = 1500;                // max_tokens for the reply
input group "Analysis"
input int    InpAnalysisInterval = 60;                  // auto-analysis interval, minutes (0 = manual only)
input int    InpCandleCount      = 50;                  // candles per timeframe in the prompt
input bool   InpAnswerJapanese   = true;                // reply in Japanese
input group "Display"
input bool   InpSaveToFile       = true;                // save result to MQL5/Files
input int    InpPanelWidth       = 62;                  // panel wrap width (chars)

datetime g_lastAnalysis = 0;
bool     g_busy         = false;
int      g_hMA20 = INVALID_HANDLE, g_hMA50 = INVALID_HANDLE, g_hMA200 = INVALID_HANDLE;
int      g_hRSI = INVALID_HANDLE, g_hATR = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_hMA20  = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_SMA, PRICE_CLOSE);
   g_hMA50  = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_SMA, PRICE_CLOSE);
   g_hMA200 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_SMA, PRICE_CLOSE);
   g_hRSI   = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   g_hATR   = iATR(_Symbol, PERIOD_H1, 14);
   CreateButton();
   Print("Claude Market Analyzer initialized for ", _Symbol,
         " (model ", InpModel, "). Allow https://api.anthropic.com in WebRequest settings.");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectDelete(0, "ClaudeBtn");
   ObjectsDeleteAll(0, "ClaudePanel_");
   if(g_hMA20 != INVALID_HANDLE) IndicatorRelease(g_hMA20);
   if(g_hMA50 != INVALID_HANDLE) IndicatorRelease(g_hMA50);
   if(g_hMA200 != INVALID_HANDLE) IndicatorRelease(g_hMA200);
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
  }

//+------------------------------------------------------------------+
void CreateButton()
  {
   string n = "ClaudeBtn";
   ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, 150);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, 36);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 11);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, clrDarkOrange);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, clrSaddleBrown);
   ObjectSetString(0, n, OBJPROP_TEXT, "Claude Analysis");
   ObjectSetString(0, n, OBJPROP_FONT, "Arial");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(InpAnalysisInterval > 0 &&
      TimeCurrent() - g_lastAnalysis >= (datetime)(InpAnalysisInterval * 60))
     {
      g_lastAnalysis = TimeCurrent();
      RunAnalysis();
     }
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == "ClaudeBtn")
     {
      ObjectSetInteger(0, "ClaudeBtn", OBJPROP_STATE, false);
      RunAnalysis();
     }
  }

//+------------------------------------------------------------------+
//| Market data collection (same content as the GPT version)         |
//+------------------------------------------------------------------+
string CollectMarketData()
  {
   string d = "";
   d += "Symbol: " + _Symbol + "\n";
   d += "Current Price: " + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits) + "\n";
   d += "Spread: " + IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " points\n";
   d += "Time: " + TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + "\n\n";
   d += TimeframeData(PERIOD_H1, "1H");
   d += TimeframeData(PERIOD_H4, "4H");
   d += TimeframeData(PERIOD_D1, "Daily");
   d += Indicators();
   return(d);
  }

string TimeframeData(ENUM_TIMEFRAMES tf, string name)
  {
   string r = name + " Data:\n";
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, tf, 0, InpCandleCount, rates);
   if(copied > 0)
     {
      r += "Recent candles (O,H,L,C):\n";
      int nShow = (int)MathMin(5, copied);
      for(int i = 0; i < nShow; i++)
         r += StringFormat("  [%d] %s, %s, %s, %s\n", i,
              DoubleToString(rates[i].open, _Digits), DoubleToString(rates[i].high, _Digits),
              DoubleToString(rates[i].low, _Digits), DoubleToString(rates[i].close, _Digits));
      double hi = rates[0].high, lo = rates[0].low;
      for(int i = 1; i < copied; i++)
        {
         if(rates[i].high > hi) hi = rates[i].high;
         if(rates[i].low < lo)  lo = rates[i].low;
        }
      r += "  Highest: " + DoubleToString(hi, _Digits) + "\n";
      r += "  Lowest: " + DoubleToString(lo, _Digits) + "\n";
     }
   return(r + "\n");
  }

string Indicators()
  {
   string r = "Technical Indicators:\n";
   double b[1];
   if(g_hMA20 != INVALID_HANDLE && CopyBuffer(g_hMA20, 0, 0, 1, b) > 0)
      r += "  SMA20 (H1): " + DoubleToString(b[0], _Digits) + "\n";
   if(g_hMA50 != INVALID_HANDLE && CopyBuffer(g_hMA50, 0, 0, 1, b) > 0)
      r += "  SMA50 (H1): " + DoubleToString(b[0], _Digits) + "\n";
   if(g_hMA200 != INVALID_HANDLE && CopyBuffer(g_hMA200, 0, 0, 1, b) > 0)
      r += "  SMA200 (H1): " + DoubleToString(b[0], _Digits) + "\n";
   if(g_hRSI != INVALID_HANDLE && CopyBuffer(g_hRSI, 0, 0, 1, b) > 0)
      r += "  RSI(14): " + DoubleToString(b[0], 2) + "\n";
   if(g_hATR != INVALID_HANDLE && CopyBuffer(g_hATR, 0, 0, 1, b) > 0)
      r += "  ATR(14): " + DoubleToString(b[0], _Digits) + "\n";
   return(r);
  }

//+------------------------------------------------------------------+
//| Run one analysis round                                           |
//+------------------------------------------------------------------+
void RunAnalysis()
  {
   if(g_busy) { Print("Claude analysis already in progress..."); return; }
   if(StringLen(InpAnthropicKey) < 10)
     {
      ShowPanel("ERROR: set InpAnthropicKey (Anthropic API key).");
      return;
     }
   g_busy = true;
   ShowPanel("Analyzing " + _Symbol + " with " + InpModel + " ...");
   string analysis = CallClaude(CollectMarketData());
   if(StringLen(analysis) > 0)
     {
      ShowPanel(analysis);
      Print("=== Claude Analysis (", _Symbol, ") ===\n", analysis);
      if(InpSaveToFile) SaveToFile(analysis);
     }
   else
      ShowPanel("Failed to get Claude analysis - see Experts log.");
   g_busy = false;
  }

//+------------------------------------------------------------------+
//| Anthropic Messages API call                                      |
//| POST https://api.anthropic.com/v1/messages                       |
//| headers: x-api-key, anthropic-version: 2023-06-01                |
//+------------------------------------------------------------------+
string CallClaude(string marketData)
  {
   string url = "https://api.anthropic.com/v1/messages";

   string lang = InpAnswerJapanese ? "日本語で回答してください。" : "Answer in English.";
   string systemPrompt =
      "あなたはFX市場の専門アナリストです。提供されたマーケットデータを分析し、以下の形式で回答してください。" + lang + "\\n"
      "1. 現在のトレンド判定(上昇/下降/レンジ)\\n"
      "2. 主要なサポート・レジスタンス水準\\n"
      "3. テクニカル指標の客観的な解釈\\n"
      "4. 市場環境の概観\\n"
      "5. 注目すべきポイント\\n\\n"
      "これは情報提供のみを目的とし、投資助言ではありません。断定的な売買推奨はしないでください。";

   string jsonRequest = "{";
   jsonRequest += "\"model\": \"" + InpModel + "\",";
   jsonRequest += "\"max_tokens\": " + IntegerToString(InpMaxTokens) + ",";
   jsonRequest += "\"system\": \"" + systemPrompt + "\",";
   jsonRequest += "\"messages\": [";
   jsonRequest += "{\"role\": \"user\", \"content\": \"" + EscapeJSON(marketData) + "\"}";
   jsonRequest += "]}";

   string headers = "Content-Type: application/json\r\n"
                    "x-api-key: " + InpAnthropicKey + "\r\n"
                    "anthropic-version: 2023-06-01\r\n";

   char post[]; char result[]; string resultHeaders;
   int postSize = StringToCharArray(jsonRequest, post, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(post, postSize - 1);   // drop the null terminator

   ResetLastError();
   int status = WebRequest("POST", url, headers, 60000, post, result, resultHeaders);
   if(status == -1)
     {
      Print("WebRequest failed. Error: ", GetLastError(),
            ". Add 'https://api.anthropic.com' to Tools > Options > Expert Advisors allowed URLs.");
      return("");
     }
   string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(status != 200)
     {
      Print("Anthropic API HTTP ", status, ": ", StringSubstr(response, 0, 500));
      return("");
     }
   if(StringFind(response, "\"type\":\"error\"") >= 0 ||
      StringFind(response, "\"type\": \"error\"") >= 0)
     {
      Print("Anthropic API error: ", StringSubstr(response, 0, 500));
      return("");
     }
   // refusal stop reason (safety classifiers): no usable content
   if(StringFind(response, "\"stop_reason\":\"refusal\"") >= 0)
     {
      Print("Claude declined the request (stop_reason=refusal).");
      return("");
     }
   return(ExtractText(response));
  }

//+------------------------------------------------------------------+
//| Extract content[0].text from the Messages API response:          |
//| {"content":[{"type":"text","text":"..."}], ...}                  |
//+------------------------------------------------------------------+
string ExtractText(string response)
  {
   int cpos = StringFind(response, "\"content\"");
   if(cpos < 0) return("");
   // first "text":" AFTER the content array opens (skip "type":"text")
   int tpos = StringFind(response, "\"text\":", cpos);
   if(tpos < 0) { tpos = StringFind(response, "\"text\" :", cpos); if(tpos < 0) return(""); }
   int start = StringFind(response, "\"", tpos + 7);
   if(start < 0) return("");
   start++;

   int end = start;
   bool esc = false;
   int len = StringLen(response);
   while(end < len)
     {
      ushort ch = StringGetCharacter(response, end);
      if(esc) { esc = false; end++; continue; }
      if(ch == '\\') { esc = true; end++; continue; }
      if(ch == '"') break;
      end++;
     }
   string text = StringSubstr(response, start, end - start);
   StringReplace(text, "\\n", "\n");
   StringReplace(text, "\\\"", "\"");
   StringReplace(text, "\\\\", "\\");
   StringReplace(text, "\\t", "  ");
   return(text);
  }

//+------------------------------------------------------------------+
//| On-chart panel (replaces Discord delivery)                       |
//+------------------------------------------------------------------+
void ShowPanel(string text)
  {
   ObjectsDeleteAll(0, "ClaudePanel_");
   string header = "=== Claude Market Analysis: " + _Symbol + "  " +
                   TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + " ===";
   string lines[];
   int nl = WrapText(header + "\n" + text, InpPanelWidth, lines);
   int y = 80;
   int nShow = (int)MathMin(nl, 40);        // cap panel height
   for(int i = 0; i < nShow; i++)
     {
      string n = "ClaudePanel_" + IntegerToString(i);
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, n, OBJPROP_COLOR, (i == 0) ? clrGold : clrWhite);
      ObjectSetString(0, n, OBJPROP_FONT, "MS Gothic");
      ObjectSetString(0, n, OBJPROP_TEXT, lines[i]);
      y += 14;
     }
   ChartRedraw();
  }

// split text into wrapped lines; returns line count
int WrapText(string text, int width, string &lines[])
  {
   string rows[];
   int nr = StringSplit(text, '\n', rows);
   ArrayResize(lines, 0);
   for(int i = 0; i < nr; i++)
     {
      string row = rows[i];
      if(StringLen(row) == 0) { Push(lines, " "); continue; }
      while(StringLen(row) > width)
        {
         Push(lines, StringSubstr(row, 0, width));
         row = StringSubstr(row, width);
        }
      Push(lines, row);
     }
   return(ArraySize(lines));
  }

void Push(string &arr[], string v)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = v;
  }

//+------------------------------------------------------------------+
void SaveToFile(string analysis)
  {
   string fname = "ClaudeAnalysis_" + _Symbol + ".txt";
   int h = FileOpen(fname, FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI, 0, CP_UTF8);
   if(h == INVALID_HANDLE) { Print("FileOpen failed: ", GetLastError()); return; }
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "\n===== " + TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) +
                      "  " + _Symbol + " (" + InpModel + ") =====\n" + analysis + "\n");
   FileClose(h);
  }

//+------------------------------------------------------------------+
string EscapeJSON(string text)
  {
   string r = text;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   StringReplace(r, "\r", "\\r");
   StringReplace(r, "\t", "\\t");
   return(r);
  }
//+------------------------------------------------------------------+
