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
//|  v1.10: multi-symbol (XAUUSD-ready) broker auto-calibration and   |
//|  dynamic ATR trailing. The EA measures the broker's real spread  |
//|  (EMA of ask-bid), derives the pitch floor and the entry spread  |
//|  gate from it, and sizes the lot / stack cap from equity, the    |
//|  account leverage and the symbol's margin requirements. The      |
//|  reverse stop can trail chandelier-style at k*ATR behind the     |
//|  best price of the leg. All prices remain in the symbol's own    |
//|  price units (chart units), so nothing assumes BOOM's scale.     |
//|                                                                  |
//|  NOT deployable until Phase C validation passes (Monte Carlo     |
//|  P10, Rules 3/4) and a human approves (Layer 12). Needs an MT5   |
//|  compile pass (no MetaEditor here).                              |
//+------------------------------------------------------------------+
//|  v1.20: broker-adaptive timeframe. The EA no longer depends on    |
//|  the chart timeframe: it picks the working timeframe itself as    |
//|  the fastest one whose average bar range clears a multiple of    |
//|  the measured spread (cost-noise floor), reviews the choice      |
//|  periodically with hysteresis, and rebuilds its indicators when  |
//|  it steps up or down. Manual timeframe override remains.         |
//+------------------------------------------------------------------+
//|  v1.31: close-confirmed entries (no wick fills). Seed, stack     |
//|  adds, the trail anchor and (by default) the flip decision are   |
//|  all taken on CLOSED bars of the working timeframe - intrabar    |
//|  wicks never trigger an entry. The video-style resting reverse   |
//|  stop remains available via InpFlipMode=FLIP_STOP_ORDER; the     |
//|  velocity delta-lock stays tick-based as the crash guard.        |
//+------------------------------------------------------------------+
//|  v1.30: MQL5 economic-calendar integration. High-importance      |
//|  events for the symbol's currencies open news windows            |
//|  automatically (pre/post margins), on top of the manual          |
//|  HH:MM-HH:MM windows. The calendar API yields nothing in the     |
//|  Strategy Tester or offline - the EA logs one warning and        |
//|  degrades to manual windows there.                               |
//+------------------------------------------------------------------+
//|  v1.40: causal ER regime gate (docs/inbox/trend_rider_          |
//|  50pct_verification.md - "Regime-gate walk-forward" section).    |
//|  A long-window Kaufman ER (default ~250 M5 bars / 20.8h) is       |
//|  compared against hysteresis thresholds derived ONLY from the     |
//|  trailing InpGateTrainDays of ER history (no lookahead),          |
//|  recalibrated every InpGateRecalcDays. Below the OFF threshold,   |
//|  the EA flattens and sits out; above the ON threshold, it         |
//|  resumes normal riding. Walk-forward verified on one instrument/  |
//|  period (XAUUSD M5, 2026 Mar-Jul: weak-regime months improved     |
//|  from -$134/mo to +$38/mo net); default OFF until validated on    |
//|  more data. This is a SEPARATE module from the short-window ER    |
//|  used for pitch widening (decision 1) - the two do not interact.  |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "1.40"
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
   ST_KILLED,     // equity DD kill-switch: manual re-init required
   ST_GATE_OFF    // regime gate: long-window ER below threshold, sitting out
  };

enum ENUM_NEWS_MODE
  {
   NEWS_OFF = 0,      // no news handling (use for synthetics like BOOM_100)
   NEWS_FLATTEN,      // close all before the window, halt inside
   NEWS_LOCK,         // delta-lock through the window
   NEWS_STRADDLE      // wide stop pair to harvest the announcement move
  };

enum ENUM_TRAIL_MODE
  {
   TRAIL_PITCH = 0,  // reverse stop at RevDistMult * pitch behind price
   TRAIL_ATR         // chandelier: k*ATR behind the best price of the leg
  };

enum ENUM_FLIP_MODE
  {
   FLIP_ON_CLOSE = 0, // flip when a bar CLOSES beyond the trail (no wick fills)
   FLIP_STOP_ORDER    // video-style resting stop order (fills on wicks)
  };

input group "Broker auto-calibration (XAUUSD-ready)"
input bool   InpAutoCalibrate = true;  // measure spread/leverage and adapt
input double InpPitchSpreadMult = 4.0; // pitch floor >= mult * avg spread
input double InpSpreadSpikeMult = 3.0; // skip new exposure when spread > mult * avg
input bool   InpAutoLot       = true;  // size lot from equity/risk (else InpLot)
input double InpRiskPctPerFlip = 0.5;  // auto lot: % equity lost on one false flip
input double InpMaxMarginUsePct = 30.0;// full stack margin cap, % of equity

input group "Timeframe auto-selection"
input bool   InpAutoTimeframe = true;  // pick the working TF from spread vs bar range
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // manual TF when auto is off
input double InpTfRangeSpreadMult = 6.0; // require avg bar range >= mult * spread
input int    InpTfReviewMin   = 60;    // re-check the TF choice every N minutes

input group "Pitch / regime (packet: decision 1)"
input double InpDeltaMin      = 0.0;   // Delta_min: pitch floor, price units (0 = auto from spread)
input double InpAtrMult       = 1.0;   // c_atr: pitch = max(floor, c_atr*ATR)
input int    InpAtrPeriod     = 14;    // ATR period (closed bars of the working TF)
input int    InpERPeriod      = 20;    // Kaufman ER lookback (bars)
input double InpERRangeBelow  = 0.30;  // er_lo: ER below => RANGE regime
input double InpERTrendAbove  = 0.45;  // er_hi: ER above => TREND regime
input double InpRangeWiden    = 2.0;   // w_range: pitch multiplier in RANGE (widen)
input bool   InpRangeHaltStack = true; // RANGE: halt stacking beyond the seed

