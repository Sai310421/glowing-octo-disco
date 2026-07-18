//+------------------------------------------------------------------+
//|                                        BoomTrendRider_v0.mq5      |
//|                        AMOS Level 50 - EA Factory (Layer 06)      |
//|                                                                  |
//|  Video-faithful symmetric stop-and-reverse trend rider for       |
//|  Deriv BOOM_100 (M1). Implements docs/inbox/boom_trend_rider.md: |
//|  equal-lot pyramid every Delta in the trend direction, a single  |
//|  opposite stop trailed with price, flip-on-fill (bank the        |
//|  ladder), regime-adaptive pitch (WIDEN in range), delta-lock on  |
//|  velocity spikes, and a separate news-window module.             |
//|                                                                  |
//|  v1.00: production hardening - two-step flip (no re-flip while    |
//|  the old stack is closing), lock volume verify + rebalance,      |
//|  spread/margin/freeze guards, daily-loss halt and equity DD      |
//|  kill-switch, state persistence across restarts, order-churn     |
//|  limits, and an emergency flatten state.                         |
//|                                                                  |
//|  NOT deployable until Phase C validation passes (Monte Carlo     |
//|  P10, Rules 3/4) and a human approves (Layer 12). Prices are in  |
//|  index price units (chart units). Needs an MT5 compile pass (no  |
//|  MetaEditor here).                                               |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_RIDER_STATE
  {
   ST_FLAT = 0,   // no exposure: straddle seed pending
   ST_RIDE,       // stacking with the trend, reverse stop trailed
   ST_FLIP,       // reverse stop filled: closing the old stack
   ST_LOCKED,     // delta-locked after a velocity spike
   ST_NEWS_HALT,  // inside a news window (FLATTEN/LOCK/STRADDLE)
   ST_HALT_DAY,   // daily-loss halt: flat until the next server day
   ST_EMERGENCY,  // anomaly: flatten, cooldown, then restart flat
   ST_KILLED      // equity DD kill-switch: manual re-init required
  };

enum ENUM_NEWS_MODE
  {
   NEWS_OFF = 0,      // BOOM_100 synthetic: no calendar (default)
   NEWS_FLATTEN,      // close all before the window, halt inside
   NEWS_LOCK,         // delta-lock through the window
   NEWS_STRADDLE      // wide stop pair to harvest the announcement move
  };

input group "Pitch / regime (packet: decision 1)"
input double InpDeltaMin      = 50.0;  // Delta_min: pitch floor (index price units)
input double InpAtrMult       = 1.0;   // c_atr: pitch = max(Delta_min, c_atr*ATR)
input int    InpAtrPeriod     = 14;    // ATR period (M1 closed bars)
input int    InpERPeriod      = 20;    // Kaufman ER lookback (bars)
input double InpERRangeBelow  = 0.30;  // er_lo: ER below => RANGE regime
input double InpERTrendAbove  = 0.45;  // er_hi: ER above => TREND regime
input double InpRangeWiden    = 2.0;   // w_range: pitch multiplier in RANGE (widen)
input bool   InpRangeHaltStack = true; // RANGE: halt stacking beyond the seed

input group "Ride / stack"
input double InpLot           = 0.01;  // L: fixed lot everywhere (no martingale)
input int    InpNMax          = 10;    // N_max: max stacked positions
input double InpRevDistMult   = 1.0;   // d_rev = mult * Delta_t (reverse stop distance)
input bool   InpUsePerPosTP   = false; // optional per-position TP (video: OFF = pure SAR)
input double InpCtp           = 3.0;   // per-position TP = c_tp * Delta_t

input group "Sudden change: delta lock (packet: decision 2)"
input bool   InpUseLock       = true;  // velocity spike => equal-volume lock
input int    InpSpikeLookback = 5;     // tau bars
input double InpSpikeMaxVel   = 40.0;  // v_max: price units per bar (lock at/above)
input double InpCalmVel       = 20.0;  // v_calm: unwind below this velocity
input int    InpMinStackToLock = 2;    // lock only when stack >= this
input double InpLockTolLots   = 0.02;  // lock vs stack volume tolerance (lots)
input int    InpLockRebalMax  = 3;     // rebalance attempts before Emergency

input group "News windows (packet: decision 4; server time)"
input ENUM_NEWS_MODE InpNewsMode = NEWS_OFF; // separate logic, default OFF
input string InpNewsWindows   = "";    // "HH:MM-HH:MM;HH:MM-HH:MM" (server time)
input int    InpNewsPreMin    = 5;     // act this many minutes before each window
input double InpNewsStraddleK = 2.0;   // k_news: straddle distance = k * Delta_t

