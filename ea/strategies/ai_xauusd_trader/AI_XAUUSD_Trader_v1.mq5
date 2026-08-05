//+------------------------------------------------------------------+
//| AI_XAUUSD_Trader_v1.mq5                                          |
//|                        AMOS Level 50 - EA Factory (Layer 06)      |
//|                                                                  |
//|  "1 AI-model EA" requested after reviewing a third-party sales    |
//|  page (STRATEGY LAB "AI TRADER": PF 1.66, Sharpe 4.57, WR 76-78%, |
//|  maxDD 11.6-14.6%, XAUUSD, 2022-2026). Those are unverified       |
//|  marketing claims and this EA does NOT reproduce them.            |
//|                                                                  |
//|  This EA runs a real LightGBM model (20 numeric OHLCV features,  |
//|  M5, 1h-forward direction label) trained + walk-forward tested   |
//|  on this repo's real XAUUSD 1m data (scripts/ai_direction_*.py). |
//|  Honest result: OOS AUC ~0.47-0.57 across 5 monthly folds - no   |
//|  measured directional edge (coin-flip range). See                |
//|  docs/inbox/ai_direction_model_verification.md and                |
//|  reports/ai_direction_wf.json.                                    |
//|                                                                  |
//|  Consequently InpMode defaults to SHADOW (logs the model's        |
//|  decision every bar, places no orders). LIVE mode exists as       |
//|  requested infrastructure but is not a claim of profitability -   |
//|  do not run LIVE on real money without your own validation.       |
//|                                                                  |
//|  Feature computation below is a byte-for-byte port of             |
//|  scripts/ai_direction_features.py's build_features()/             |
//|  build_labels() so the live features match what the model was     |
//|  trained on (RSI/ATR/ADX use the exact Wilder-EWM recursion the   |
//|  training script used - NOT MT5's built-in iADX, which uses a     |
//|  different +DM/-DM reference and would silently feed the model    |
//|  data it never saw in training).                                  |
//|                                                                  |
//|  Setup: compile in MetaEditor (the .onnx under model/ is loaded   |
//|  as a compiled-in resource - no manual file copy needed).         |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

#resource "model\\ai_xauusd_direction.onnx" as uchar ExtModel[]

enum ENUM_AI_MODE
  {
   MODE_SHADOW   = 0, // log the model's decision every bar; place no orders
   MODE_ADVISORY = 1, // same as SHADOW but also shows a persistent chart panel
   MODE_LIVE     = 2  // actually trade (NOT validated - see header)
  };

input group "AI model"
input ENUM_AI_MODE InpMode        = MODE_SHADOW; // default: no capital at risk
input double        InpConfHigh   = 0.55;         // long if proba>=this, short if proba<=1-this
input int            InpHorizonOverride = 0;       // 0 = use model's trained horizon (meta.json: 12 bars)

input group "Risk (only matters in MODE_LIVE)"
input bool   InpUseFixedLot     = true;
input double InpFixedLot        = 0.01;
input double InpRiskPercent     = 0.5;   // used only if InpUseFixedLot=false
input double InpProtectiveSLAtr = 3.0;   // safety-net SL = k*ATR (0 = no SL - not recommended)
input double InpMaxSpreadPts    = 300;
input double InpMaxDailyLossPct = 5.0;
input double InpMaxDrawdownPct  = 20.0;
input long   InpMagic           = 550140;
input int    InpSlippage        = 15;
input bool   InpShowPanel       = true;

//--- feature order MUST match model/meta.json exactly
#define N_FEATURES 20
#define HORIZON_DEFAULT 12
#define WARMUP_BARS 300

