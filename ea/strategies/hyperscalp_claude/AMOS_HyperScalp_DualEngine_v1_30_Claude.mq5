//+------------------------------------------------------------------+
//| AMOS_HyperScalp_DualEngine_v1_30_Claude.mq5                      |
//|                                                                  |
//| v1.30 (Claude Gate カスタム):                                    |
//|  ベース: ユーザー提供 v1.21 FIXED（全ロジック保持）              |
//|  [A] Claudeエージェント統合（Anthropic Messages API 直叩き）     |
//|      クラスター発射の直前に市況＋セットアップ要約を渡し、        |
//|      {direction, confidence, reason} のJSON判定を受け取る        |
//|  [B] 3モード: OFF / ADVISORY(記録のみ・発射は従来通り) /         |
//|      GATE(方向一致かつ信頼度>=閾値のときのみ発射)                |
//|  [C] 判定キャッシュ+クールダウン（毎ティックAPIを叩かない）      |
//|  [D] ストラテジーテスターでは WebRequest 不可のため自動OFF       |
//|  [E] APIキーは input のみ。コードへの埋め込み禁止                |
//|                                                                  |
//|  セットアップ:                                                   |
//|   1. ツール > オプション > エキスパートアドバイザ で             |
//|      https://api.anthropic.com を WebRequest 許可URLに追加       |
//|   2. InpAnthropicKey に APIキーを設定                            |
//|                                                                  |
//|  注意: WebRequest は同期呼び出し（数秒ブロック）。発射判定時     |
//|  のみ呼ぶ設計なので通常運転への影響は限定的。LLMの判定は         |
//|  検証済みのエッジではない（docs/inbox/mathematical_framework.md）|
//|  — Phase C で優位性が実証されるまで GATE は補助輪扱いのこと。    |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "1.30"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// ENUMS
//==================================================================
enum ENUM_AMOS_STATE
{
   STATE_IDLE             = 0,
   STATE_RANGE_ACTIVE     = 1,
   STATE_SWEEP_CONFIRMED  = 2,
   STATE_CRT_ACTIVE       = 3,
   STATE_TREND_RIDE       = 4,
   STATE_KILL             = 9
};

enum ENUM_DIRECTION
{
   DIR_NONE = 0,
   DIR_BUY  = 1,
   DIR_SELL = -1
};

enum ENUM_BIAS_MODE
{
   BIAS_AUTO_ICT      = 0,
   BIAS_MANUAL_BUY    = 1,
   BIAS_MANUAL_SELL   = 2,
   BIAS_AUTO_HTF_EMA  = 3
};

// [A] Claude ゲートの動作モード
enum ENUM_CLAUDE_MODE
{
   CLAUDE_OFF      = 0,  // 呼ばない（v1.21と同一動作）
   CLAUDE_ADVISORY = 1,  // 判定を記録・表示するだけ。発射は従来条件のみ
   CLAUDE_GATE     = 2   // 方向一致 かつ confidence>=閾値 のときのみ発射
};

//==================================================================
// INPUTS
//==================================================================
input group "--- 【Core】 ---"
input long              InpMagic             = 20260601;
input ENUM_TIMEFRAMES   InpEntryTF           = PERIOD_M1;
input ENUM_TIMEFRAMES   InpBiasTF            = PERIOD_M15;
input ENUM_BIAS_MODE    InpBiasMode          = BIAS_AUTO_ICT;
input bool              InpEnableTrading     = false;  // 安全デフォルトOFF
input bool              InpOneDirectionOnly  = true;
input bool              InpShowPanel         = true;

input group "--- 【Risk / Lots】 ---"
input bool              InpUseFixedLot       = false;
input double            InpFixedLot          = 0.01;
input double            InpRiskPercent       = 0.50;
input double            RiskBaseEquity       = 10000.0; // 複利基準証拠金
input double            InpMaxLot            = 50.00;
input int               InpMaxPositions      = 12;
input double            InpDailyDDStopPct    = 50.0;
input double            InpEquityKillPct     = 80.0;

input group "--- 【Spread / Execution Guard】 ---"
input double            InpMaxSpreadPoints   = 150;
input int               InpSlippagePoints    = 30;

input group "--- 【Range Compression Engine】 ---"
input bool              InpUseRangeEngine    = true;
input int               InpBBPeriod          = 20;
input double            InpBBDev             = 2.0;
input int               InpATRPeriod         = 14;
input int               InpADXPeriod         = 14;
input int               InpRangeLookback     = 150;
input double            InpRangeScoreMin     = 0.58;
input double            InpBBSqueezePct      = 15.0;
input double            InpATRLowPct         = 25.0;
input double            InpADXMax            = 20.0;
input int               InpADXLookback       = 5;