input group "Account risk"
input double InpMinMarginLevel = 800.0; // halt new exposure below this margin level %
input double InpMaxDailyLossPct = 5.0;  // flatten + halt for the day at this loss % (0=off)
input double InpMaxDrawdownPct  = 20.0; // kill-switch: DD % from equity peak (0=off)
input int    InpMaxSpreadPts    = 0;    // skip new exposure above this spread, points (0=off)
input int    InpCooldownSec     = 300;  // Emergency -> FLAT cooldown (seconds)

input group "Execution"
input double InpTrailStep     = 5.0;   // min improvement before re-pricing a stop (price units)
input int    InpOpBackoffSec  = 5;     // pause after a rejected trade op (seconds)
input bool   InpShowComment   = true;  // chart status line

input group "Misc"
input long   InpMagic         = 550120; // ride basket magic
input long   InpMagicLock     = 550121; // lock leg magic
input int    InpSlippage      = 10;     // deviation in points

CTrade           trade;
ENUM_RIDER_STATE g_state       = ST_FLAT;
int              g_dir         = 0;      // +1 riding long, -1 riding short
double           g_lastAdd     = 0.0;    // last stack entry price
double           g_lockRef     = 0.0;    // price at lock time
bool             g_rangeMode   = false;  // regime hysteresis latch
int              g_hATR        = INVALID_HANDLE;
datetime         g_backoffTill = 0;      // no trade ops before this time
datetime         g_cooldownEnd = 0;      // Emergency cooldown end
int              g_lockRebalTries = 0;
double           g_eqPeak      = 0.0;    // for the DD kill-switch
double           g_dayStartEq  = 0.0;    // for the daily-loss halt
int              g_dayStamp    = 0;      // server day marker (year*1000 + doy)
datetime         g_regimeBar   = 0;      // last bar regime/pitch were computed on
double           g_pitchCache  = 0.0;

//+------------------------------------------------------------------+
//| State persistence (survives terminal restarts)                   |
//+------------------------------------------------------------------+
string GV(const string key) { return(StringFormat("BTR_%d_%s", (int)InpMagic, key)); }

void SaveState()
  {
   GlobalVariableSet(GV("state"),   (double)g_state);
   GlobalVariableSet(GV("dir"),     (double)g_dir);
   GlobalVariableSet(GV("lastAdd"), g_lastAdd);
   GlobalVariableSet(GV("lockRef"), g_lockRef);
   GlobalVariableSet(GV("eqPeak"),  g_eqPeak);
   GlobalVariableSet(GV("dayEq"),   g_dayStartEq);
   GlobalVariableSet(GV("dayStamp"),(double)g_dayStamp);
  }

void LoadState()
  {
   if(!GlobalVariableCheck(GV("state"))) return;
   g_state      = (ENUM_RIDER_STATE)(int)GlobalVariableGet(GV("state"));
   g_dir        = (int)GlobalVariableGet(GV("dir"));
   g_lastAdd    = GlobalVariableGet(GV("lastAdd"));
   g_lockRef    = GlobalVariableGet(GV("lockRef"));
   g_eqPeak     = GlobalVariableGet(GV("eqPeak"));
   g_dayStartEq = GlobalVariableGet(GV("dayEq"));
   g_dayStamp   = (int)GlobalVariableGet(GV("dayStamp"));
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   // --- input validation: refuse to start with unusable parameters
   if(InpDeltaMin <= 0.0 || InpAtrMult < 0.0 || InpAtrPeriod < 1 ||
      InpERPeriod < 2 || InpERRangeBelow < 0.0 || InpERTrendAbove <= InpERRangeBelow ||
      InpRangeWiden < 1.0 || InpLot <= 0.0 || InpNMax < 1 || InpRevDistMult <= 0.0 ||
      InpSpikeLookback < 1 || InpSpikeMaxVel <= 0.0 || InpCalmVel <= 0.0 ||
      InpCalmVel > InpSpikeMaxVel || InpMinStackToLock < 1 || InpLockTolLots < 0.0 ||
      InpNewsPreMin < 0 || InpNewsStraddleK <= 0.0 || InpTrailStep <= 0.0 ||
      InpMagic == InpMagicLock)
     {
      Print("BTR: invalid inputs - refusing to start.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(InpLot < vmin)
     {
      Print("BTR: InpLot ", InpLot, " below symbol minimum ", vmin, ".");
      return(INIT_PARAMETERS_INCORRECT);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_hATR = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(g_hATR == INVALID_HANDLE) return(INIT_FAILED);

   LoadState();
   RestoreState(); // live positions win over stale saved state
   if(g_eqPeak <= 0.0) g_eqPeak = AccountInfoDouble(ACCOUNT_EQUITY);
   SaveState();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   SaveState();
   if(InpShowComment) Comment("");
  }

//+------------------------------------------------------------------+
//| Ownership / basket helpers                                       |
//+------------------------------------------------------------------+
bool IsMagic(const long magic, const string sym, const long want)
  {
   return(magic == want && sym == _Symbol);
  }

// count positions of one type under one magic; type=-1 counts all
int CountPos(const long magic, const int type)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), magic)) continue;
      if(type >= 0 && (int)PositionGetInteger(POSITION_TYPE) != type) continue;
      n++;
     }
   return(n);
  }