input group "Ride / stack"
input double InpLot           = 0.01;  // L: manual lot when InpAutoLot=false
input int    InpNMax          = 10;    // N_max: max stacked positions (may be auto-reduced)
input bool   InpUsePerPosTP   = false; // optional per-position TP (video: OFF = pure SAR)
input double InpCtp           = 3.0;   // per-position TP = c_tp * Delta_t

input group "Entry confirmation (v1.31 - no wick entries)"
input bool   InpEntryOnClose  = true;  // seed/stack only on CLOSED bars (wicks ignored)
input ENUM_FLIP_MODE InpFlipMode = FLIP_ON_CLOSE; // flip on bar close (default) or resting stop

input group "Dynamic ATR trail (reverse stop)"
input ENUM_TRAIL_MODE InpTrailMode = TRAIL_ATR; // pitch-based or chandelier ATR trail
input double InpTrailAtrMult  = 2.0;   // k_atr: trail distance = k * ATR (TRAIL_ATR)
input double InpRevDistMult   = 1.0;   // d_rev = mult * pitch (TRAIL_PITCH)

input group "Sudden change: delta lock (packet: decision 2)"
input bool   InpUseLock       = true;  // velocity spike => equal-volume lock
input int    InpSpikeLookback = 5;     // tau bars
input double InpSpikeAtrMult  = 3.0;   // auto: v_max = mult * ATR per bar (symbol-agnostic)
input double InpCalmAtrMult   = 1.5;   // auto: v_calm = mult * ATR per bar
input double InpSpikeMaxVel   = 40.0;  // manual v_max, price units per bar (AutoCalibrate=false)
input double InpCalmVel       = 20.0;  // manual v_calm (AutoCalibrate=false)
input int    InpMinStackToLock = 2;    // lock only when stack >= this
input double InpLockTolLots   = 0.02;  // lock vs stack volume tolerance (lots)
input int    InpLockRebalMax  = 3;     // rebalance attempts before Emergency

input group "News handling (packet: decision 4)"
input ENUM_NEWS_MODE InpNewsMode = NEWS_FLATTEN; // action for news windows (OFF for synthetics)
input string InpNewsWindows   = "";    // extra manual windows "HH:MM-HH:MM;..." (server time)
input int    InpNewsPreMin    = 5;     // manual windows: act N minutes before
input double InpNewsStraddleK = 2.0;   // k_news: straddle distance = k * Delta_t

input group "Regime gate (v1.40, WF-verified one instrument/period only)"
input bool   InpUseRegimeGate  = false; // sit out low-efficiency regimes (opt-in; see docs/inbox/trend_rider_50pct_verification.md)
input int    InpGateWindowMin  = 1250;  // long-window ER lookback, minutes (default: WF winner ~250 M5 bars = 20.8h)
input int    InpGateTrainDays  = 60;    // trailing days of ER history used to set thresholds (matches the WF study)
input double InpGateQOn        = 0.50;  // ER quantile (of the trailing sample) that switches trading ON
input double InpGateQGap       = 0.20;  // hysteresis gap: OFF threshold = (q_on - gap) quantile
input int    InpGateRecalcDays = 30;    // recalibrate thresholds every N days (matches the WF fold cadence)