input group "--- 【クラスター爆撃設定】 ---"
input int               PyramidStepPoints    = 150;
input int               BurstTargetCount     = 12;
input double            GivebackPercent      = 40.0;
input double            SlBufferDollars      = 2.0;    // SL距離（ドル単位）

input group "--- 【ICT Direction】 ---"
input int               InpHTFFastEMA        = 20;
input int               InpHTFSlowEMA        = 50;
input int               InpSwingLookback     = 20;
input bool              InpUsePDH_PDL_Sweep  = true;
input bool              InpUseMSS            = true;

input group "--- 【Claude Agent Gate】 ---"                     // [A]
input ENUM_CLAUDE_MODE  InpClaudeMode        = CLAUDE_ADVISORY; // 動作モード
input string            InpAnthropicKey      = "";              // APIキー (sk-ant-...)
input string            InpClaudeModel       = "claude-opus-4-8"; // モデルID
input int               InpClaudeMaxTokens   = 600;             // 応答 max_tokens
input int               InpClaudeCooldownSec = 300;             // 判定キャッシュ有効秒
input int               InpClaudeMinConf     = 60;              // GATE時の最低confidence
input bool              InpClaudeFailOpen    = true;            // API失敗時に発射を許可するか
input bool              InpClaudeJapanese    = true;            // reason を日本語で

//==================================================================
// GLOBALS
//==================================================================
int hBB      = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;
int hADX     = INVALID_HANDLE;
int hFastEMA = INVALID_HANDLE;
int hSlowEMA = INVALID_HANDLE;

ENUM_AMOS_STATE g_state = STATE_IDLE;
ENUM_DIRECTION  g_bias  = DIR_NONE;

double g_range_high  = 0.0;
double g_range_low   = 0.0;
double g_range_mid   = 0.0;
bool   g_swept_high  = false;
bool   g_swept_low   = false;

double g_day_start_equity = 0.0;
int    g_day = -1;

double g_maxProfitBuy  = 0.0;
double g_maxProfitSell = 0.0;

bool     g_BlockNewOrder = false;
string   g_lastLog       = "システム起動";
datetime g_last_bar      = 0;

// [A][C] Claude 判定キャッシュ
ENUM_DIRECTION g_cl_dir    = DIR_NONE;
int            g_cl_conf   = 0;
string         g_cl_reason = "(未取得)";
datetime       g_cl_time   = 0;
bool           g_cl_valid  = false;
bool           g_cl_apiOK  = true;   // 直近API呼び出しの成否

struct BasketStats {
   int    count;
   double lots;
   double profit;
   double avgPrice;
};

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   hBB      = iBands(_Symbol, InpEntryTF, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   hATR     = iATR  (_Symbol, InpEntryTF, InpATRPeriod);
   hADX     = iADX  (_Symbol, InpEntryTF, InpADXPeriod);
   hFastEMA = iMA   (_Symbol, InpBiasTF,  InpHTFFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA   (_Symbol, InpBiasTF,  InpHTFSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hBB == INVALID_HANDLE || hATR == INVALID_HANDLE || hADX == INVALID_HANDLE ||
      hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE)
   {
      Print("インジケーター初期化失敗");
      return INIT_FAILED;
   }

   g_BlockNewOrder    = false;
   g_maxProfitBuy     = 0.0;
   g_maxProfitSell    = 0.0;
   g_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_last_bar         = 0;

   // [D] テスターでは WebRequest が使えない
   if(ClaudeActive() && MQLInfoInteger(MQL_TESTER))
      Print("[Claude] ストラテジーテスターでは WebRequest 不可のため Claude ゲートは無効化されます");
   if(ClaudeActive() && StringLen(InpAnthropicKey) < 10)
      Print("[Claude] InpAnthropicKey 未設定。API失敗扱い（FailOpen=", InpClaudeFailOpen, "）で動作します");

   Print("AMOS HyperScalp v1.30 Claude - 初期化完了 (ClaudeMode=", EnumToString(InpClaudeMode), ")");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hBB      != INVALID_HANDLE) IndicatorRelease(hBB);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX     != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   Comment("");
}