double VolumeOf(const long magic, const int type)
  {
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), magic)) continue;
      if(type >= 0 && (int)PositionGetInteger(POSITION_TYPE) != type) continue;
      v += PositionGetDouble(POSITION_VOLUME);
     }
   return(v);
  }

// most advanced stack entry in the trend direction (highest for long, lowest for short)
double ExtremeEntry(const int dir)
  {
   double best = 0.0; bool found = false;
   int want = (dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), InpMagic)) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != want) continue;
      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!found || (dir > 0 && e > best) || (dir < 0 && e < best)) { best = e; found = true; }
     }
   return(found ? best : 0.0);
  }

// direction of the most recently opened ride position (0 when flat)
int NewestDir()
  {
   datetime newest = 0; int dir = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), InpMagic)) continue;
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(ot >= newest)
        {
         newest = ot;
         dir = ((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
        }
     }
   return(dir);
  }

void ClosePositions(const long magic, const int type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), magic)) continue;
      if(type >= 0 && (int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if(!trade.PositionClose(t)) Backoff("close");
     }
  }

void CloseEverything()
  {
   ClosePositions(InpMagic, -1);
   ClosePositions(InpMagicLock, -1);
   DeletePendings();
  }

int PendingCount(const int type)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL), InpMagic)) continue;
      if(type >= 0 && (int)OrderGetInteger(ORDER_TYPE) != type) continue;
      n++;
     }
   return(n);
  }

ulong PendingTicket(const int type)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL), InpMagic)) continue;
      if((int)OrderGetInteger(ORDER_TYPE) == type) return(t);
     }
   return(0);
  }

void DeletePendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL), InpMagic)) continue;
      if(!trade.OrderDelete(t)) Backoff("delete");
     }
  }

//+------------------------------------------------------------------+
//| Execution guards                                                 |
//+------------------------------------------------------------------+
double MinStopDist()  { return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point); }
double FreezeDist()   { return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point); }
double SpreadPts()    { return((SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point); }

void Backoff(const string what)
  {
   g_backoffTill = TimeCurrent() + InpOpBackoffSec;
   Print("BTR: ", what, " failed, retcode=", trade.ResultRetcode(), " '", trade.ResultRetcodeDescription(),
         "' - backing off ", InpOpBackoffSec, "s.");
  }

bool OpsAllowed()
  {
   if(TimeCurrent() < g_backoffTill) return(false);
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return(false);
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)) return(false);
   return(true);
  }

bool MarginOK()
  {
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   return(ml == 0.0 || ml >= InpMinMarginLevel); // 0 = no open margin
  }

bool SpreadOK()
  {
   return(InpMaxSpreadPts <= 0 || SpreadPts() <= InpMaxSpreadPts);
  }

// new market exposure allowed? (pendings pay no spread; market orders do)
bool CanAddExposure()
  {
   return(OpsAllowed() && MarginOK() && SpreadOK());
  }

// enough free margin for one more lot of 'type'?
bool MarginForLot(const ENUM_ORDER_TYPE type, const double lot)
  {
   double need = 0.0;
   double px = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(!OrderCalcMargin(type, _Symbol, lot, px, need)) return(false);
   return(AccountInfoDouble(ACCOUNT_MARGIN_FREE) > need * 1.5); // 50% headroom
  }

// round a volume to the symbol's step and min/max limits
double NormVol(double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0) v = MathFloor(v / step + 1e-9) * step;
   v = MathMax(vmin, MathMin(vmax, v));
   return(NormalizeDouble(v, 2));
  }