input group "Economic calendar (MQL5 built-in; v1.30)"
input bool   InpUseCalendar   = true;  // auto news windows from the MT5 calendar
input ENUM_CALENDAR_EVENT_IMPORTANCE InpCalMinImportance = CALENDAR_IMPORTANCE_HIGH; // minimum importance
input string InpCalCurrencies = "auto";// "auto" = the symbol's currencies, or e.g. "USD,EUR"
input int    InpCalPreMin     = 15;    // enter news mode N minutes before an event
input int    InpCalPostMin    = 15;    // leave news mode N minutes after the event
input int    InpCalRefreshMin = 30;    // refresh the event cache every N minutes

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
double           g_atrCache    = 0.0;    // ATR in price units (per bar refresh)
double           g_spreadEMA   = 0.0;    // measured broker spread, price units
double           g_legExt      = 0.0;    // best price of the current leg (ATR trail anchor)
double           g_effLot      = 0.0;    // auto-sized lot in effect
int              g_effNMax     = 0;      // margin-capped stack limit in effect
ENUM_TIMEFRAMES  g_tf          = PERIOD_M1; // working timeframe in effect
datetime         g_tfNextReview = 0;     // next TF re-evaluation time
datetime         g_calEvents[];          // cached event times (server time)
datetime         g_calNextRefresh = 0;   // next calendar cache refresh
bool             g_calWarned   = false;  // calendar-unavailable warning shown
datetime         g_entryBar    = 0;      // closed-bar gate for entry decisions
double           g_flatHi      = 0.0;    // highest close while FLAT (close-based seed)
double           g_flatLo      = 0.0;    // lowest close while FLAT
double           g_trailLevel  = 0.0;    // tighten-only trail level (close-based flip)
bool             g_gateOn      = true;   // regime gate state (permissive until calibrated)
double           g_gateErNow   = 1.0;    // current long-window ER reading
double           g_gateThrOn   = 0.0;    // ON threshold in ER units (0 = not calibrated yet)
double           g_gateThrOff  = 0.0;    // OFF threshold in ER units
datetime         g_gateErBar   = 0;      // last bar the long-window ER was refreshed on
datetime         g_gateNextRecalc = 0;   // next threshold recalibration time

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
   GlobalVariableSet(GV("legExt"),  g_legExt);
   GlobalVariableSet(GV("trail"),   g_trailLevel);
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
   g_legExt     = GlobalVariableGet(GV("legExt"));
   g_trailLevel = GlobalVariableGet(GV("trail"));
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   // --- input validation: refuse to start with unusable parameters
   if(InpDeltaMin < 0.0 || InpAtrMult < 0.0 || InpAtrPeriod < 1 ||
      InpERPeriod < 2 || InpERRangeBelow < 0.0 || InpERTrendAbove <= InpERRangeBelow ||
      InpRangeWiden < 1.0 || InpLot <= 0.0 || InpNMax < 1 || InpRevDistMult <= 0.0 ||
      InpTrailAtrMult <= 0.0 || InpSpikeLookback < 1 || InpSpikeMaxVel <= 0.0 ||
      InpCalmVel <= 0.0 || InpCalmVel > InpSpikeMaxVel || InpMinStackToLock < 1 ||
      InpLockTolLots < 0.0 || InpNewsPreMin < 0 || InpNewsStraddleK <= 0.0 ||
      InpTrailStep <= 0.0 || InpPitchSpreadMult < 1.0 || InpSpreadSpikeMult < 1.0 ||
      InpSpikeAtrMult <= 0.0 || InpCalmAtrMult <= 0.0 || InpCalmAtrMult > InpSpikeAtrMult ||
      InpTfRangeSpreadMult < 1.0 || InpTfReviewMin < 1 ||
      InpCalPreMin < 0 || InpCalPostMin < 0 || InpCalRefreshMin < 1 ||
      InpRiskPctPerFlip <= 0.0 || InpMaxMarginUsePct <= 0.0 || InpMaxMarginUsePct > 100.0 ||
      InpGateWindowMin < 1 || InpGateTrainDays < 1 || InpGateQOn <= 0.0 || InpGateQOn > 1.0 ||
      InpGateQGap < 0.0 || InpGateQOn - InpGateQGap < 0.0 || InpGateRecalcDays < 1 ||
      InpMagic == InpMagicLock)
     {
      Print("BTR: invalid inputs - refusing to start.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpDeltaMin == 0.0 && !InpAutoCalibrate)
     {
      Print("BTR: InpDeltaMin=0 (auto) requires InpAutoCalibrate=true.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(!InpAutoLot && InpLot < vmin)
     {
      Print("BTR: InpLot ", InpLot, " below symbol minimum ", vmin, ".");
      return(INIT_PARAMETERS_INCORRECT);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_tf = InpAutoTimeframe ? PERIOD_M1
        : ((InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)Period() : InpTimeframe);
   g_hATR = iATR(_Symbol, g_tf, InpAtrPeriod);
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

// broker spread auto-detection: EMA of the live spread in price units
void UpdateSpreadStats()
  {
   double s = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(s <= 0.0) return;
   g_spreadEMA = (g_spreadEMA <= 0.0) ? s : 0.05 * s + 0.95 * g_spreadEMA;
  }

bool SpreadOK()
  {
   if(InpMaxSpreadPts > 0 && SpreadPts() > InpMaxSpreadPts) return(false); // manual cap
   if(InpAutoCalibrate && g_spreadEMA > 0.0)
     {
      double s = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(s > InpSpreadSpikeMult * g_spreadEMA) return(false); // widened spread (news/rollover)
     }
   return(true);
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
//| Broker-adaptive timeframe (v1.20)                                |
//| A TF is usable when its average bar range clears a multiple of   |
//| the measured spread - otherwise cost/noise dominates every bar   |
//| and the pitch/trail degenerate into spread-churn. The EA picks   |
//| the fastest usable TF, re-checks periodically, and only steps    |
//| back down with a hysteresis margin so it does not flap.          |
//+------------------------------------------------------------------+
double AvgBarRange(const ENUM_TIMEFRAMES tf, const int nBars)
  {
   int have = Bars(_Symbol, tf);
   int n = MathMin(nBars, have - 1);
   if(n < 10) return(0.0); // not enough history to judge this TF
   double sum = 0.0;
   for(int i = 1; i <= n; i++)
      sum += iHigh(_Symbol, tf, i) - iLow(_Symbol, tf, i);
   return(sum / n);
  }

void ApplyTimeframe(const ENUM_TIMEFRAMES tf)
  {
   if(tf == g_tf) return;
   int h = iATR(_Symbol, tf, InpAtrPeriod);
   if(h == INVALID_HANDLE) { Print("BTR: iATR failed for ", EnumToString(tf), " - keeping ", EnumToString(g_tf)); return; }
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   g_hATR      = h;
   Print("BTR: working timeframe ", EnumToString(g_tf), " -> ", EnumToString(tf),
         " (avg range vs spread ", DoubleToString(g_spreadEMA, _Digits), ")");
   g_tf        = tf;
   g_regimeBar = 0;    // force regime/pitch/sizing recompute on the new TF
   g_atrCache  = 0.0;
   g_pitchCache = 0.0;
  }

void SelectTimeframe()
  {
   if(!InpAutoTimeframe || g_spreadEMA <= 0.0) return;
   static ENUM_TIMEFRAMES ladder[] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4};
   int nlad = ArraySize(ladder);

   int cur = 0;
   for(int i = 0; i < nlad; i++) if(ladder[i] == g_tf) { cur = i; break; }

   double need = InpTfRangeSpreadMult * g_spreadEMA;
   int best = nlad - 1; // fallback: slowest ladder step
   for(int i = 0; i < nlad; i++)
     {
      double r = AvgBarRange(ladder[i], 100);
      if(r <= 0.0) continue; // no data for this TF yet: skip
      if(r >= need) { best = i; break; } // fastest TF that clears the cost floor
     }

   if(best > cur)                                    // too noisy/costly: step up now
      ApplyTimeframe(ladder[best]);
   else if(best < cur)                               // faster TF viable: step down
     {                                               // only with a 30% margin (hysteresis)
      double r = AvgBarRange(ladder[best], 100);
      if(r >= 1.3 * need) ApplyTimeframe(ladder[best]);
     }
  }

//+------------------------------------------------------------------+
//| Regime / pitch (packet: decision 1 - WIDEN in range)             |
//| Recomputed once per closed bar of the working timeframe.         |
//+------------------------------------------------------------------+
double EfficiencyRatio()
  {
   int n = MathMax(2, InpERPeriod);
   double num = MathAbs(iClose(_Symbol, g_tf, 1) - iClose(_Symbol, g_tf, n));
   double den = 0.0;
   for(int i = 1; i < n; i++)
      den += MathAbs(iClose(_Symbol, g_tf, i) - iClose(_Symbol, g_tf, i + 1));
   return(den > 0.0 ? num / den : 1.0);
  }

void UpdateRegimeAndPitch()
  {
   datetime bar = iTime(_Symbol, g_tf, 0);
   if(bar == g_regimeBar && g_pitchCache > 0.0) return;
   g_regimeBar = bar;

   double er = EfficiencyRatio();
   if(er < InpERRangeBelow)       g_rangeMode = true;   // range: widen pitch
   else if(er >= InpERTrendAbove) g_rangeMode = false;  // trend: normal pitch
   // in between: keep previous mode (hysteresis)

   double atr[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) == 1 && atr[0] > 0.0) g_atrCache = atr[0];

   // pitch floor: manual Delta_min and/or auto (multiple of the measured spread),
   // so the pitch can never sit inside the broker's cost band on any symbol
   double floorD = InpDeltaMin;
   if(InpAutoCalibrate && g_spreadEMA > 0.0)
      floorD = MathMax(floorD, InpPitchSpreadMult * g_spreadEMA);
   if(floorD <= 0.0) floorD = MathMax(MinStopDist(), 10.0 * _Point); // first ticks, no data yet

   double d = MathMax(floorD, InpAtrMult * g_atrCache);
   if(g_rangeMode) d *= InpRangeWiden;
   g_pitchCache = d;

   RecalcSizing();
  }

double PitchNow() { return(g_pitchCache > 0.0 ? g_pitchCache : MathMax(InpDeltaMin, 10.0 * _Point)); }

// reverse-stop trail distance for the active mode (price units)
double TrailDistance()
  {
   double d;
   if(InpTrailMode == TRAIL_ATR && g_atrCache > 0.0) d = InpTrailAtrMult * g_atrCache;
   else                                              d = InpRevDistMult * PitchNow();
   // never inside the broker's cost/stops band
   if(InpAutoCalibrate && g_spreadEMA > 0.0) d = MathMax(d, InpPitchSpreadMult * g_spreadEMA);
   return(MathMax(d, MinStopDist() + _Point));
  }

// churn-guard step: auto mode scales it to the symbol (fraction of ATR/spread)
double TrailStepNow()
  {
   if(!InpAutoCalibrate) return(InpTrailStep);
   double s = MathMax(0.10 * g_atrCache, 0.50 * g_spreadEMA);
   return(s > 0.0 ? s : InpTrailStep);
  }

//+------------------------------------------------------------------+
//| Regime gate (v1.40) - long-window ER on/off switch, causal        |
//| thresholds only. SEPARATE from EfficiencyRatio() above, which is  |
//| the short window (InpERPeriod) used for pitch widening only.      |
//+------------------------------------------------------------------+
int GateWindowBars()
  {
   int secPerBar = PeriodSeconds(g_tf);
   if(secPerBar <= 0) return(InpGateWindowMin);
   int bars = (int)MathRound(InpGateWindowMin * 60.0 / secPerBar);
   return(MathMax(bars, 10));
  }

double LongEfficiencyRatio(const int n)
  {
   if(n < 2) return(1.0);
   double num = MathAbs(iClose(_Symbol, g_tf, 1) - iClose(_Symbol, g_tf, n));
   double den = 0.0;
   for(int i = 1; i < n; i++)
      den += MathAbs(iClose(_Symbol, g_tf, i) - iClose(_Symbol, g_tf, i + 1));
   return(den > 0.0 ? num / den : 1.0);
  }

// linear-interpolated percentile (numpy.quantile default), ascending sort
double QuantileOf(double &arr[], const double q)
  {
   int n = ArraySize(arr);
   if(n == 0) return(0.0);
   if(n == 1) return(arr[0]);
   double a[]; ArrayResize(a, n); ArrayCopy(a, arr);
   ArraySort(a);
   double pos = q * (n - 1);
   int lo = (int)MathFloor(pos), hi = (int)MathCeil(pos);
   if(lo == hi) return(a[lo]);
   return(a[lo] + (a[hi] - a[lo]) * (pos - lo));
  }

// recompute thr_on/thr_off from the TRAILING InpGateTrainDays of history
// only (causal: nothing at or after "now" informs the thresholds)
void RecalibrateGateThresholds()
  {
   int windowBars = GateWindowBars();
   int secPerBar  = PeriodSeconds(g_tf);
   if(secPerBar <= 0) return;
   int trainBars = (int)MathRound(InpGateTrainDays * 24.0 * 3600.0 / secPerBar);
   int have  = Bars(_Symbol, g_tf);
   int total = MathMin(trainBars + windowBars + 5, have - 1);
   if(total < windowBars + 20) { g_gateThrOn = 0.0; return; } // not enough history yet

   // c[k] = close at shift (total-k): k=0 is the oldest bar in the window,
   // k=total-1 is shift=1 (the most recently closed bar) - ascending time,
   // built via iClose(shift) like the rest of this file (no CopyClose
   // series-direction ambiguity to worry about)
   double c[]; ArrayResize(c, total);
   for(int k = 0; k < total; k++)
      c[k] = iClose(_Symbol, g_tf, total - k);

   double csum[]; ArrayResize(csum, total);
   csum[0] = 0.0;
   for(int i = 1; i < total; i++)
      csum[i] = csum[i - 1] + MathAbs(c[i] - c[i - 1]);

   double sample[]; ArrayResize(sample, total - windowBars);
   for(int i = windowBars; i < total; i++)
     {
      double num = MathAbs(c[i] - c[i - windowBars]);
      double den = csum[i] - csum[i - windowBars];
      sample[i - windowBars] = (den > 0.0) ? num / den : 1.0;
     }
   if(ArraySize(sample) < 20) { g_gateThrOn = 0.0; return; }

   g_gateThrOn  = QuantileOf(sample, InpGateQOn);
   g_gateThrOff = QuantileOf(sample, MathMax(InpGateQOn - InpGateQGap, 0.0));
   Print("BTR: regime gate recalibrated - window=", windowBars, " bars (",
         DoubleToString(windowBars * secPerBar / 3600.0, 1), "h)  train=", ArraySize(sample),
         " samples  thr_on=", DoubleToString(g_gateThrOn, 4),
         "  thr_off=", DoubleToString(g_gateThrOff, 4));
  }

// updates g_gateOn every tick (hysteresis); recalibrates thresholds and the
// long-window ER reading only as often as needed (cheap on every other tick)
void UpdateRegimeGate()
  {
   if(!InpUseRegimeGate) { g_gateOn = true; return; }

   datetime bar = iTime(_Symbol, g_tf, 0);
   if(bar != g_gateErBar)
     {
      g_gateErBar = bar;
      g_gateErNow = LongEfficiencyRatio(GateWindowBars());
     }
   if(TimeCurrent() >= g_gateNextRecalc)
     {
      RecalibrateGateThresholds();
      g_gateNextRecalc = TimeCurrent() + (datetime)(InpGateRecalcDays * 24 * 3600);
     }

   if(g_gateThrOn <= 0.0) { g_gateOn = true; return; } // not calibrated yet: stay permissive
   if(g_gateErNow >= g_gateThrOn)       g_gateOn = true;
   else if(g_gateErNow < g_gateThrOff)  g_gateOn = false;
   // else: inside the hysteresis band - keep the previous g_gateOn
  }

// returns true when the regime gate owns this tick (flattened and sitting out)
bool HandleRegimeGate()
  {
   UpdateRegimeGate();
   if(g_gateOn)
     {
      if(g_state == ST_GATE_OFF) // gate just turned back on: resume from flat
        {
         g_dir = 0;
         ResetFlatTrackers();
         g_state = ST_FLAT;
         SaveState();
        }
      return(false);
     }
   if(g_state != ST_GATE_OFF)
     {
      Print("BTR: regime gate OFF (ER=", DoubleToString(g_gateErNow, 4), " < thr_off=",
            DoubleToString(g_gateThrOff, 4), ") - flattening and sitting out.");
      g_state = ST_GATE_OFF;
      SaveState();
     }
   if(CountPos(InpMagic, -1) + CountPos(InpMagicLock, -1) > 0 || PendingCount(-1) > 0)
      if(OpsAllowed()) CloseEverything();
   return(true);
  }

//+------------------------------------------------------------------+
//| Leverage / margin auto-sizing (per bar)                          |
//| Lot from equity risk-per-flip; stack cap from margin + leverage. |
//+------------------------------------------------------------------+
void RecalcSizing()
  {
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);

   // --- lot: manual, or sized so one false flip costs ~InpRiskPctPerFlip% of equity
   double lot = InpLot;
   if(InpAutoLot)
     {
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double perUnit  = (tickSize > 0.0) ? tickVal / tickSize : 0.0; // ccy per 1.0 price unit per lot
      double dist     = TrailDistance() + g_spreadEMA;               // adverse move of one flip
      if(perUnit > 0.0 && dist > 0.0 && eq > 0.0)
         lot = (eq * InpRiskPctPerFlip / 100.0) / (dist * perUnit);
      else
         lot = vmin;
     }
   lot = NormVol(lot);

   // --- stack cap: full stack margin must fit the leverage the broker gives us
   int nmax = InpNMax;
   double perLotMargin = 0.0;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask > 0.0 && OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, perLotMargin) && perLotMargin > 0.0)
     {
      double allowed   = eq * InpMaxMarginUsePct / 100.0;
      double maxLots   = allowed / perLotMargin;      // total lots the cap allows
      if(lot * nmax > maxLots)
        {
         nmax = (int)MathFloor(maxLots / lot);
         if(nmax < 1 && InpAutoLot)
           {
            // shrink the lot instead of dropping below one level
            lot  = NormVol(maxLots / InpNMax);
            nmax = (lot >= vmin && lot > 0.0) ? (int)MathFloor(maxLots / lot) : 0;
           }
         nmax = MathMax(nmax, 0);
        }
     }
   g_effLot  = MathMax(lot, 0.0);
   g_effNMax = MathMin(nmax, InpNMax);
  }

double EffLot()  { return(g_effLot  > 0.0 ? g_effLot  : NormVol(InpLot)); }
int    EffNMax() { return(g_effNMax > 0   ? g_effNMax : 0); }

double Velocity()
  {
   int tau = MathMax(1, InpSpikeLookback);
   double now  = iClose(_Symbol, g_tf, 0);
   double past = iClose(_Symbol, g_tf, tau);
   if(now == 0.0 || past == 0.0) return(0.0);
   return((now - past) / tau); // signed: + = up, - = down
  }

// spike thresholds: ATR-scaled in auto mode so they work on any symbol,
// fixed price units in manual mode (BOOM-style)
double EffSpikeVel()
  {
   if(InpAutoCalibrate && g_atrCache > 0.0) return(InpSpikeAtrMult * g_atrCache);
   return(InpSpikeMaxVel);
  }

double EffCalmVel()
  {
   if(InpAutoCalibrate && g_atrCache > 0.0) return(InpCalmAtrMult * g_atrCache);
   return(InpCalmVel);
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
   if(MathAbs(target - cur) < TrailStepNow()) return; // churn guard
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
//| A window is either a manual HH:MM-HH:MM range or an MQL5         |
//| economic-calendar event (v1.30) within pre/post minutes.         |
//+------------------------------------------------------------------+
bool InManualWindow()
  {
   if(StringLen(InpNewsWindows) == 0) return(false);
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

//+------------------------------------------------------------------+
//| MQL5 economic calendar (v1.30)                                   |
//| Caches upcoming event times for the relevant currencies. NOTE:   |
//| the calendar API returns nothing in the Strategy Tester and      |
//| needs a connected terminal - the EA degrades to manual windows   |
//| and logs one warning in that case.                               |
//+------------------------------------------------------------------+
void CalCurrencies(string &curs[])
  {
   string raw = InpCalCurrencies;
   StringTrimLeft(raw); StringTrimRight(raw);
   if(raw == "" || raw == "auto")
     {
      string base   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
      string profit = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
      string margin = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_MARGIN);
      ArrayResize(curs, 0);
      string cand[3]; cand[0] = base; cand[1] = profit; cand[2] = margin;
      for(int i = 0; i < 3; i++)
        {
         if(StringLen(cand[i]) != 3) continue; // XAU etc. have no calendar; USD/EUR/JPY do
         bool dup = false;
         for(int j = 0; j < ArraySize(curs); j++) if(curs[j] == cand[i]) dup = true;
         if(!dup) { int n = ArraySize(curs); ArrayResize(curs, n + 1); curs[n] = cand[i]; }
        }
      return;
     }
   StringSplit(raw, ',', curs);
   for(int i = 0; i < ArraySize(curs); i++)
     { StringTrimLeft(curs[i]); StringTrimRight(curs[i]); }
  }

void RefreshCalendar()
  {
   ArrayResize(g_calEvents, 0);
   string curs[];
   CalCurrencies(curs);
   if(ArraySize(curs) == 0) return;

   datetime from = TimeTradeServer() - (datetime)(InpCalPostMin * 60);
   datetime to   = TimeTradeServer() + 48 * 3600;

   for(int c = 0; c < ArraySize(curs); c++)
     {
      MqlCalendarValue vals[];
      ResetLastError();
      if(!CalendarValueHistory(vals, from, to, NULL, curs[c]))
        {
         if(!g_calWarned)
           {
            Print("BTR: calendar unavailable for '", curs[c], "' (err ", GetLastError(),
                  ") - tester or disconnected terminal? Manual windows only.");
            g_calWarned = true;
           }
         continue;
        }
      for(int i = 0; i < ArraySize(vals); i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev)) continue;
         if(ev.importance < InpCalMinImportance) continue;
         int n = ArraySize(g_calEvents);
         ArrayResize(g_calEvents, n + 1);
         g_calEvents[n] = vals[i].time; // server time per the calendar contract
        }
     }
  }

