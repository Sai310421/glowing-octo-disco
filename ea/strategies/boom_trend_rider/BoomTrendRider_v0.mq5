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
//|  NOT deployable until Phase C validation passes (Monte Carlo     |
//|  P10, Rules 3/4) and a human approves (Layer 12). Prices are in  |
//|  index price units (chart units). Needs an MT5 compile pass.     |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "0.10"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_RIDER_STATE
  {
   ST_FLAT = 0,   // no exposure: straddle seed pending
   ST_RIDE,       // stacking with the trend, reverse stop trailed
   ST_LOCKED,     // delta-locked after a velocity spike
   ST_NEWS_HALT   // inside a news window (FLATTEN/LOCK handled)
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

input group "News windows (packet: decision 4; server time)"
input ENUM_NEWS_MODE InpNewsMode = NEWS_OFF; // separate logic, default OFF
input string InpNewsWindows   = "";    // "HH:MM-HH:MM;HH:MM-HH:MM" (server time)
input int    InpNewsPreMin    = 5;     // act this many minutes before each window
input double InpNewsStraddleK = 2.0;   // k_news: straddle distance = k * Delta_t

input group "Risk floor"
input double InpMinMarginLevel = 800.0; // halt new exposure below this margin level %

input group "Misc"
input long   InpMagic         = 550120; // ride basket magic
input long   InpMagicLock     = 550121; // lock leg magic
input int    InpSlippage      = 10;     // deviation in points

CTrade           trade;
ENUM_RIDER_STATE g_state      = ST_FLAT;
int              g_dir        = 0;      // +1 riding long, -1 riding short
double           g_lastAdd    = 0.0;    // last stack entry price
double           g_lockRef    = 0.0;    // price at lock time
bool             g_rangeMode  = false;  // regime hysteresis latch
int              g_hATR       = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_hATR = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(g_hATR == INVALID_HANDLE) return(INIT_FAILED);
   RestoreState();
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) {}

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

// most advanced stack entry in the trend direction (lowest for short, highest for long)
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

void ClosePositions(const long magic, const int type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMagic((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), magic)) continue;
      if(type >= 0 && (int)PositionGetInteger(POSITION_TYPE) != type) continue;
      trade.PositionClose(t);
     }
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
      trade.OrderDelete(t);
     }
  }

double MinStopDist()
  {
   return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point);
  }

bool MarginOK()
  {
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   return(ml == 0.0 || ml >= InpMinMarginLevel); // 0 = no open margin
  }

//+------------------------------------------------------------------+
//| Regime / pitch (packet: decision 1 - WIDEN in range)             |
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

void UpdateRegime()
  {
   double er = EfficiencyRatio();
   if(er < InpERRangeBelow)      g_rangeMode = true;   // range: widen pitch
   else if(er >= InpERTrendAbove) g_rangeMode = false; // trend: normal pitch
   // in between: keep previous mode (hysteresis)
  }

double PitchNow()
  {
   double atr[1];
   double d = InpDeltaMin;
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) == 1 && atr[0] > 0.0)
      d = MathMax(InpDeltaMin, InpAtrMult * atr[0]);
   if(g_rangeMode) d *= InpRangeWiden;
   return(d);
  }

double Velocity()
  {
   int tau = MathMax(1, InpSpikeLookback);
   double now  = iClose(_Symbol, PERIOD_CURRENT, 0);
   double past = iClose(_Symbol, PERIOD_CURRENT, tau);
   if(now == 0.0 || past == 0.0) return(0.0);
   return((now - past) / tau); // signed: + = up, - = down
  }

//+------------------------------------------------------------------+
//| News windows (packet: decision 4 - separate logic)               |
//+------------------------------------------------------------------+
// true when server time is inside any window (minus the pre-margin)
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
      if(inWin) { if(InpNewsMode == NEWS_STRADDLE) ManageStraddle(); return(true); }
      // window over: unwind a news lock, then hand back to normal logic
      if(InpNewsMode == NEWS_LOCK) ClosePositions(InpMagicLock, -1);
      g_state = (CountPos(InpMagic, -1) > 0) ? ST_RIDE : ST_FLAT;
      return(false);
     }

   if(!inWin) return(false);

   // entering a window
   switch(InpNewsMode)
     {
      case NEWS_FLATTEN:
         ClosePositions(InpMagic, -1);
         ClosePositions(InpMagicLock, -1);
         DeletePendings();
         g_dir = 0;
         break;
      case NEWS_LOCK:
        {
         double net = VolumeOf(InpMagic, POSITION_TYPE_BUY) - VolumeOf(InpMagic, POSITION_TYPE_SELL);
         trade.SetExpertMagicNumber(InpMagicLock);
         if(net > 0.0)      trade.Sell(net, _Symbol, 0.0, 0.0, 0.0, "BTR_v0 news lock");
         else if(net < 0.0) trade.Buy(-net, _Symbol, 0.0, 0.0, 0.0, "BTR_v0 news lock");
         trade.SetExpertMagicNumber(InpMagic);
         DeletePendings();
         break;
        }
      case NEWS_STRADDLE:
         DeletePendings();
         ManageStraddle();
         break;
      default:
         break;
     }
   g_state = ST_NEWS_HALT;
   return(true);
  }