//+------------------------------------------------------------------+
//| Regime / pitch (packet: decision 1 - WIDEN in range)             |
//| Recomputed once per closed M1 bar.                               |
//+------------------------------------------------------------------+
double EfficiencyRatio()
  {
   int n = MathMax(2, InpERPeriod);
   double num = MathAbs(iClose(_Symbol, PERIOD_CURRENT, 1) - iClose(_Symbol, PERIOD_CURRENT, n));
   double den = 0.0;
   for(int i = 1; i < n; i++)
      den += MathAbs(iClose(_Symbol, PERIOD_CURRENT, i) - iClose(_Symbol, PERIOD_CURRENT, i + 1));
   return(den > 0.0 ? num / den : 1.0);
  }

void UpdateRegimeAndPitch()
  {
   datetime bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar == g_regimeBar && g_pitchCache > 0.0) return;
   g_regimeBar = bar;

   double er = EfficiencyRatio();
   if(er < InpERRangeBelow)       g_rangeMode = true;   // range: widen pitch
   else if(er >= InpERTrendAbove) g_rangeMode = false;  // trend: normal pitch
   // in between: keep previous mode (hysteresis)

   double atr[1];
   double d = InpDeltaMin;
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) == 1 && atr[0] > 0.0)
      d = MathMax(InpDeltaMin, InpAtrMult * atr[0]);
   if(g_rangeMode) d *= InpRangeWiden;
   g_pitchCache = d;
  }

double PitchNow() { return(g_pitchCache > 0.0 ? g_pitchCache : InpDeltaMin); }

double Velocity()
  {
   int tau = MathMax(1, InpSpikeLookback);
   double now  = iClose(_Symbol, PERIOD_CURRENT, 0);
   double past = iClose(_Symbol, PERIOD_CURRENT, tau);
   if(now == 0.0 || past == 0.0) return(0.0);
   return((now - past) / tau); // signed: + = up, - = down
  }

//+------------------------------------------------------------------+
//| Pending order placement/re-pricing with churn + freeze guards    |
//+------------------------------------------------------------------+
void PlaceOrMoveStop(const int type, const double target, const double lot,
                     const string tag, const bool tightenOnly, const int tightenDir)
  {
   if(!OpsAllowed()) return;
   ulong ticket = PendingTicket(type);
   if(ticket == 0)
     {
      bool ok = (type == ORDER_TYPE_BUY_STOP)
                ? trade.BuyStop(lot, target, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, tag)
                : trade.SellStop(lot, target, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, tag);
      if(!ok) Backoff(tag);
      return;
     }
   if(!OrderSelect(ticket)) return;
   double cur = OrderGetDouble(ORDER_PRICE_OPEN);
   if(MathAbs(target - cur) < InpTrailStep) return; // churn guard
   if(tightenOnly)
     {
      // tightenDir=+1: only ever move the stop up; -1: only down
      if((tightenDir > 0 && target <= cur) || (tightenDir < 0 && target >= cur)) return;
     }
   // freeze guard: cannot modify an order the market is about to hit
   double ref = (type == ORDER_TYPE_BUY_STOP) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(MathAbs(cur - ref) <= FreezeDist()) return;
   if(!trade.OrderModify(ticket, target, 0.0, 0.0, ORDER_TIME_GTC, 0)) Backoff("modify " + tag);
  }

//+------------------------------------------------------------------+
//| News windows (packet: decision 4 - separate logic)               |
//+------------------------------------------------------------------+
bool InNewsWindow()
  {
   if(InpNewsMode == NEWS_OFF || StringLen(InpNewsWindows) == 0) return(false);
   MqlDateTime st;
   TimeToStruct(TimeTradeServer(), st);
   int nowMin = st.hour * 60 + st.min;

   string wins[];
   int nw = StringSplit(InpNewsWindows, ';', wins);
   for(int i = 0; i < nw; i++)
     {
      string parts[];
      if(StringSplit(wins[i], '-', parts) != 2) continue;
      string a[], b[];
      if(StringSplit(parts[0], ':', a) != 2 || StringSplit(parts[1], ':', b) != 2) continue;
      int from = ((int)StringToInteger(a[0])) * 60 + (int)StringToInteger(a[1]) - InpNewsPreMin;
      int to   = ((int)StringToInteger(b[0])) * 60 + (int)StringToInteger(b[1]);
      if(from <= to) { if(nowMin >= from && nowMin <= to) return(true); }
      else           { if(nowMin >= from || nowMin <= to) return(true); } // crosses midnight
     }
   return(false);
  }