bool InCalendarWindow()
  {
   if(!InpUseCalendar) return(false);
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(g_calEvents); i++)
      if(now >= g_calEvents[i] - InpCalPreMin * 60 &&
         now <= g_calEvents[i] + InpCalPostMin * 60) return(true);
   return(false);
  }

// minutes until the next cached event (-1 when none within the cache)
int NextCalEventMin()
  {
   datetime now = TimeTradeServer(); datetime best = 0;
   for(int i = 0; i < ArraySize(g_calEvents); i++)
      if(g_calEvents[i] > now && (best == 0 || g_calEvents[i] < best)) best = g_calEvents[i];
   return(best == 0 ? -1 : (int)((best - now) / 60));
  }

bool InNewsWindow()
  {
   if(InpNewsMode == NEWS_OFF) return(false);
   return(InManualWindow() || InCalendarWindow());
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
         g_legExt  = g_lastAdd;
         DeletePendings();
         g_state = ST_RIDE;
        }
      else { g_dir = 0; ResetFlatTrackers(); g_state = ST_FLAT; }
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
      PlaceOrMoveStop(ORDER_TYPE_BUY_STOP,  NormalizeDouble(ask + d, _Digits), EffLot(), tag, false, 0);
   if(CountPos(InpMagic, POSITION_TYPE_SELL) == 0)
      PlaceOrMoveStop(ORDER_TYPE_SELL_STOP, NormalizeDouble(bid - d, _Digits), EffLot(), tag, false, 0);
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
      if(g_state == ST_HALT_DAY) { ResetFlatTrackers(); g_state = ST_FLAT; }
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