double GetPipsSize() { return (_Digits == 3 || _Digits == 5) ? 10.0 * _Point : _Point; }
double SpreadPoints() { return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point; }
bool   SpreadOK()     { return SpreadPoints() <= InpMaxSpreadPoints; }

// Filling種別取得（RETURN→IOC→FOK優先順）
ENUM_ORDER_TYPE_FILLING GetFillingType()
{
   int f = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_RETURN) == SYMBOL_FILLING_RETURN) return ORDER_FILLING_RETURN;
   if((f & SYMBOL_FILLING_IOC)    == SYMBOL_FILLING_IOC)    return ORDER_FILLING_IOC;
   return ORDER_FILLING_FOK;
}

void CheckNewDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day != g_day)
   {
      g_day              = dt.day;
      g_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_state == STATE_KILL)
      {
         g_state        = STATE_IDLE;
         g_BlockNewOrder = false;
         Print("[AMOS] STATE_KILL 翌日自動解除");
      }
   }
}

double CalculateDynamicLot()
{
   if(InpUseFixedLot) return InpFixedLot;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0 || RiskBaseEquity <= 0) return InpFixedLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLot);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0) minLot = 0.01;
   if(step   <= 0.0) step   = minLot;

   double calc = (equity / RiskBaseEquity) * InpFixedLot;
   double lot  = MathFloor(calc / step) * step;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

int CountPositionsByType(long direction)
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PositionGetSymbol(i)              == _Symbol  &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetInteger(POSITION_TYPE)  == direction)
         count++;
   }
   return count;
}

int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   return count;
}

int GetActiveOrdersCount()
{
   int count = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
      if(OrderGetTicket(i) > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic)
         count++;
   return count;
}

void CancelAllLimits()
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic)
         trade.OrderDelete(ticket);
   }
}

void CloseAllMine(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         trade.PositionClose(ticket);
   }
   g_maxProfitBuy  = 0.0;
   g_maxProfitSell = 0.0;
   g_lastLog = "【一括決済】" + reason;
   Print("[AMOS] ", g_lastLog);
}

bool DailyGuardOK()
{
   CheckNewDay();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day_start_equity <= 0.0) g_day_start_equity = eq;

   if((g_day_start_equity - eq) / g_day_start_equity * 100.0 >= InpDailyDDStopPct)
   { g_state = STATE_KILL; return false; }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > 0.0 && (bal - eq) / bal * 100.0 >= InpEquityKillPct)
   { g_state = STATE_KILL; return false; }

   return true;
}

//+------------------------------------------------------------------+
//| 12本等間隔指値クラスター配置エンジン（v1.21のまま）              |
//+------------------------------------------------------------------+
void PlaceBurstLimitOrders(bool isBuy, double lot)
{
   ENUM_ORDER_TYPE         orderType = isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   ENUM_ORDER_TYPE_FILLING fill      = GetFillingType();
   int failCount = 0;

   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel <= 0) stopsLevel = 30;
   double freezeDist = stopsLevel * _Point;

   // SL = レンジ境界 ± SlBufferDollars（全弾共通・固定）
   double rangeSL = isBuy
      ? NormalizeDouble(g_range_low  - SlBufferDollars, _Digits)
      : NormalizeDouble(g_range_high + SlBufferDollars, _Digits);

   for(int i = 0; i < BurstTargetCount; i++)
   {
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      MqlTradeRequest request;
      MqlTradeResult  result;
      ZeroMemory(request);
      ZeroMemory(result);

      double startPrice = isBuy ? currentBid : currentAsk;
      double price = isBuy
         ? NormalizeDouble(startPrice - ((i + 1) * PyramidStepPoints * _Point), _Digits)
         : NormalizeDouble(startPrice + ((i + 1) * PyramidStepPoints * _Point), _Digits);

      // ストップレベルガード（price補正のみ。SLはレンジ基準維持）
      if( isBuy && (currentBid - price) < freezeDist)
         price = NormalizeDouble(currentBid - freezeDist, _Digits);
      if(!isBuy && (price - currentAsk) < freezeDist)
         price = NormalizeDouble(currentAsk + freezeDist, _Digits);

      // SL/TP 規約逆転チェック（price補正後）
      if(isBuy  && rangeSL >= price) { failCount++; Sleep(60); continue; }
      if(!isBuy && rangeSL <= price) { failCount++; Sleep(60); continue; }

      request.action       = TRADE_ACTION_PENDING;
      request.symbol       = _Symbol;
      request.magic        = InpMagic;
      request.volume       = lot;
      request.type         = orderType;
      request.price        = price;
      request.sl           = rangeSL;
      request.tp           = isBuy ? g_range_high : g_range_low;
      request.type_filling = fill;
      request.type_time    = ORDER_TIME_GTC;
      request.comment      = isBuy
         ? "GB_BUY_"  + IntegerToString(i + 1)
         : "GB_SELL_" + IntegerToString(i + 1);

      if(trade.OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
            g_lastLog = StringFormat("指値成功[%d本目]: Ticket=%d / price=%.5f / sl=%.5f",
                                     i+1, result.order, price, rangeSL);
         else
         {
            failCount++;
            Print(StringFormat("指値拒否[%d本目]: retcode=%d / price=%.5f", i+1, result.retcode, price));
         }
      }
      else
      {
         failCount++;
         Print(StringFormat("送信失敗[%d本目]: %s", i+1, trade.ResultComment()));
      }

      Sleep(60);
   }

   if(failCount == 0)
      g_lastLog = StringFormat("%s 12本指値クラスター配置完了 SL=%.5f",
                               isBuy ? "【BULLISH】" : "【BEARISH】", rangeSL);
   else
      g_lastLog = StringFormat("クラスター配置完了（成功:%d / 失敗:%d）",
                               BurstTargetCount - failCount, failCount);
   Print("[AMOS] ", g_lastLog);
}