// returns true when normal riding must not run this tick
bool HandleNews()
  {
   bool inWin = InNewsWindow();

   if(g_state == ST_NEWS_HALT)
     {
      if(inWin)
        {
         if(InpNewsMode == NEWS_STRADDLE) ManageStraddle(InpNewsStraddleK, "BTR news straddle");
         // FLATTEN: keep retrying until actually flat (a close can be rejected)
         if(InpNewsMode == NEWS_FLATTEN && OpsAllowed() &&
            (CountPos(InpMagic, -1) + CountPos(InpMagicLock, -1) > 0 || PendingCount(-1) > 0))
            CloseEverything();
         return(true);
        }
      // window over: unwind a news lock, then hand back to normal logic
      if(InpNewsMode == NEWS_LOCK) ClosePositions(InpMagicLock, -1);
      int dir = NewestDir();
      if(dir != 0)
        {
         g_dir     = dir;
         g_lastAdd = ExtremeEntry(g_dir);
         DeletePendings();
         g_state = ST_RIDE;
        }
      else { g_dir = 0; g_state = ST_FLAT; }
      SaveState();
      return(false);
     }

   if(!inWin) return(false);

   // entering a window
   switch(InpNewsMode)
     {
      case NEWS_FLATTEN:
         CloseEverything();
         g_dir = 0;
         break;
      case NEWS_LOCK:
        {
         // net across BOTH baskets: if a spike lock is already on, net is 0
         // and no extra hedge is added (double-hedge guard)
         double net = VolumeOf(InpMagic, POSITION_TYPE_BUY) + VolumeOf(InpMagicLock, POSITION_TYPE_BUY)
                    - VolumeOf(InpMagic, POSITION_TYPE_SELL) - VolumeOf(InpMagicLock, POSITION_TYPE_SELL);
         double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(MathAbs(net) < vmin * 0.5) net = 0.0;             // already flat/locked
         else net = (net > 0.0) ? NormVol(net) : -NormVol(-net);
         trade.SetExpertMagicNumber(InpMagicLock);
         bool ok = true;
         if(net > 0.0)      ok = trade.Sell(net, _Symbol, 0.0, 0.0, 0.0, "BTR news lock");
         else if(net < 0.0) ok = trade.Buy(-net, _Symbol, 0.0, 0.0, 0.0, "BTR news lock");
         trade.SetExpertMagicNumber(InpMagic);
         if(!ok) { Backoff("news lock"); return(true); } // retry next tick, stay pre-window
         DeletePendings();
         break;
        }
      case NEWS_STRADDLE:
         DeletePendings();
         ManageStraddle(InpNewsStraddleK, "BTR news straddle");
         break;
      default:
         break;
     }
   g_state = ST_NEWS_HALT;
   SaveState();
   return(true);
  }

// symmetric stop pair around price; both legs track price (no tighten-only)
void ManageStraddle(const double k, const string tag)
  {
   double d   = MathMax(k * PitchNow(), MinStopDist() + _Point);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(CountPos(InpMagic, POSITION_TYPE_BUY) == 0)
      PlaceOrMoveStop(ORDER_TYPE_BUY_STOP,  NormalizeDouble(ask + d, _Digits), NormVol(InpLot), tag, false, 0);
   if(CountPos(InpMagic, POSITION_TYPE_SELL) == 0)
      PlaceOrMoveStop(ORDER_TYPE_SELL_STOP, NormalizeDouble(bid - d, _Digits), NormVol(InpLot), tag, false, 0);
  }