// reset per-leg / per-flat trackers when exposure ends
void ResetFlatTrackers()
  {
   g_flatHi     = 0.0;
   g_flatLo     = 0.0;
   g_trailLevel = 0.0;
   g_legExt     = 0.0;
  }

// true once per closed bar of the working timeframe (entry decisions only)
bool NewEntryBar()
  {
   datetime t = iTime(_Symbol, g_tf, 0);
   if(t == 0 || t == g_entryBar) return(false);
   g_entryBar = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| FLAT: seed the first position of a leg                           |
//| InpEntryOnClose=true (default): CLOSE-based - a bar must CLOSE   |
//| one pitch beyond the running extreme of closes since going flat; |
//| wicks never trigger anything.                                    |
//| InpEntryOnClose=false: video-style resting stop straddle         |
//| (fills on wicks by nature).                                      |
//+------------------------------------------------------------------+
void SeedRide(const int dir)
  {
   double lot = EffLot();
   ENUM_ORDER_TYPE ot = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!MarginForLot(ot, lot)) return;
   bool ok = (dir > 0) ? trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "BTR seed")
                       : trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "BTR seed");
   if(!ok) { Backoff("seed"); return; }
   double px = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   g_dir        = dir;
   g_lastAdd    = px;
   g_legExt     = px;
   g_trailLevel = 0.0;
   g_flatHi     = 0.0;
   g_flatLo     = 0.0;
   DeletePendings();
   g_state = ST_RIDE;
   SaveState();
  }