void GetBasketStats(long direction, BasketStats &stats)
{
   stats.count = 0; stats.lots = 0.0; stats.profit = 0.0; stats.avgPrice = 0.0;
   double weightedPrice = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i)              == _Symbol  &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetInteger(POSITION_TYPE)  == direction)
      {
         double vol    = PositionGetDouble(POSITION_VOLUME);
         stats.count++;
         stats.lots   += vol;
         stats.profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         weightedPrice += PositionGetDouble(POSITION_PRICE_OPEN) * vol;
      }
   }
   if(stats.lots > 0.0) stats.avgPrice = weightedPrice / stats.lots;
}

void ManageBasketSettlement(long direction, const BasketStats &stats)
{
   if(stats.count == 0) return;

   double &maxProfit = (direction == POSITION_TYPE_BUY) ? g_maxProfitBuy : g_maxProfitSell;
   maxProfit = MathMax(maxProfit, stats.profit);

   if(maxProfit >= 10.0)
   {
      double closeLine = maxProfit * (1.0 - (GivebackPercent / 100.0));
      if(stats.profit <= closeLine)
      {
         CloseAllMine("Giveback一括全利確");
         CancelAllLimits();
      }
   }
}

double RangeEntryScore()
{
   double upper[], lower[], atrs[], adx[];
   ArraySetAsSeries(upper, true); ArraySetAsSeries(lower, true);
   ArraySetAsSeries(atrs,  true); ArraySetAsSeries(adx,   true);

   if(CopyBuffer(hBB,  1, 0, InpRangeLookback+1, upper) < InpRangeLookback) return 0.0;
   if(CopyBuffer(hBB,  2, 0, InpRangeLookback+1, lower) < InpRangeLookback) return 0.0;
   if(CopyBuffer(hATR, 0, 0, InpRangeLookback+1, atrs)  < InpRangeLookback) return 0.0;
   if(CopyBuffer(hADX, 0, 0, InpADXLookback,      adx)  < InpADXLookback)   return 0.0;

   double widths[]; ArrayResize(widths, InpRangeLookback);
   for(int i = 0; i < InpRangeLookback; i++) widths[i] = upper[i+1] - lower[i+1];

   double curWidth = upper[0] - lower[0];
   int belowBB = 0;
   for(int i = 0; i < InpRangeLookback; i++) if(widths[i] < curWidth) belowBB++;
   double bbPct   = (double)belowBB / InpRangeLookback * 100.0;
   double scoreBB = (bbPct <= InpBBSqueezePct) ? 1.0
      : MathMax(0.0, 1.0 - (bbPct - InpBBSqueezePct) / (100.0 - InpBBSqueezePct));

   int belowADX = 0;
   for(int k = 0; k < InpADXLookback; k++) if(adx[k] < InpADXMax) belowADX++;
   double scoreADX = (double)belowADX / InpADXLookback;

   double atrHist[]; ArrayResize(atrHist, InpRangeLookback);
   for(int j = 0; j < InpRangeLookback; j++) atrHist[j] = atrs[j+1];
   int belowATR = 0;
   for(int i = 0; i < InpRangeLookback; i++) if(atrHist[i] < atrs[0]) belowATR++;
   double atrPct   = (double)belowATR / InpRangeLookback * 100.0;
   double scoreATR = (atrPct <= InpATRLowPct) ? 1.0
      : MathMax(0.0, 1.0 - (atrPct - InpATRLowPct) / (100.0 - InpATRLowPct));

   return (scoreBB + scoreADX + scoreATR) / 3.0;
}