//+------------------------------------------------------------------+
//| Account-level halts                                              |
//+------------------------------------------------------------------+
// returns true when the EA must not trade this tick
bool HandleAccountRisk()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_eqPeak) { g_eqPeak = eq; SaveState(); }

   // kill-switch: DD from equity peak. Manual restart required by design.
   if(g_state != ST_KILLED && InpMaxDrawdownPct > 0.0 &&
      eq <= g_eqPeak * (1.0 - InpMaxDrawdownPct / 100.0))
     {
      Print("BTR: KILL-SWITCH - equity ", eq, " is ", InpMaxDrawdownPct,
            "% below peak ", g_eqPeak, ". Flattening and halting until re-init.");
      g_state = ST_KILLED;
      SaveState();
     }
   if(g_state == ST_KILLED)
     {
      if(CountPos(InpMagic, -1) + CountPos(InpMagicLock, -1) > 0 || PendingCount(-1) > 0)
         if(OpsAllowed()) CloseEverything();
      return(true);
     }

   // daily loss halt: reset at the server-day boundary
   MqlDateTime st;
   TimeToStruct(TimeTradeServer(), st);
   int stamp = st.year * 1000 + st.day_of_year;
   if(stamp != g_dayStamp)
     {
      g_dayStamp   = stamp;
      g_dayStartEq = eq;
      if(g_state == ST_HALT_DAY) g_state = ST_FLAT;
      SaveState();
     }
   if(g_state != ST_HALT_DAY && InpMaxDailyLossPct > 0.0 && g_dayStartEq > 0.0 &&
      eq <= g_dayStartEq * (1.0 - InpMaxDailyLossPct / 100.0))
     {
      Print("BTR: daily loss limit hit (", InpMaxDailyLossPct, "% of ", g_dayStartEq,
            ") - flat until the next server day.");
      g_state = ST_HALT_DAY;
      SaveState();
     }
   if(g_state == ST_HALT_DAY)
     {
      if(CountPos(InpMagic, -1) + CountPos(InpMagicLock, -1) > 0 || PendingCount(-1) > 0)
         if(OpsAllowed()) CloseEverything();
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| FLAT: straddle seed - first fill decides the direction           |
//+------------------------------------------------------------------+
void ManageFlat()
  {
   int dir = NewestDir();
   if(dir != 0)
     {
      g_dir     = dir;
      g_lastAdd = ExtremeEntry(g_dir);
      DeletePendings(); // leftover seed stop; a fresh reverse stop is armed in RIDE
      g_state   = ST_RIDE;
      SaveState();
      return;
     }
   if(!CanAddExposure()) return;
   ManageStraddle(1.0, "BTR seed");
  }

//+------------------------------------------------------------------+
//| RIDE: stack with the trend, trail the reverse stop               |
//+------------------------------------------------------------------+
void ManageRide()
  {
   int myType  = (g_dir > 0) ? POSITION_TYPE_BUY  : POSITION_TYPE_SELL;
   int oppType = (g_dir > 0) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   // --- flip: the reverse stop filled (opposite-type position under ride magic)
   if(CountPos(InpMagic, oppType) > 0)
     {
      g_dir   = -g_dir;         // the fill is seed #1 of the new ride
      g_state = ST_FLIP;        // ST_FLIP closes the old stack, then resumes
      DeletePendings();
      SaveState();
      return;
     }

   if(CountPos(InpMagic, myType) == 0) { g_dir = 0; g_state = ST_FLAT; SaveState(); return; }

   double d   = PitchNow();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double px  = (g_dir > 0) ? bid : ask;

   // --- delta lock on a velocity spike against the stack (decision 2)
   if(InpUseLock && CountPos(InpMagic, myType) >= InpMinStackToLock && OpsAllowed())
     {
      double v = Velocity();
      if(MathAbs(v) >= InpSpikeMaxVel && ((g_dir > 0 && v < 0.0) || (g_dir < 0 && v > 0.0)))
        {
         double vol = NormVol(VolumeOf(InpMagic, myType));
         trade.SetExpertMagicNumber(InpMagicLock);
         bool ok = (g_dir > 0) ? trade.Sell(vol, _Symbol, 0.0, 0.0, 0.0, "BTR lock")
                               : trade.Buy(vol, _Symbol, 0.0, 0.0, 0.0, "BTR lock");
         trade.SetExpertMagicNumber(InpMagic);
         if(ok)
           {
            DeletePendings();
            g_lockRef        = px;
            g_lockRebalTries = 0;
            g_state          = ST_LOCKED;
            SaveState();
            return;
           }
         Backoff("lock");
        }
     }

   // --- stack: price advanced one pitch beyond the last add (with the trend)
   bool stackAllowed = !(g_rangeMode && InpRangeHaltStack);
   if(stackAllowed && CanAddExposure() && CountPos(InpMagic, myType) < InpNMax)
     {
      if((g_dir > 0 && px >= g_lastAdd + d) || (g_dir < 0 && px <= g_lastAdd - d))
        {
         ENUM_ORDER_TYPE ot = (g_dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         if(MarginForLot(ot, InpLot))
           {
            bool ok = (g_dir > 0) ? trade.Buy(NormVol(InpLot), _Symbol, 0.0, 0.0, 0.0, "BTR stack")
                                  : trade.Sell(NormVol(InpLot), _Symbol, 0.0, 0.0, 0.0, "BTR stack");
            if(ok) { g_lastAdd = px; SaveState(); }
            else Backoff("stack");
           }
        }
     }

   // --- optional per-position TP ladder (default OFF: pure SAR like the video)
   if(InpUsePerPosTP) ManagePerPosTP(d);

   // --- reverse stop: exactly one, trailed monotonically tighter (decision 3)
   double dist   = MathMax(InpRevDistMult * d, MinStopDist() + _Point);
   double target = (g_dir > 0) ? NormalizeDouble(bid - dist, _Digits)
                               : NormalizeDouble(ask + dist, _Digits);
   if(g_dir > 0) PlaceOrMoveStop(ORDER_TYPE_SELL_STOP, target, NormVol(InpLot), "BTR reverse", true, +1);
   else          PlaceOrMoveStop(ORDER_TYPE_BUY_STOP,  target, NormVol(InpLot), "BTR reverse", true, -1);
  }

void ManagePerPosTP(const double d)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), InpMagic)) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp = (type == POSITION_TYPE_BUY) ? NormalizeDouble(entry + InpCtp * d, _Digits)
                                              : NormalizeDouble(entry - InpCtp * d, _Digits);
      if(MathAbs(PositionGetDouble(POSITION_TP) - tp) > InpTrailStep) // churn guard
         if(!trade.PositionModify(t, PositionGetDouble(POSITION_SL), tp)) Backoff("tp");
     }
  }