void ManageFlat()
  {
   int dir = NewestDir(); // a pending seed stop filled (stop-order mode)
   if(dir != 0)
     {
      g_dir        = dir;
      g_lastAdd    = ExtremeEntry(g_dir);
      g_legExt     = g_lastAdd; // new leg: reset the ATR-trail anchor
      g_trailLevel = 0.0;
      DeletePendings(); // leftover seed stop; the reverse arms in RIDE
      g_state      = ST_RIDE;
      SaveState();
      return;
     }
   if(EffNMax() < 1) return; // margin cap leaves no room for even one level

   if(InpEntryOnClose)
     {
      if(!NewEntryBar()) return;
      double c = iClose(_Symbol, g_tf, 1);
      if(c <= 0.0) return;
      double dpitch = PitchNow();
      // trigger on the extremes of PRIOR closes, then fold this close in
      bool seeded = false;
      if(CanAddExposure())
        {
         if(g_flatLo > 0.0 && c >= g_flatLo + dpitch)      { SeedRide(+1); seeded = true; }
         else if(g_flatHi > 0.0 && c <= g_flatHi - dpitch) { SeedRide(-1); seeded = true; }
        }
      if(!seeded)
        {
         if(g_flatHi <= 0.0 || c > g_flatHi) g_flatHi = c;
         if(g_flatLo <= 0.0 || c < g_flatLo) g_flatLo = c;
        }
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
      g_dir        = -g_dir;    // the fill is seed #1 of the new ride
      g_trailLevel = 0.0;
      g_state      = ST_FLIP;   // ST_FLIP closes the old stack, then resumes
      DeletePendings();
      SaveState();
      return;
     }

   if(CountPos(InpMagic, myType) == 0)
     { g_dir = 0; ResetFlatTrackers(); g_state = ST_FLAT; SaveState(); return; }

   double d   = PitchNow();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double px  = (g_dir > 0) ? bid : ask;

   // --- entry-bar gate: in close-confirmed mode all entry/flip/anchor
   //     decisions run once per closed bar on its CLOSE; wicks are ignored
   bool   barTurn  = (InpEntryOnClose || InpFlipMode == FLIP_ON_CLOSE) ? NewEntryBar() : false;
   double barClose = iClose(_Symbol, g_tf, 1);

   // --- track the best price of the leg (anchor for the ATR trail)
   if(InpEntryOnClose)
     {
      if(g_legExt <= 0.0) g_legExt = px;
      else if(barTurn && barClose > 0.0 &&
              ((g_dir > 0 && barClose > g_legExt) || (g_dir < 0 && barClose < g_legExt)))
         g_legExt = barClose; // closes only - wick extremes never tighten the trail
     }
   else
     {
      if(g_legExt <= 0.0) g_legExt = px;
      if((g_dir > 0 && px > g_legExt) || (g_dir < 0 && px < g_legExt)) g_legExt = px;
     }

   // --- delta lock on a velocity spike against the stack (decision 2)
   if(InpUseLock && CountPos(InpMagic, myType) >= InpMinStackToLock && OpsAllowed())
     {
      double v = Velocity();
      if(MathAbs(v) >= EffSpikeVel() && ((g_dir > 0 && v < 0.0) || (g_dir < 0 && v > 0.0)))
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

   bool   canStack = InpEntryOnClose
                     ? (barTurn && barClose > 0.0 &&
                        ((g_dir > 0 && barClose >= g_lastAdd + d) || (g_dir < 0 && barClose <= g_lastAdd - d)))
                     : ((g_dir > 0 && px >= g_lastAdd + d) || (g_dir < 0 && px <= g_lastAdd - d));

   // --- stack: one pitch of confirmed progress with the trend
   bool stackAllowed = !(g_rangeMode && InpRangeHaltStack);
   if(stackAllowed && CanAddExposure() && CountPos(InpMagic, myType) < EffNMax() && canStack)
     {
      ENUM_ORDER_TYPE ot = (g_dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double lot = EffLot();
      if(MarginForLot(ot, lot))
        {
         bool ok = (g_dir > 0) ? trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "BTR stack")
                               : trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "BTR stack");
         if(ok) { g_lastAdd = (InpEntryOnClose ? barClose : px); SaveState(); }
         else Backoff("stack");
        }
     }

   // --- optional per-position TP ladder (default OFF: pure SAR like the video)
   if(InpUsePerPosTP) ManagePerPosTP(d);

   // --- trail level: chandelier (k*ATR behind the leg's best price) or
   //     pitch-multiple; monotonically tighter, never loosened
   double dist   = TrailDistance();
   double anchor = (InpTrailMode == TRAIL_ATR && g_legExt > 0.0) ? g_legExt
                                                                 : ((g_dir > 0) ? bid : ask);
   double target = (g_dir > 0) ? NormalizeDouble(anchor - dist, _Digits)
                               : NormalizeDouble(anchor + dist, _Digits);
   if(g_trailLevel <= 0.0) g_trailLevel = target;
   else g_trailLevel = (g_dir > 0) ? MathMax(g_trailLevel, target) : MathMin(g_trailLevel, target);

   if(InpFlipMode == FLIP_ON_CLOSE)
     {
      // no resting order: flip only when a bar CLOSES beyond the trail level.
      // Wicks through the level do nothing; the velocity delta-lock remains
      // the fast guard against crashes between closes.
      DeletePendings(); // clear any leftover reverse stop (mode switch etc.)
      if(barTurn && barClose > 0.0 && OpsAllowed() &&
         ((g_dir > 0 && barClose <= g_trailLevel) || (g_dir < 0 && barClose >= g_trailLevel)))
        {
         double lot = EffLot();
         bool ok = (g_dir > 0) ? trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "BTR flip")
                               : trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "BTR flip");
         if(ok)
           {
            g_dir        = -g_dir;   // the fill is seed #1 of the new ride
            g_trailLevel = 0.0;
            g_state      = ST_FLIP;  // ST_FLIP banks the old stack
            SaveState();
           }
         else Backoff("flip");
        }
      return;
     }

   // FLIP_STOP_ORDER: video-style resting stop at the trail level
   double stopTgt = g_trailLevel;
   if(g_dir > 0) stopTgt = MathMin(stopTgt, NormalizeDouble(bid - MinStopDist() - _Point, _Digits));
   else          stopTgt = MathMax(stopTgt, NormalizeDouble(ask + MinStopDist() + _Point, _Digits));
   if(g_dir > 0) PlaceOrMoveStop(ORDER_TYPE_SELL_STOP, stopTgt, EffLot(), "BTR reverse", true, +1);
   else          PlaceOrMoveStop(ORDER_TYPE_BUY_STOP,  stopTgt, EffLot(), "BTR reverse", true, -1);
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
      if(MathAbs(PositionGetDouble(POSITION_TP) - tp) > TrailStepNow()) // churn guard
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
   if(CountPos(InpMagic, newType) == 0)
     { g_dir = 0; ResetFlatTrackers(); g_state = ST_FLAT; SaveState(); return; }
   g_lastAdd = ExtremeEntry(g_dir);
   g_legExt  = g_lastAdd; // new leg: reset the ATR-trail anchor
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
      if(CountPos(InpMagic, -1) > 0) { g_trailLevel = 0.0; g_legExt = 0.0; g_state = ST_RIDE; }
      else                           { g_dir = 0; ResetFlatTrackers(); g_state = ST_FLAT; }
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

   if(MathAbs(Velocity()) >= EffCalmVel()) return; // still moving fast: stay locked
   if(!OpsAllowed()) return;

   double px = (g_dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double d  = PitchNow();

   if((g_dir > 0 && px >= g_lockRef) || (g_dir < 0 && px <= g_lockRef))
     {
      // spike faded on the stack side: drop the hedge, keep riding
      ClosePositions(InpMagicLock, -1);
      g_lastAdd    = ExtremeEntry(g_dir);
      g_legExt     = px; // re-anchor the ATR trail at the post-spike price
      g_trailLevel = 0.0;
      g_state      = ST_RIDE;
      SaveState();
      return;
     }
   if((g_dir > 0 && px <= g_lockRef - d) || (g_dir < 0 && px >= g_lockRef + d))
     {
      // spike became the new leg: realize the old stack, reseed in the new regime
      ClosePositions(InpMagic, myType);
      ClosePositions(InpMagicLock, -1);
      g_dir   = 0;
      ResetFlatTrackers();
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
   ResetFlatTrackers();
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
      if(g_state != ST_HALT_DAY && g_state != ST_EMERGENCY)
        { g_state = ST_FLAT; g_dir = 0; ResetFlatTrackers(); }
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
   if(g_legExt <= 0.0) g_legExt = g_lastAdd;
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
      case ST_GATE_OFF:  return("GATE-OFF");
     }
   return("?");
  }