ENUM_DIRECTION GetICTBias()
{
   if(InpBiasMode == BIAS_MANUAL_BUY)  return DIR_BUY;
   if(InpBiasMode == BIAS_MANUAL_SELL) return DIR_SELL;

   double fast[], slow[];
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true);
   if(CopyBuffer(hFastEMA, 0, 0, 2, fast) < 2 || CopyBuffer(hSlowEMA, 0, 0, 2, slow) < 2)
      return DIR_NONE;

   ENUM_DIRECTION emaBias = (fast[0] > slow[0]) ? DIR_BUY
                          : (fast[0] < slow[0]) ? DIR_SELL : DIR_NONE;
   if(InpBiasMode == BIAS_AUTO_HTF_EMA) return emaBias;

   double pdh    = iHigh (_Symbol, PERIOD_D1, 1);
   double pdl    = iLow  (_Symbol, PERIOD_D1, 1);
   double close0 = iClose(_Symbol, InpEntryTF, 0);
   double high0  = iHigh (_Symbol, InpEntryTF, 0);
   double low0   = iLow  (_Symbol, InpEntryTF, 0);

   ENUM_DIRECTION sweepDir = DIR_NONE;
   if(InpUsePDH_PDL_Sweep)
   {
      if(low0 < pdl && close0 > pdl) sweepDir = DIR_BUY;
      if(high0 > pdh && close0 < pdh) sweepDir = DIR_SELL;
   }

   ENUM_DIRECTION mssDir = DIR_NONE;
   if(InpUseMSS)
   {
      double lastHigh = iHigh(_Symbol, InpEntryTF, 1);
      double lastLow  = iLow (_Symbol, InpEntryTF, 1);
      for(int k = 2; k <= InpSwingLookback; k++)
      {
         lastHigh = MathMax(lastHigh, iHigh(_Symbol, InpEntryTF, k));
         lastLow  = MathMin(lastLow,  iLow (_Symbol, InpEntryTF, k));
      }
      if(close0 > lastHigh) mssDir = DIR_BUY;
      if(close0 < lastLow)  mssDir = DIR_SELL;
   }

   if(sweepDir != DIR_NONE && mssDir != DIR_NONE && sweepDir == mssDir) return sweepDir;
   if(mssDir != DIR_NONE && mssDir == emaBias) return mssDir;
   return emaBias;
}

//==================================================================
// [A] Claude Agent Gate
//==================================================================
bool ClaudeActive()
{
   return (InpClaudeMode != CLAUDE_OFF);
}

// 発射直前チェック。ADVISORY: 常にtrue（判定は記録）。GATE: 一致+信頼度。
bool ClaudeApproves(ENUM_DIRECTION want, double score)
{
   if(!ClaudeActive()) return true;
   if(MQLInfoInteger(MQL_TESTER)) return true;   // [D] テスターは素通し

   // [C] キャッシュが新しければ再利用、古ければ再取得
   if(!g_cl_valid || (TimeCurrent() - g_cl_time) >= (datetime)InpClaudeCooldownSec)
      ClaudeConsult(want, score);

   if(InpClaudeMode == CLAUDE_ADVISORY) return true;

   // GATE モード
   if(!g_cl_apiOK) return InpClaudeFailOpen;
   bool ok = (g_cl_dir == want && g_cl_conf >= InpClaudeMinConf);
   if(!ok)
      Print(StringFormat("[Claude GATE] 発射見送り: want=%s claude=%s conf=%d (min=%d) reason=%s",
            want == DIR_BUY ? "BUY" : "SELL",
            g_cl_dir == DIR_BUY ? "BUY" : (g_cl_dir == DIR_SELL ? "SELL" : "NONE"),
            g_cl_conf, InpClaudeMinConf, g_cl_reason));
   return ok;
}