long   ExtOnnxHandle = INVALID_HANDLE;
int    g_hEma20      = INVALID_HANDLE;
int    g_hEma50      = INVALID_HANDLE;
int    g_hEma200     = INVALID_HANDLE;
int    g_hATR        = INVALID_HANDLE;
int    g_horizon     = HORIZON_DEFAULT;
datetime g_lastBar   = 0;
double g_lastProba   = 0.5;
string g_lastReason  = "";
int    g_barsHeld    = -1;   // -1 = flat; >=0 = bars since AI entry
int    g_posDir      = 0;
double g_eqPeak      = 0.0;
double g_dayStartEq  = 0.0;
int    g_dayStamp    = -1;
bool   g_halted      = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpConfHigh <= 0.5 || InpConfHigh >= 1.0)
     {
      Print("AIXAU: InpConfHigh must be in (0.5, 1.0).");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_horizon = (InpHorizonOverride > 0) ? InpHorizonOverride : HORIZON_DEFAULT;

   ExtOnnxHandle = OnnxCreateFromBuffer(ExtModel, ONNX_DEFAULT);
   if(ExtOnnxHandle == INVALID_HANDLE)
     {
      Print("AIXAU: OnnxCreateFromBuffer failed, err=", GetLastError());
      return(INIT_FAILED);
     }
   // model was exported with zipmap=False (scripts/ai_direction_export_onnx.py):
   // output 0 = int64 label [1], output 1 = float probabilities [1,2]
   // (column 0 = P(down), column 1 = P(up) - meta.json proba_class_index_up=1)
   const long inShape[]    = {1, N_FEATURES};
   const long labelShape[] = {1};
   const long probaShape[] = {1, 2};
   if(!OnnxSetInputShape(ExtOnnxHandle, 0, inShape) ||
      !OnnxSetOutputShape(ExtOnnxHandle, 0, labelShape) ||
      !OnnxSetOutputShape(ExtOnnxHandle, 1, probaShape))
     { Print("AIXAU: Onnx*Shape failed, err=", GetLastError()); return(INIT_FAILED); }

   // created once here, reused everywhere - creating a fresh handle per
   // bar/call (as the first version did) leaks terminal indicator handles
   g_hEma20  = iMA(_Symbol, PERIOD_M5, 20,  0, MODE_EMA, PRICE_CLOSE);
   g_hEma50  = iMA(_Symbol, PERIOD_M5, 50,  0, MODE_EMA, PRICE_CLOSE);
   g_hEma200 = iMA(_Symbol, PERIOD_M5, 200, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR    = iATR(_Symbol, PERIOD_M5, 14);
   if(g_hEma20 == INVALID_HANDLE || g_hEma50 == INVALID_HANDLE ||
      g_hEma200 == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     { Print("AIXAU: indicator handle creation failed, err=", GetLastError()); return(INIT_FAILED); }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_eqPeak     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEq = g_eqPeak;
   RestorePositionState();

   Print("AI_XAUUSD_Trader v1.00 initialized. Mode=", EnumToString(InpMode),
         "  horizon=", g_horizon, " bars (M5).",
         (InpMode == MODE_LIVE ? "  *** LIVE: this model has NO measured OOS edge (AUC~0.5). ***" : ""));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(ExtOnnxHandle != INVALID_HANDLE) OnnxRelease(ExtOnnxHandle);
   if(g_hEma20  != INVALID_HANDLE) IndicatorRelease(g_hEma20);
   if(g_hEma50  != INVALID_HANDLE) IndicatorRelease(g_hEma50);
   if(g_hEma200 != INVALID_HANDLE) IndicatorRelease(g_hEma200);
   if(g_hATR    != INVALID_HANDLE) IndicatorRelease(g_hATR);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Recover g_barsHeld/g_posDir after a restart from the live         |
//| position itself (position comment carries the entry bar time)     |
//+------------------------------------------------------------------+
void RestorePositionState()
  {
   g_posDir = 0; g_barsHeld = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      g_posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      int barsSince = iBarShift(_Symbol, PERIOD_M5, opened, false);
      g_barsHeld = MathMax(0, barsSince);
      return;
     }
  }

//+------------------------------------------------------------------+
//| Wilder EWM recursion: y[0]=x[0]; y[t]=a*x[t]+(1-a)*y[t-1]         |
//+------------------------------------------------------------------+
void WilderEwm(const double &x[], const double alpha, double &y[])
  {
   int n = ArraySize(x);
   ArrayResize(y, n);
   if(n == 0) return;
   y[0] = x[0];
   for(int i = 1; i < n; i++) y[i] = alpha * x[i] + (1.0 - alpha) * y[i - 1];
  }

//+------------------------------------------------------------------+
//| Byte-for-byte port of ai_direction_features.wilder_atr_rsi_adx()  |
//| c/h/l ascending time (index 0 oldest); returns arrays same length |
//+------------------------------------------------------------------+
void WilderAtrRsiAdx(const double &h[], const double &l[], const double &c[], const int p,
                     double &atr[], double &rsi[], double &adx[])
  {
   int n = ArraySize(c);
   double tr[]; ArrayResize(tr, n);
   double gain[]; ArrayResize(gain, n);
   double loss[]; ArrayResize(loss, n);
   double plusDm[]; ArrayResize(plusDm, n);
   double minusDm[]; ArrayResize(minusDm, n);
   for(int i = 0; i < n; i++)
     {
      double prevC = (i == 0) ? c[0] : c[i - 1];
      tr[i] = MathMax(h[i] - l[i], MathMax(MathAbs(h[i] - prevC), MathAbs(l[i] - prevC)));
      double delta = c[i] - prevC;
      gain[i] = (delta > 0.0) ? delta : 0.0;
      loss[i] = (delta < 0.0) ? -delta : 0.0;
      double up = MathMax(h[i] - prevC, 0.0);
      double dn = MathMax(prevC - l[i], 0.0);
      plusDm[i]  = (up > dn && up > 0.0) ? up : 0.0;
      minusDm[i] = (dn > up && dn > 0.0) ? dn : 0.0;
     }
   double a = 1.0 / p;
   WilderEwm(tr, a, atr);
   double avgGain[], avgLoss[];
   WilderEwm(gain, a, avgGain);
   WilderEwm(loss, a, avgLoss);
   ArrayResize(rsi, n);
   for(int i = 0; i < n; i++)
     {
      double rs = avgGain[i] / MathMax(avgLoss[i], 1e-12);
      rsi[i] = 100.0 - 100.0 / (1.0 + rs);
     }
   double pdiRaw[], mdiRaw[];
   WilderEwm(plusDm, a, pdiRaw);
   WilderEwm(minusDm, a, mdiRaw);
   double pdi[], mdi[], dx[];
   ArrayResize(pdi, n); ArrayResize(mdi, n); ArrayResize(dx, n);
   for(int i = 0; i < n; i++)
     {
      pdi[i] = 100.0 * pdiRaw[i] / MathMax(atr[i], 1e-9);
      mdi[i] = 100.0 * mdiRaw[i] / MathMax(atr[i], 1e-9);
      dx[i]  = 100.0 * MathAbs(pdi[i] - mdi[i]) / MathMax(pdi[i] + mdi[i], 1e-9);
     }
   WilderEwm(dx, a, adx);
  }

//+------------------------------------------------------------------+
//| Kaufman ER, port of ai_direction_features.kaufman_er()            |
//+------------------------------------------------------------------+
void KaufmanEr(const double &c[], const int n_er, double &er[])
  {
   int n = ArraySize(c);
   double csum[]; ArrayResize(csum, n);
   csum[0] = 0.0;
   for(int i = 1; i < n; i++) csum[i] = csum[i - 1] + MathAbs(c[i] - c[i - 1]);
   ArrayResize(er, n);
   for(int i = 0; i < n; i++)
     {
      if(i < n_er) { er[i] = 0.0; continue; }
      double num = MathAbs(c[i] - c[i - n_er]);
      double den = csum[i] - csum[i - n_er];
      er[i] = num / MathMax(den, 1e-12);
     }
  }

double PopStd(const double &x[], const int i0, const int n)
  {
   double mean = 0.0;
   for(int i = i0; i < i0 + n; i++) mean += x[i];
   mean /= n;
   double sq = 0.0;
   for(int i = i0; i < i0 + n; i++) sq += (x[i] - mean) * (x[i] - mean);
   return(MathSqrt(sq / n));
  }

double Mean(const double &x[], const int i0, const int n)
  {
   double s = 0.0;
   for(int i = i0; i < i0 + n; i++) s += x[i];
   return(s / n);
  }

//+------------------------------------------------------------------+
//| Build the 20-feature vector for the LAST CLOSED M5 bar, matching  |
//| ai_direction_features.build_features() exactly.                   |
//+------------------------------------------------------------------+
bool ComputeFeatures(double &out[])
  {
   ArrayResize(out, N_FEATURES);
   int have = Bars(_Symbol, PERIOD_M5);
   int need = WARMUP_BARS + 260; // +260 covers ema200 warmup and rolling(50/20) windows
   int total = MathMin(need, have - 1);
   if(total < WARMUP_BARS) { Print("AIXAU: not enough M5 history yet (", total, " bars)"); return(false); }

   double c[], h[], l[]; long v[];
   ArrayResize(c, total); ArrayResize(h, total); ArrayResize(l, total); ArrayResize(v, total);
   // ascending time: k=0 oldest, k=total-1 = shift 1 (last closed bar)
   for(int k = 0; k < total; k++)
     {
      int shift = total - k;
      c[k] = iClose(_Symbol, PERIOD_M5, shift);
      h[k] = iHigh (_Symbol, PERIOD_M5, shift);
      l[k] = iLow  (_Symbol, PERIOD_M5, shift);
      v[k] = iTickVolume(_Symbol, PERIOD_M5, shift);
     }
   int t = total - 1; // "now" = last closed bar

   double atr[], rsi[], adx[];
   WilderAtrRsiAdx(h, l, c, 14, atr, rsi, adx);
   double er[];
   KaufmanEr(c, 20, er);

   double ema20b[1], ema50b[1], ema200b[1];
   if(CopyBuffer(g_hEma20, 0, 1, 1, ema20b) < 1 || CopyBuffer(g_hEma50, 0, 1, 1, ema50b) < 1 ||
      CopyBuffer(g_hEma200, 0, 1, 1, ema200b) < 1)
     { Print("AIXAU: EMA CopyBuffer failed"); return(false); }
   double ema20 = ema20b[0], ema50 = ema50b[0], ema200 = ema200b[0];

   double bbMid = Mean(c, t - 19, 20);
   double bbStd = PopStd(c, t - 19, 20);
   double bbZ   = (c[t] - bbMid) / MathMax(bbStd, 1e-9);

   double ret1arr[]; ArrayResize(ret1arr, total);
   ret1arr[0] = 0.0;
   for(int i = 1; i < total; i++) ret1arr[i] = (c[i] - c[i - 1]) / c[i - 1];
   double vol20 = PopStd(ret1arr, t - 19, 20);

   double atrMean50 = Mean(atr, t - 49, 50);
   double volRatio  = atr[t] / MathMax(atrMean50, 1e-9);

   double vd[]; ArrayResize(vd, total);
   for(int i = 0; i < total; i++) vd[i] = (double)v[i];
   double volMean50 = Mean(vd, t - 49, 50);
   double volStd50  = PopStd(vd, t - 49, 50);
   double volZ = (vd[t] - volMean50) / MathMax(volStd50, 1e-9);

   datetime barTime = iTime(_Symbol, PERIOD_M5, 1);
   MqlDateTime dt; TimeToStruct(barTime, dt);
   double hourFrac = dt.hour + dt.min / 60.0;
   double hourSin = MathSin(2.0 * M_PI * hourFrac / 24.0);
   double hourCos = MathCos(2.0 * M_PI * hourFrac / 24.0);
   // MQL5 day_of_week: Sunday=0..Saturday=6. Training used pandas
   // dt.dayofweek: Monday=0..Sunday=6. Convert or every live "dow" input
   // is off by a fixed offset from what the model was trained on.
   double dow = (double)((dt.day_of_week + 6) % 7);

   double ret1  = (c[t] - c[t - 1])  / c[t - 1];
   double ret3  = (c[t] - c[t - 3])  / c[t - 3];
   double ret6  = (c[t] - c[t - 6])  / c[t - 6];
   double ret12 = (c[t] - c[t - 12]) / c[t - 12];
   double ret24 = (c[t] - c[t - 24]) / c[t - 24];

   int i = 0;
   out[i++] = ret1;
   out[i++] = ret3;
   out[i++] = ret6;
   out[i++] = ret12;
   out[i++] = ret24;
   out[i++] = atr[t] / c[t];
   out[i++] = rsi[t];
   out[i++] = adx[t];
   out[i++] = er[t];
   out[i++] = (c[t] - ema20)  / c[t];
   out[i++] = (c[t] - ema50)  / c[t];
   out[i++] = (c[t] - ema200) / c[t];
   double sign1 = (MathAbs(ema20 - ema50)  < 1e-12) ? 0.0 : (ema20 > ema50  ? 1.0 : -1.0);
   double sign2 = (MathAbs(ema50 - ema200) < 1e-12) ? 0.0 : (ema50 > ema200 ? 1.0 : -1.0);
   out[i++] = sign1 + sign2;   // matches python's np.sign(ema20-ema50)+np.sign(ema50-ema200)
   out[i++] = bbZ;
   out[i++] = vol20;
   out[i++] = volRatio;
   out[i++] = volZ;
   out[i++] = hourSin;
   out[i++] = hourCos;
   out[i++] = dow;
   return(true);
  }

//+------------------------------------------------------------------+
//| Run the ONNX model on the given feature vector, return P(up)      |
//+------------------------------------------------------------------+
double RunModel(const double &feat[])
  {
   matrix inM; inM.Init(1, N_FEATURES);
   for(int i = 0; i < N_FEATURES; i++) inM[0][i] = feat[i];

   long   labelOut[];
   matrix probaOut;
   if(!OnnxRun(ExtOnnxHandle, ONNX_DEFAULT, inM, labelOut, probaOut))
     {
      Print("AIXAU: OnnxRun failed, err=", GetLastError());
      return(0.5);
     }
   // probaOut is [1 x 2]: column 0 = P(down), column 1 = P(up) (proba_class_index_up=1 per meta.json)
   if(probaOut.Cols() < 2) { Print("AIXAU: unexpected proba shape"); return(0.5); }
   return(probaOut[0][1]);
  }

//+------------------------------------------------------------------+
double SpreadPts() { return((SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point); }

bool DailyGuardOK()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_eqPeak) g_eqPeak = eq;
   if(InpMaxDrawdownPct > 0.0 && eq <= g_eqPeak * (1.0 - InpMaxDrawdownPct / 100.0))
     {
      if(!g_halted) Print("AIXAU: equity DD kill-switch hit. Halting.");
      g_halted = true;
     }
   MqlDateTime st; TimeToStruct(TimeTradeServer(), st);
   int stamp = st.year * 1000 + st.day_of_year;
   if(stamp != g_dayStamp) { g_dayStamp = stamp; g_dayStartEq = eq; }
   if(InpMaxDailyLossPct > 0.0 && g_dayStartEq > 0.0 &&
      eq <= g_dayStartEq * (1.0 - InpMaxDailyLossPct / 100.0))
      return(false);
   return(!g_halted);
  }

double EffLot()
  {
   if(InpUseFixedLot) return(InpFixedLot);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double atrNow = 0.0; // rough sizing reference
   double buf[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, buf) > 0) atrNow = buf[0];
   double perUnit = (tickSize > 0.0) ? tickVal / tickSize : 0.0;
   double dist = MathMax(InpProtectiveSLAtr * atrNow, 10 * _Point);
   double lot = (perUnit > 0.0 && dist > 0.0) ? (eq * InpRiskPercent / 100.0) / (dist * perUnit) : InpFixedLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0) lot = MathFloor(lot / step) * step;
   return(NormalizeDouble(MathMax(vmin, MathMin(vmax, lot)), 2));
  }