// symmetric wide stop pair; a fill becomes a normal ride seed after the window
void ManageStraddle()
  {
   double d   = InpNewsStraddleK * PitchNow();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(PendingCount(ORDER_TYPE_BUY_STOP) == 0 && CountPos(InpMagic, POSITION_TYPE_BUY) == 0)
      trade.BuyStop(InpLot, NormalizeDouble(ask + MathMax(d, MinStopDist() + _Point), _Digits),
                    _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BTR_v0 news straddle");
   if(PendingCount(ORDER_TYPE_SELL_STOP) == 0 && CountPos(InpMagic, POSITION_TYPE_SELL) == 0)
      trade.SellStop(InpLot, NormalizeDouble(bid - MathMax(d, MinStopDist() + _Point), _Digits),
                     _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BTR_v0 news straddle");
  }

//+------------------------------------------------------------------+
//| FLAT: straddle seed - first fill decides the direction           |
//+------------------------------------------------------------------+
void ManageFlat()
  {
   int buys  = CountPos(InpMagic, POSITION_TYPE_BUY);
   int sells = CountPos(InpMagic, POSITION_TYPE_SELL);
   if(buys > 0 || sells > 0)
     {
      g_dir = (buys > 0) ? 1 : -1;
      g_lastAdd = ExtremeEntry(g_dir);
      DeletePendings(); // leftover seed stop; a fresh reverse stop is armed in RIDE
      g_state = ST_RIDE;
      return;
     }
   if(!MarginOK()) return;

   double d   = PitchNow();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(PendingCount(ORDER_TYPE_BUY_STOP) == 0)
      trade.BuyStop(InpLot, NormalizeDouble(ask + MathMax(d, MinStopDist() + _Point), _Digits),
                    _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BTR_v0 seed");
   if(PendingCount(ORDER_TYPE_SELL_STOP) == 0)
      trade.SellStop(InpLot, NormalizeDouble(bid - MathMax(d, MinStopDist() + _Point), _Digits),
                     _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BTR_v0 seed");
  }

//+------------------------------------------------------------------+
//| RIDE: stack with the trend, trail the reverse stop, flip on fill |
//+------------------------------------------------------------------+
void ManageRide()
  {
   int myType  = (g_dir > 0) ? POSITION_TYPE_BUY  : POSITION_TYPE_SELL;
   int oppType = (g_dir > 0) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   // --- flip: the reverse stop filled (opposite-type position under ride magic)
   if(CountPos(InpMagic, oppType) > 0)
     {
      ClosePositions(InpMagic, myType); // bank the ladder
      DeletePendings();
      g_dir     = -g_dir;
      g_lastAdd = ExtremeEntry(g_dir);
      return; // fresh reverse stop next tick
     }

   if(CountPos(InpMagic, myType) == 0) { g_state = ST_FLAT; g_dir = 0; return; }

   double d   = PitchNow();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double px  = (g_dir > 0) ? bid : ask;

   // --- delta lock on a velocity spike against the stack (decision 2)
   if(InpUseLock && CountPos(InpMagic, myType) >= InpMinStackToLock)
     {
      double v = Velocity();
      if(MathAbs(v) >= InpSpikeMaxVel && ((g_dir > 0 && v < 0.0) || (g_dir < 0 && v > 0.0)))
        {
         double vol = VolumeOf(InpMagic, myType);
         trade.SetExpertMagicNumber(InpMagicLock);
         bool ok = (g_dir > 0) ? trade.Sell(vol, _Symbol, 0.0, 0.0, 0.0, "BTR_v0 lock")
                               : trade.Buy(vol, _Symbol, 0.0, 0.0, 0.0, "BTR_v0 lock");
         trade.SetExpertMagicNumber(InpMagic);
         if(ok)
           {
            DeletePendings();
            g_lockRef = px;
            g_state   = ST_LOCKED;
            return;
           }
        }
     }

   // --- stack: price advanced one pitch beyond the last add (with the trend)
   bool stackAllowed = !(g_rangeMode && InpRangeHaltStack);
   if(stackAllowed && MarginOK() && CountPos(InpMagic, myType) < InpNMax)
     {
      if((g_dir > 0 && px >= g_lastAdd + d) || (g_dir < 0 && px <= g_lastAdd - d))
        {
         bool ok = (g_dir > 0) ? trade.Buy(InpLot, _Symbol, 0.0, 0.0, 0.0, "BTR_v0 stack")
                               : trade.Sell(InpLot, _Symbol, 0.0, 0.0, 0.0, "BTR_v0 stack");
         if(ok) g_lastAdd = px;
        }
     }

   // --- optional per-position TP ladder (default OFF: pure SAR like the video)
   if(InpUsePerPosTP) ManagePerPosTP(d);

   // --- reverse stop: exactly one, trailed monotonically tighter (decision 3)
   double dist    = MathMax(InpRevDistMult * d, MinStopDist() + _Point);
   double target  = (g_dir > 0) ? NormalizeDouble(bid - dist, _Digits)
                                : NormalizeDouble(ask + dist, _Digits);
   int    revType = (g_dir > 0) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
   ulong  ticket  = PendingTicket(revType);
   if(ticket == 0)
     {
      if(g_dir > 0) trade.SellStop(InpLot, target, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BTR_v0 reverse");
      else          trade.BuyStop(InpLot, target, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BTR_v0 reverse");
     }
   else if(OrderSelect(ticket))
     {
      double cur = OrderGetDouble(ORDER_PRICE_OPEN);
      // tighten only: up-ride lifts the sell stop, down-ride lowers the buy stop
      if((g_dir > 0 && target > cur + _Point) || (g_dir < 0 && target < cur - _Point))
         trade.OrderModify(ticket, target, 0.0, 0.0, ORDER_TIME_GTC, 0);
     }
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
      if(MathAbs(PositionGetDouble(POSITION_TP) - tp) > _Point)
         trade.PositionModify(t, PositionGetDouble(POSITION_SL), tp);
     }
  }

//+------------------------------------------------------------------+
//| LOCKED: wait for calm, then resume or flip (decision 2)          |
//+------------------------------------------------------------------+
void ManageLocked()
  {
   int myType = (g_dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   if(CountPos(InpMagicLock, -1) == 0) // lock leg gone (manual close?) -> resume
     {
      g_state = (CountPos(InpMagic, -1) > 0) ? ST_RIDE : ST_FLAT;
      return;
     }
   if(MathAbs(Velocity()) >= InpCalmVel) return; // still moving fast: stay locked

   double px = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double d  = PitchNow();

   if((g_dir > 0 && px >= g_lockRef) || (g_dir < 0 && px <= g_lockRef))
     {
      // spike faded on the stack side: drop the hedge, keep riding
      ClosePositions(InpMagicLock, -1);
      g_lastAdd = ExtremeEntry(g_dir);
      g_state   = ST_RIDE;
      return;
     }
   if((g_dir > 0 && px <= g_lockRef - d) || (g_dir < 0 && px >= g_lockRef + d))
     {
      // spike became the new leg: realize the old stack, seed from the hedge side
      ClosePositions(InpMagic, myType);
      ClosePositions(InpMagicLock, -1);
      g_dir   = -g_dir;
      g_state = ST_FLAT; // reseed straddle in the new regime
     }
  }

//+------------------------------------------------------------------+
//| Crash/restart recovery: rebuild state from live positions        |
//+------------------------------------------------------------------+
void RestoreState()
  {
   if(CountPos(InpMagicLock, -1) > 0)
     {
      g_dir = (VolumeOf(InpMagic, POSITION_TYPE_BUY) >= VolumeOf(InpMagic, POSITION_TYPE_SELL)) ? 1 : -1;
      g_lockRef = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                              : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      g_state = ST_LOCKED;
      return;
     }
   int buys  = CountPos(InpMagic, POSITION_TYPE_BUY);
   int sells = CountPos(InpMagic, POSITION_TYPE_SELL);
   if(buys == 0 && sells == 0) { g_state = ST_FLAT; g_dir = 0; return; }
   g_dir     = (buys >= sells) ? 1 : -1;
   g_lastAdd = ExtremeEntry(g_dir);
   g_state   = ST_RIDE;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateRegime();
   if(HandleNews()) return; // separate news logic owns the tick

   switch(g_state)
     {
      case ST_FLAT:   ManageFlat();   break;
      case ST_RIDE:   ManageRide();   break;
      case ST_LOCKED: ManageLocked(); break;
      default:        g_state = ST_FLAT; break;
     }
  }
//+------------------------------------------------------------------+