// セットアップ要約を Claude に渡し JSON 判定を受け取る
void ClaudeConsult(ENUM_DIRECTION want, double score)
{
   g_cl_valid = true;             // 失敗してもクールダウンは効かせる（連打防止）
   g_cl_time  = TimeCurrent();
   g_cl_apiOK = false;

   if(StringLen(InpAnthropicKey) < 10) { g_cl_reason = "APIキー未設定"; return; }

   string ctx = BuildSetupContext(want, score);
   string lang = InpClaudeJapanese ? "reasonは日本語で書くこと。" : "Write reason in English.";
   string systemPrompt =
      "あなたはFXスキャルピングEAのセットアップ検証エージェントです。"
      "レンジ圧縮ブレイク後の逆張りリミット・クラスター(平均回帰でレンジ内へ戻る想定)の是非を判定します。"
      "必ず次のJSONのみで回答すること(前後に文章を付けない): "
      "{\\\"direction\\\":\\\"BUY|SELL|NONE\\\",\\\"confidence\\\":0-100の整数,\\\"reason\\\":\\\"80字以内\\\"} "
      "directionは推奨方向。優位性が無い/急変・指標イベント懸念ならNONE。" + lang;

   string jsonRequest = "{";
   jsonRequest += "\"model\": \"" + InpClaudeModel + "\",";
   jsonRequest += "\"max_tokens\": " + IntegerToString(InpClaudeMaxTokens) + ",";
   jsonRequest += "\"system\": \"" + systemPrompt + "\",";
   jsonRequest += "\"messages\": [";
   jsonRequest += "{\"role\": \"user\", \"content\": \"" + EscapeJSON(ctx) + "\"}";
   jsonRequest += "]}";

   string headers = "Content-Type: application/json\r\n"
                    "x-api-key: " + InpAnthropicKey + "\r\n"
                    "anthropic-version: 2023-06-01\r\n";

   char post[]; char result[]; string resultHeaders;
   int postSize = StringToCharArray(jsonRequest, post, 0, WHOLE_ARRAY, CP_UTF8);
   ArrayResize(post, postSize - 1);

   ResetLastError();
   int status = WebRequest("POST", "https://api.anthropic.com/v1/messages",
                           headers, 30000, post, result, resultHeaders);
   if(status == -1)
   {
      g_cl_reason = "WebRequest失敗 err=" + IntegerToString(GetLastError()) +
                    " (許可URLに https://api.anthropic.com を追加)";
      Print("[Claude] ", g_cl_reason);
      return;
   }
   string response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(status != 200 || StringFind(response, "\"type\":\"error\"") >= 0)
   {
      g_cl_reason = "API HTTP " + IntegerToString(status);
      Print("[Claude] API error: ", StringSubstr(response, 0, 300));
      return;
   }
   if(StringFind(response, "\"stop_reason\":\"refusal\"") >= 0)
   {
      g_cl_reason = "refusal";
      return;
   }

   string text = ExtractText(response);
   ParseVerdict(text);
   g_cl_apiOK = true;
   Print(StringFormat("[Claude] 判定: dir=%s conf=%d reason=%s",
         g_cl_dir == DIR_BUY ? "BUY" : (g_cl_dir == DIR_SELL ? "SELL" : "NONE"),
         g_cl_conf, g_cl_reason));
}

// 判定に渡すセットアップ要約（コンパクトに保つ）
string BuildSetupContext(ENUM_DIRECTION want, double score)
{
   double adx[1]; double atrv[1];
   double adxVal = 0, atrVal = 0;
   if(CopyBuffer(hADX, 0, 0, 1, adx) > 0)  adxVal = adx[0];
   if(CopyBuffer(hATR, 0, 0, 1, atrv) > 0) atrVal = atrv[0];

   string s = "";
   s += "Symbol: " + _Symbol + "  Time: " + TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES) + "\n";
   s += "Bid: " + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits) +
        "  Spread(points): " + DoubleToString(SpreadPoints(), 0) + "\n";
   s += "EAの意図: レンジ [" + DoubleToString(g_range_low, _Digits) + " - " +
        DoubleToString(g_range_high, _Digits) + "] を検出。価格がレンジ外へスイープ後、" +
        (want == DIR_BUY ? "下抜けからのBUYリミット12本(平均回帰でレンジ上限TP)" :
                           "上抜けからのSELLリミット12本(平均回帰でレンジ下限TP)") + "を配置予定。\n";
   s += "RangeScore(BB圧縮+低ADX+低ATRの合成): " + DoubleToString(score, 3) +
        "  ADX(" + IntegerToString(InpADXPeriod) + "): " + DoubleToString(adxVal, 1) +
        "  ATR(" + IntegerToString(InpATRPeriod) + "): " + DoubleToString(atrVal, _Digits) + "\n";
   s += "ICTバイアス: " + (g_bias == DIR_BUY ? "BUY" : (g_bias == DIR_SELL ? "SELL" : "NONE")) + "\n";

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpBiasTF, 0, 12, rates);
   if(copied > 0)
   {
      s += "直近" + IntegerToString(copied) + "本 (" + EnumToString(InpBiasTF) + ", O/H/L/C):\n";
      for(int i = 0; i < copied; i++)
         s += StringFormat("  [%d] %s %s %s %s\n", i,
              DoubleToString(rates[i].open, _Digits), DoubleToString(rates[i].high, _Digits),
              DoubleToString(rates[i].low, _Digits), DoubleToString(rates[i].close, _Digits));
   }
   s += "この逆張りクラスターを発射すべきか、JSONで判定せよ。";
   return s;
}