void ShowStatus()
  {
   if(!InpShowComment) return;
   string tfs = EnumToString(g_tf);
   StringReplace(tfs, "PERIOD_", "");
   string line = "BoomTrendRider v1.40 " + _Symbol + " " + tfs +
      "  |  " + StateName(g_state) + " " + (g_dir > 0 ? "LONG" : (g_dir < 0 ? "SHORT" : "-")) +
      "  |  stack " + IntegerToString(CountPos(InpMagic, (g_dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL)) +
      "/" + IntegerToString(EffNMax()) +
      "  lot " + DoubleToString(EffLot(), 2) +
      "  pitch " + DoubleToString(PitchNow(), _Digits) +
      (g_rangeMode ? " (RANGE x" + DoubleToString(InpRangeWiden, 1) + ")" : "") +
      "  |  trail " + (InpTrailMode == TRAIL_ATR ? "ATR " : "pitch ") + DoubleToString(TrailDistance(), _Digits) +
      "  |  spread " + DoubleToString(g_spreadEMA, _Digits) +
      "  lev 1:" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LEVERAGE)) +
      "  |  eq " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) +
      " (peak " + DoubleToString(g_eqPeak, 2) + ")";
   int nm = NextCalEventMin();
   if(nm >= 0 && nm <= 180) line += "  |  news in " + IntegerToString(nm) + "m";
   if(InpUseRegimeGate)
      line += "  |  gate " + (g_gateOn ? "ON" : "OFF") + " ER=" + DoubleToString(g_gateErNow, 3) +
              " (on>=" + DoubleToString(g_gateThrOn, 3) + " off<" + DoubleToString(g_gateThrOff, 3) + ")";
   Comment(line);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateSpreadStats();     // broker spread auto-detection (EMA)
   if(InpAutoTimeframe && TimeCurrent() >= g_tfNextReview)
     {
      SelectTimeframe();    // broker-adaptive working timeframe
      g_tfNextReview = TimeCurrent() + (datetime)(InpTfReviewMin * 60);
     }
   if(InpUseCalendar && InpNewsMode != NEWS_OFF && TimeCurrent() >= g_calNextRefresh)
     {
      RefreshCalendar();    // MQL5 economic calendar cache
      g_calNextRefresh = TimeCurrent() + (datetime)(InpCalRefreshMin * 60);
     }
   UpdateRegimeAndPitch();  // per-bar: regime, pitch, ATR, lot/N_max sizing

   if(HandleAccountRisk()) { ShowStatus(); return; } // KILLED / HALT-DAY own the tick
   if(HandleNews())        { ShowStatus(); return; } // news module owns the tick
   if(HandleRegimeGate())  { ShowStatus(); return; } // regime gate owns the tick (v1.40, opt-in)

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