//+------------------------------------------------------------------+
//| FLIP: close the old stack, then resume riding the new direction  |
//| Two-step so a slow/failed close can never trigger a second flip. |
//+------------------------------------------------------------------+
void ManageFlip()
  {
   int oldType = (g_dir > 0) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   if(CountPos(InpMagic, oldType) > 0)
     {
      if(OpsAllowed()) ClosePositions(InpMagic, oldType); // bank the ladder
      return; // keep retrying until the old side is flat
     }
   int newType = (g_dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   if(CountPos(InpMagic, newType) == 0) { g_dir = 0; g_state = ST_FLAT; SaveState(); return; }
   g_lastAdd = ExtremeEntry(g_dir);
   g_state   = ST_RIDE;
   SaveState();
  }

//+------------------------------------------------------------------+
//| LOCKED: verify the lock, wait for calm, resume or flip           |
//+------------------------------------------------------------------+
void ManageLocked()
  {
   int myType = (g_dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   if(CountPos(InpMagicLock, -1) == 0) // lock leg gone (manual close?) -> resume
     {
      g_state = (CountPos(InpMagic, -1) > 0) ? ST_RIDE : ST_FLAT;
      SaveState();
      return;
     }

   // --- lock verify: hedge volume must match stack volume (net ~ 0)
   double stackVol = VolumeOf(InpMagic, myType);
   double lockVol  = VolumeOf(InpMagicLock, -1);
   double gap      = stackVol - lockVol;
   if(MathAbs(gap) > InpLockTolLots)
     {
      if(g_lockRebalTries >= InpLockRebalMax) { EnterEmergency("lock imbalance persists"); return; }
      if(OpsAllowed())
        {
         g_lockRebalTries++;
         double add = NormVol(MathAbs(gap));
         trade.SetExpertMagicNumber(InpMagicLock);
         bool ok;
         if(gap > 0.0) ok = (g_dir > 0) ? trade.Sell(add, _Symbol, 0.0, 0.0, 0.0, "BTR lock rebal")
                                        : trade.Buy(add, _Symbol, 0.0, 0.0, 0.0, "BTR lock rebal");
         else          ok = (g_dir > 0) ? trade.Buy(add, _Symbol, 0.0, 0.0, 0.0, "BTR lock rebal")
                                        : trade.Sell(add, _Symbol, 0.0, 0.0, 0.0, "BTR lock rebal");
         trade.SetExpertMagicNumber(InpMagic);
         if(!ok) Backoff("lock rebal");
        }
      return;
     }

   if(MathAbs(Velocity()) >= InpCalmVel) return; // still moving fast: stay locked
   if(!OpsAllowed()) return;

   double px = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double d  = PitchNow();

   if((g_dir > 0 && px >= g_lockRef) || (g_dir < 0 && px <= g_lockRef))
     {
      // spike faded on the stack side: drop the hedge, keep riding
      ClosePositions(InpMagicLock, -1);
      g_lastAdd = ExtremeEntry(g_dir);
      g_state   = ST_RIDE;
      SaveState();
      return;
     }
   if((g_dir > 0 && px <= g_lockRef - d) || (g_dir < 0 && px >= g_lockRef + d))
     {
      // spike became the new leg: realize the old stack, reseed in the new regime
      ClosePositions(InpMagic, myType);
      ClosePositions(InpMagicLock, -1);
      g_dir   = 0;
      g_state = ST_FLAT;
      SaveState();
     }
  }

//+------------------------------------------------------------------+
//| Emergency: flatten, cool down, restart flat                      |
//+------------------------------------------------------------------+
void EnterEmergency(const string why)
  {
   Print("BTR: EMERGENCY - ", why, ". Flattening; cooldown ", InpCooldownSec, "s.");
   g_state       = ST_EMERGENCY;
   g_cooldownEnd = TimeCurrent() + InpCooldownSec;
   SaveState();
  }

void ManageEmergency()
  {
   if(CountPos(InpMagic, -1) + CountPos(InpMagicLock, -1) > 0 || PendingCount(-1) > 0)
     {
      if(OpsAllowed()) CloseEverything();
      return;
     }
   if(TimeCurrent() < g_cooldownEnd) return;
   g_dir   = 0;
   g_state = ST_FLAT;
   SaveState();
  }

//+------------------------------------------------------------------+
//| Crash/restart recovery: live positions win over saved state      |
//+------------------------------------------------------------------+
void RestoreState()
  {
   if(g_state == ST_KILLED) return; // kill-switch survives restarts by design

   if(CountPos(InpMagicLock, -1) > 0)
     {
      int dir = NewestDir();
      g_dir = (dir != 0) ? dir
              : ((VolumeOf(InpMagic, POSITION_TYPE_BUY) >= VolumeOf(InpMagic, POSITION_TYPE_SELL)) ? 1 : -1);
      if(g_lockRef <= 0.0)
         g_lockRef = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                 : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      g_lockRebalTries = 0;
      g_state = ST_LOCKED;
      return;
     }

   int buys  = CountPos(InpMagic, POSITION_TYPE_BUY);
   int sells = CountPos(InpMagic, POSITION_TYPE_SELL);
   if(buys == 0 && sells == 0)
     {
      if(g_state != ST_HALT_DAY && g_state != ST_EMERGENCY) { g_state = ST_FLAT; g_dir = 0; }
      return;
     }
   if(buys > 0 && sells > 0)
     {
      // both sides open under the ride magic: a flip was interrupted mid-close
      g_dir   = NewestDir();
      g_state = ST_FLIP;
      return;
     }
   g_dir     = (buys > 0) ? 1 : -1;
   g_lastAdd = ExtremeEntry(g_dir);
   g_state   = ST_RIDE;
  }

//+------------------------------------------------------------------+
//| Status line                                                      |
//+------------------------------------------------------------------+
string StateName(const ENUM_RIDER_STATE s)
  {
   switch(s)
     {
      case ST_FLAT:      return("FLAT");
      case ST_RIDE:      return("RIDE");
      case ST_FLIP:      return("FLIP");
      case ST_LOCKED:    return("LOCKED");
      case ST_NEWS_HALT: return("NEWS");
      case ST_HALT_DAY:  return("HALT-DAY");
      case ST_EMERGENCY: return("EMERGENCY");
      case ST_KILLED:    return("KILLED");
     }
   return("?");
  }

void ShowStatus()
  {
   if(!InpShowComment) return;
   Comment(StringFormat("BoomTrendRider v1.00  |  %s %s  |  stack %d/%d  pitch %.0f%s  |  eq %.2f (peak %.2f)",
           StateName(g_state), (g_dir > 0 ? "LONG" : (g_dir < 0 ? "SHORT" : "-")),
           CountPos(InpMagic, (g_dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL), InpNMax,
           PitchNow(), (g_rangeMode ? " (RANGE x" + DoubleToString(InpRangeWiden, 1) + ")" : ""),
           AccountInfoDouble(ACCOUNT_EQUITY), g_eqPeak));
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateRegimeAndPitch();

   if(HandleAccountRisk()) { ShowStatus(); return; } // KILLED / HALT-DAY own the tick
   if(HandleNews())        { ShowStatus(); return; } // news module owns the tick

   switch(g_state)
     {
      case ST_FLAT:      ManageFlat();      break;
      case ST_RIDE:      ManageRide();      break;
      case ST_FLIP:      ManageFlip();      break;
      case ST_LOCKED:    ManageLocked();    break;
      case ST_EMERGENCY: ManageEmergency(); break;
      default:           g_state = ST_FLAT; break;
     }
   ShowStatus();
  }
//+------------------------------------------------------------------+