// {"direction":"BUY","confidence":72,"reason":"..."} を素朴に読む
void ParseVerdict(string text)
{
   g_cl_dir    = DIR_NONE;
   g_cl_conf   = 0;
   g_cl_reason = "(parse失敗)";
   if(StringLen(text) == 0) return;

   if(StringFind(text, "\"BUY\"") >= 0 || StringFind(text, "\"direction\":\"BUY") >= 0 ||
      StringFind(text, "direction\": \"BUY") >= 0)       g_cl_dir = DIR_BUY;
   else if(StringFind(text, "\"SELL\"") >= 0)            g_cl_dir = DIR_SELL;

   int cpos = StringFind(text, "confidence");
   if(cpos >= 0)
   {
      string tail = StringSubstr(text, cpos + 10, 12);
      string num = "";
      for(int i = 0; i < StringLen(tail); i++)
      {
         ushort ch = StringGetCharacter(tail, i);
         if(ch >= '0' && ch <= '9') num += StringSubstr(tail, i, 1);
         else if(StringLen(num) > 0) break;
      }
      if(StringLen(num) > 0) g_cl_conf = (int)StringToInteger(num);
   }

   int rpos = StringFind(text, "\"reason\"");
   if(rpos >= 0)
   {
      int q1 = StringFind(text, "\"", rpos + 8);
      if(q1 >= 0)
      {
         q1++;
         int q2 = q1;
         bool esc = false;
         int len = StringLen(text);
         while(q2 < len)
         {
            ushort ch = StringGetCharacter(text, q2);
            if(esc) { esc = false; q2++; continue; }
            if(ch == '\\') { esc = true; q2++; continue; }
            if(ch == '"') break;
            q2++;
         }
         g_cl_reason = StringSubstr(text, q1, q2 - q1);
      }
   }
}

// Messages API 応答から content[0].text を取り出す
string ExtractText(string response)
{
   int cpos = StringFind(response, "\"content\"");
   if(cpos < 0) return("");
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
   return(text);
}

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
void OnTick()
{
   BasketStats buyStats, sellStats;
   GetBasketStats(POSITION_TYPE_BUY,  buyStats);
   GetBasketStats(POSITION_TYPE_SELL, sellStats);
   int activeOrders = GetActiveOrdersCount();

   ManageBasketSettlement(POSITION_TYPE_BUY,  buyStats);
   ManageBasketSettlement(POSITION_TYPE_SELL, sellStats);

   if(buyStats.count == 0 && sellStats.count == 0 && activeOrders == 0)
   {
      g_BlockNewOrder = false;
      g_maxProfitBuy  = 0.0;
      g_maxProfitSell = 0.0;
   }

   if(buyStats.count > 0 || sellStats.count > 0 || activeOrders > 0 || g_BlockNewOrder)
   { DrawPanel(); return; }

   if(!InpEnableTrading || !DailyGuardOK() || !SpreadOK()) { DrawPanel(); return; }

   // 新足確定チェック
   datetime curBar = iTime(_Symbol, InpEntryTF, 0);
   double score = 0.0;
   if(curBar != g_last_bar)
   {
      g_last_bar = curBar;

      score = RangeEntryScore();
      if(score >= InpRangeScoreMin)
      {
         double tmpH = iHigh(_Symbol, InpEntryTF, 0);
         double tmpL = iLow (_Symbol, InpEntryTF, 0);
         for(int k = 1; k < 16; k++)
         {
            tmpH = MathMax(tmpH, iHigh(_Symbol, InpEntryTF, k));
            tmpL = MathMin(tmpL, iLow (_Symbol, InpEntryTF, k));
         }
         g_range_high = tmpH;
         g_range_low  = tmpL;
         g_range_mid  = (tmpH + tmpL) / 2.0;
         g_state      = STATE_RANGE_ACTIVE;
      }
      else g_state = STATE_IDLE;
   }

   if(g_state != STATE_RANGE_ACTIVE) { DrawPanel(); return; }

   g_bias = GetICTBias();
   if(g_bias == DIR_NONE) { DrawPanel(); return; }

   double currentClose = iClose(_Symbol, InpEntryTF, 0);
   double autoLot      = CalculateDynamicLot();

   if(g_bias == DIR_BUY && currentClose < g_range_low)
   {
      if(ClaudeApproves(DIR_BUY, score))            // [A][B]
      {
         g_BlockNewOrder = true;
         g_state         = STATE_SWEEP_CONFIRMED;
         PlaceBurstLimitOrders(true, autoLot);
      }
   }
   else if(g_bias == DIR_SELL && currentClose > g_range_high)
   {
      if(ClaudeApproves(DIR_SELL, score))           // [A][B]
      {
         g_BlockNewOrder = true;
         g_state         = STATE_SWEEP_CONFIRMED;
         PlaceBurstLimitOrders(false, autoLot);
      }
   }

   DrawPanel();
}