void EnterPosition(const int dir)
  {
   double lot = EffLot();
   double atrNow = 0.0;
   double buf[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, buf) > 0) atrNow = buf[0];
   double sl = 0.0;
   if(InpProtectiveSLAtr > 0.0 && atrNow > 0.0)
     {
      double px = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = (dir > 0) ? NormalizeDouble(px - InpProtectiveSLAtr * atrNow, _Digits)
                     : NormalizeDouble(px + InpProtectiveSLAtr * atrNow, _Digits);
     }
   bool ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0.0, sl, 0.0, "AIXAU up " + DoubleToString(g_lastProba, 3))
                       : trade.Sell(lot, _Symbol, 0.0, sl, 0.0, "AIXAU down " + DoubleToString(g_lastProba, 3));
   if(ok) { g_posDir = dir; g_barsHeld = 0; }
   else Print("AIXAU: entry failed, retcode=", trade.ResultRetcode());
  }

void ClosePosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      trade.PositionClose(t);
     }
   g_posDir = 0; g_barsHeld = -1;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == g_lastBar) { ShowPanel(); return; }
   g_lastBar = bar;

   double feat[];
   if(!ComputeFeatures(feat)) { ShowPanel(); return; }
   g_lastProba = RunModel(feat);
   int direction = 0;
   if(g_lastProba >= InpConfHigh)            direction = 1;
   else if(g_lastProba <= 1.0 - InpConfHigh) direction = -1;
   g_lastReason = StringFormat("P(up)=%.3f  conf_band=[%.2f,%.2f]  decision=%s",
                               g_lastProba, 1.0 - InpConfHigh, InpConfHigh,
                               direction == 1 ? "LONG" : (direction == -1 ? "SHORT" : "NO-TRADE"));

   if(InpMode == MODE_SHADOW || InpMode == MODE_ADVISORY)
     {
      Print("AIXAU [SHADOW] ", g_lastReason);
      ShowPanel();
      return; // never places an order
     }

   // MODE_LIVE from here
   if(g_posDir != 0)
     {
      g_barsHeld++;
      if(g_barsHeld >= g_horizon) ClosePosition(); // time-exit, matching the tested horizon
      ShowPanel();
      return;
     }

   if(!DailyGuardOK() || SpreadPts() > InpMaxSpreadPts) { ShowPanel(); return; }
   if(direction != 0) EnterPosition(direction);
   ShowPanel();
  }

//+------------------------------------------------------------------+
void ShowPanel()
  {
   if(!InpShowPanel) return;
   string txt = "AI_XAUUSD_Trader v1.00  |  Mode=" + EnumToString(InpMode) + "\n" +
      g_lastReason + "\n" +
      "position=" + (g_posDir == 0 ? "flat" : (g_posDir > 0 ? "LONG" : "SHORT")) +
      (g_posDir != 0 ? "  held " + IntegerToString(g_barsHeld) + "/" + IntegerToString(g_horizon) + " bars" : "") + "\n" +
      "*** WF OOS AUC ~0.47-0.57 on real data - no measured edge (see docs/inbox/ai_direction_model_verification.md) ***";
   Comment(txt);
  }
//+------------------------------------------------------------------+