//+------------------------------------------------------------------+
//| HUD パネル（Claude 判定行を追加）                                |
//+------------------------------------------------------------------+
void DrawPanel()
{
   if(!InpShowPanel) return;

   int activeOrders = GetActiveOrdersCount();
   int buyCount  = CountPositionsByType(POSITION_TYPE_BUY);
   int sellCount = CountPositionsByType(POSITION_TYPE_SELL);

   string stateStr;
   switch(g_state)
   {
      case STATE_IDLE:           stateStr = "IDLE";            break;
      case STATE_RANGE_ACTIVE:   stateStr = "RANGE_ACTIVE";    break;
      case STATE_SWEEP_CONFIRMED:stateStr = "SWEEP_CONFIRMED"; break;
      case STATE_CRT_ACTIVE:     stateStr = "CRT_ACTIVE";      break;
      case STATE_TREND_RIDE:     stateStr = "TREND_RIDE";      break;
      case STATE_KILL:           stateStr = "KILL";            break;
      default:                   stateStr = "UNKNOWN";
   }

   string clModeStr = (InpClaudeMode == CLAUDE_OFF) ? "OFF"
                    : (InpClaudeMode == CLAUDE_ADVISORY) ? "ADVISORY" : "GATE";
   string clDirStr  = (g_cl_dir == DIR_BUY) ? "BUY" : (g_cl_dir == DIR_SELL) ? "SELL" : "NONE";
   string clLine    = clModeStr;
   if(InpClaudeMode != CLAUDE_OFF)
      clLine += " | " + clDirStr + " conf=" + IntegerToString(g_cl_conf) +
                (g_cl_valid ? " @" + TimeToString(g_cl_time, TIME_MINUTES) : "");

   string txt =
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
      "  AMOS HyperScalp v1.30 [Claude]\n"
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
      " ステート         : " + stateStr + "\n" +
      " ICTバイアス      : " + (g_bias==DIR_BUY?"BUY":(g_bias==DIR_SELL?"SELL":"NONE")) + "\n" +
      " Claude判定       : " + clLine + "\n" +
      " Claude理由       : " + StringSubstr(g_cl_reason, 0, 60) + "\n" +
      " Equity           : " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n" +
      " 次回ロット       : " + DoubleToString(CalculateDynamicLot(), 2) + " × " + IntegerToString(BurstTargetCount) + "本\n" +
      " 未約定注文       : " + IntegerToString(activeOrders) + " 本\n" +
      " BUY  保有        : " + IntegerToString(buyCount)  + " 本 / ピーク: " + DoubleToString(g_maxProfitBuy,  2) + "\n" +
      " SELL 保有        : " + IntegerToString(sellCount) + " 本 / ピーク: " + DoubleToString(g_maxProfitSell, 2) + "\n" +
      " SL ライン BUY    : " + DoubleToString(g_range_low  - SlBufferDollars, 5) + "\n" +
      " SL ライン SELL   : " + DoubleToString(g_range_high + SlBufferDollars, 5) + "\n" +
      " 最終ログ         : " + g_lastLog + "\n" +
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
   Comment(txt);
}
//+------------------------------------------------------------------+
