//+------------------------------------------------------------------+
//|                          BoomDeltaLockAIRecovery_v1_1.mq5         |
//|                        AMOS Level 50 - EA Factory (Layer 06)      |
//|                                                                  |
//|  Delta Lock & AI Recovery Engine (spec v1.1). Implements         |
//|  docs/inbox/boom_delta_lock_ai_recovery.md for Deriv BOOM_100.   |
//|                                                                  |
//|  SKELETON: deterministic logic (grid, equal-volume delta lock,   |
//|  lock verify, recovery basket, finite-risk caps, emergency) is   |
//|  implemented; the AI direction model is a SAFE STUB - with no     |
//|  trained ONNX model it always returns RANGE/WAIT, so no recovery  |
//|  trades are taken. NOT deployable: gated on v0 Phase C validation |
//|  AND a validated model, plus Monte Carlo P10 and human approval   |
//|  (Rules 3/4/7, Layer 12). Prices are in index price units.       |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>

//--- AI direction classes (section 7)
#define AI_RANGE 0
#define AI_UP    1
#define AI_DOWN  2

//--- runtime state machine (section 17)
enum ENUM_ENGINE_STATE
  {
   ST_IDLE = 0,
   ST_SELL_DRIFT,
   ST_SELL_PYRAMID,
   ST_SPIKE_WARNING,
   ST_BUY_STOP_TRIGGER,
   ST_DELTA_LOCK,
   ST_LOCK_VERIFY,
   ST_AI_WAIT,
   ST_DOWN_RECOVERY,
   ST_UP_RECOVERY,
   ST_TARGET_REACHED,
   ST_CLOSE_ALL,
   ST_COOLDOWN,
   ST_EMERGENCY
  };

input group "Phase A - Drift grid (sections 3-4)"
input double InpDelta          = 50.0;  // Delta: grid pitch (index price units)
input double InpLot            = 0.01;  // equal lot per SELL (no martingale)
input int    InpNMax           = 10;    // max concurrent SELL positions
input double InpBuyStopDist     = 50.0; // d_bs: BUY STOP distance (price units)

input group "Spike detection (section 2/17)"
input int    InpSpikeLookback  = 5;     // tau bars
input double InpSpikeMaxVel    = 40.0;  // v_max: price units per bar

input group "Recovery (sections 8-14)"
input double InpRecoveryMult   = 0.50;  // RecoveryLot <= mult * LockedLot
input double InpConfidence     = 0.68;  // confidence gate
input double InpProbGap        = 0.20;  // Pmax - Psecond gate
input double InpRecoveryDDpct  = 1.0;   // max recovery drawdown, % of equity
input int    InpTauMaxSec      = 3600;  // max recovery time (seconds)
input double InpSafetyBuffer   = 0.50;  // SafetyBuffer added to CloseCost (account ccy)

input group "Hard risk (sections 15-16; AI cannot change)"
input double InpMinMarginLevel = 800.0; // min margin level %
input int    InpMaxSpreadPts   = 0;     // max spread in points (0 = disabled)

input group "AI model (section 7; SAFE STUB until a model exists)"
input bool   InpUseONNX        = false; // enable ONNX inference (needs a model)
input string InpOnnxModelFile  = "";    // model file under MQL5/Files

input group "Misc"
input long   InpMagicBase      = 550110; // base / lock basket magic
input long   InpMagicRecovery  = 550111; // recovery basket magic
input int    InpSlippage       = 10;     // deviation in points

CTrade            trade;
ENUM_ENGINE_STATE g_state       = ST_IDLE;
long              g_onnx        = INVALID_HANDLE;
double            g_lockedLot   = 0.0;   // total SELL lot captured at lock
double            g_recStartEq  = 0.0;   // equity at recovery start
datetime          g_recStart    = 0;     // recovery start time
double            g_recPeak     = 0.0;   // recovery basket peak PnL
datetime          g_cooldownEnd = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpUseONNX && StringLen(InpOnnxModelFile) > 0)
     {
      g_onnx = OnnxCreate(InpOnnxModelFile, ONNX_DEFAULT);
      if(g_onnx == INVALID_HANDLE)
         Print("ONNX model not loaded ('", InpOnnxModelFile, "') - AI recovery stays in safe WAIT.");
     }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_onnx != INVALID_HANDLE) OnnxRelease(g_onnx);
  }

//+------------------------------------------------------------------+
//| Position / order helpers (filtered by magic)                     |
//+------------------------------------------------------------------+
bool Owned(const long magic, const string sym){ return(sym == _Symbol && (magic == InpMagicBase || magic == InpMagicRecovery)); }

double SideLot(const long magic, const ENUM_POSITION_TYPE type)
  {
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) == type) v += PositionGetDouble(POSITION_VOLUME);
     }
   return(v);
  }

int SideCount(const long magic, const ENUM_POSITION_TYPE type)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) == type) n++;
     }
   return(n);
  }

double LowestSellEntry(const long magic)
  {
   double lo = 0.0; bool f = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!f || e < lo){ lo = e; f = true; }
     }
   return(f ? lo : 0.0);
  }

double HighestBuyEntry(const long magic)
  {
   double hi = 0.0; bool f = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!f || e > hi){ hi = e; f = true; }
     }
   return(f ? hi : 0.0);
  }

double BasketProfit(const long magic)
  {
   double p = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return(p);
  }

int PendingCount(const long magic, const ENUM_ORDER_TYPE type)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_TYPE) == type) n++;
     }
   return(n);
  }

void DeletePendings(const long magic)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      trade.OrderDelete(t);
     }
  }

void CloseByMagic(const long magic)
  {
   trade.SetExpertMagicNumber(magic);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      trade.PositionClose(t);
     }
   DeletePendings(magic);
  }

void CloseEverything()
  {
   CloseByMagic(InpMagicRecovery);
   CloseByMagic(InpMagicBase);
  }

double MinStopDist(){ return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point); }
double SpreadPts(){ return((SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID)) / _Point); }
double MarginLevel(){ return(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)); }

bool SpikeUp()
  {
   int tau = MathMax(1, InpSpikeLookback);
   double now = iClose(_Symbol, PERIOD_CURRENT, 0);
   double past = iClose(_Symbol, PERIOD_CURRENT, tau);
   if(now == 0.0 || past == 0.0) return(false);
   return((now - past) / tau >= InpSpikeMaxVel);   // upward velocity only
  }

// Approximate cost to unwind everything (section 13). Conservative estimate.
double CloseCost()
  {
   int totalPos = SideCount(InpMagicBase,POSITION_TYPE_SELL) + SideCount(InpMagicBase,POSITION_TYPE_BUY)
                + SideCount(InpMagicRecovery,POSITION_TYPE_SELL) + SideCount(InpMagicRecovery,POSITION_TYPE_BUY);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double spreadCostPerPos = SpreadPts() * tickVal * (InpLot / SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   return(totalPos * spreadCostPerPos + InpSafetyBuffer);
  }

//+------------------------------------------------------------------+
//| Phase A: SELL pyramid + equal-volume dynamic BUY STOP            |
//+------------------------------------------------------------------+
void ManageDriftGrid()
  {
   int k = SideCount(InpMagicBase, POSITION_TYPE_SELL);
   trade.SetExpertMagicNumber(InpMagicBase);

   // add a SELL STOP one Delta below (unless spiking / capped / already armed)
   if(!SpikeUp() && k < InpNMax && PendingCount(InpMagicBase, ORDER_TYPE_SELL_STOP) == 0)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ref = (k > 0) ? LowestSellEntry(InpMagicBase) : bid;
      double lvl = NormalizeDouble(ref - InpDelta, _Digits);
      if(bid - lvl < MinStopDist()) lvl = NormalizeDouble(bid - MinStopDist() - _Point, _Digits);
      trade.SellStop(InpLot, lvl, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BDL grid");
     }

   // dynamic equal-volume BUY STOP: lot = total SELL lot, always re-placed on top
   double sellLot = SideLot(InpMagicBase, POSITION_TYPE_SELL);
   if(sellLot > 0.0)
     {
      DeletePendings(InpMagicBase); // clears the SELL STOP too; it re-arms next tick
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lvl = NormalizeDouble(ask + InpBuyStopDist, _Digits);
      if(lvl - ask < MinStopDist()) lvl = NormalizeDouble(ask + MinStopDist() + _Point, _Digits);
      trade.BuyStop(sellLot, lvl, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BDL hedge");
     }
  }

//+------------------------------------------------------------------+
//| Lock verify (section 6): BUY total == SELL total within +/-0.01  |
//+------------------------------------------------------------------+
bool LockValid()
  {
   double s = SideLot(InpMagicBase, POSITION_TYPE_SELL);
   double b = SideLot(InpMagicBase, POSITION_TYPE_BUY);
   return(MathAbs(b - s) <= 0.01 + 1e-9);
  }

//+------------------------------------------------------------------+
//| AI prediction (section 7) - SAFE STUB                            |
//| Returns dir + probabilities. With no model, returns RANGE with   |
//| zero confidence so the gate always yields WAIT.                  |
//+------------------------------------------------------------------+
struct AISignal { int dir; double pmax; double psecond; };

AISignal AIPredict()
  {
   AISignal s; s.dir = AI_RANGE; s.pmax = 0.0; s.psecond = 0.0;
   if(g_onnx == INVALID_HANDLE) return(s);   // no model -> safe WAIT

   // TODO(model): assemble the section-7 feature vector (ATR, tick velocity,
   // spread, EMA slope, ADX, RSI, MSS, BOS, displacement, liquidity sweep,
   // FVG, Vegas, spike age, distance-from-high), run OnnxRun with the model's
   // real input/output tensor shapes, then fill dir/pmax/psecond from the
   // output probabilities. Left unimplemented on purpose until a validated
   // model exists (no fabricated inference).
   return(s);
  }

bool ConfidencePass(const AISignal &s)
  {
   return(s.pmax >= InpConfidence && (s.pmax - s.psecond) >= InpProbGap);
  }

//+------------------------------------------------------------------+
//| Recovery basket (sections 9-14) in a separate magic              |
//+------------------------------------------------------------------+
double RecoveryLotCap(){ return(InpRecoveryMult * g_lockedLot); }

void AddRecovery(const bool isBuy)
  {
   double curLot = SideLot(InpMagicRecovery, POSITION_TYPE_BUY) + SideLot(InpMagicRecovery, POSITION_TYPE_SELL);
   if(curLot + InpLot > RecoveryLotCap() + 1e-9) return; // finite lot cap (section 14)

   trade.SetExpertMagicNumber(InpMagicRecovery);
   if(isBuy)
     {
      int n = SideCount(InpMagicRecovery, POSITION_TYPE_BUY);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double ref = (n > 0) ? HighestBuyEntry(InpMagicRecovery) : ask;
      if(n == 0 || ask >= ref + InpDelta) trade.Buy(InpLot, _Symbol, 0.0, 0.0, 0.0, "BDL rec UP");
     }
   else
     {
      int n = SideCount(InpMagicRecovery, POSITION_TYPE_SELL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ref = (n > 0) ? LowestSellEntry(InpMagicRecovery) : bid;
      if(n == 0 || bid <= ref - InpDelta) trade.Sell(InpLot, _Symbol, 0.0, 0.0, 0.0, "BDL rec DOWN");
     }
  }

// recovery hit its DD or time cap (section 14)
bool RecoveryExhausted()
  {
   if(g_recStart > 0 && (TimeCurrent() - g_recStart) >= InpTauMaxSec) return(true);
   double dd = g_recStartEq - AccountInfoDouble(ACCOUNT_EQUITY);
   if(dd >= g_recStartEq * (InpRecoveryDDpct / 100.0)) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Emergency checks (section 18)                                    |
//+------------------------------------------------------------------+
bool EmergencyCondition()
  {
   if(MarginLevel() > 0.0 && MarginLevel() < InpMinMarginLevel) return(true);
   if(InpMaxSpreadPts > 0 && SpreadPts() > InpMaxSpreadPts) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| State machine (section 17)                                       |
//+------------------------------------------------------------------+
void OnTick()
  {
   // global guards first
   if(g_state != ST_EMERGENCY && g_state != ST_IDLE && g_state != ST_COOLDOWN && EmergencyCondition())
     { g_state = ST_EMERGENCY; }

   switch(g_state)
     {
      case ST_IDLE:
        {
         if(TimeCurrent() < g_cooldownEnd) break;
         ManageDriftGrid();
         if(SideCount(InpMagicBase, POSITION_TYPE_SELL) > 0) g_state = ST_SELL_DRIFT;
         break;
        }
      case ST_SELL_DRIFT:
      case ST_SELL_PYRAMID:
        {
         ManageDriftGrid();
         g_state = (SideCount(InpMagicBase, POSITION_TYPE_SELL) > 1) ? ST_SELL_PYRAMID : ST_SELL_DRIFT;
         if(SpikeUp()) g_state = ST_SPIKE_WARNING;
         // BUY STOP fill => net exposure builds a BUY leg => go verify the lock
         if(SideLot(InpMagicBase, POSITION_TYPE_BUY) > 0.0) g_state = ST_BUY_STOP_TRIGGER;
         break;
        }
      case ST_SPIKE_WARNING:
        {
         // stop adding SELLs; keep the equal-volume hedge armed
         ManageDriftGrid();
         if(SideLot(InpMagicBase, POSITION_TYPE_BUY) > 0.0) g_state = ST_BUY_STOP_TRIGGER;
         else if(!SpikeUp()) g_state = ST_SELL_DRIFT;
         break;
        }
      case ST_BUY_STOP_TRIGGER:
        {
         g_lockedLot = SideLot(InpMagicBase, POSITION_TYPE_SELL);
         g_state = ST_DELTA_LOCK;
         break;
        }
      case ST_DELTA_LOCK:
        {
         DeletePendings(InpMagicBase); // no more pendings once locked
         g_state = ST_LOCK_VERIFY;
         break;
        }
      case ST_LOCK_VERIFY:
        {
         if(!LockValid()) { g_state = ST_EMERGENCY; break; }
         g_recStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
         g_recStart   = TimeCurrent();
         g_recPeak    = 0.0;
         g_state = ST_AI_WAIT;
         break;
        }
      case ST_AI_WAIT:
        {
         AISignal s = AIPredict();
         if(!ConfidencePass(s)) break; // WAIT (this is where the stub always lands)
         if(s.dir == AI_DOWN) g_state = ST_DOWN_RECOVERY;
         else if(s.dir == AI_UP) g_state = ST_UP_RECOVERY;
         // RANGE => keep waiting
         break;
        }
      case ST_DOWN_RECOVERY:
      case ST_UP_RECOVERY:
        {
         AddRecovery(g_state == ST_UP_RECOVERY);
         double total = BasketProfit(InpMagicBase) + BasketProfit(InpMagicRecovery);
         if(total >= CloseCost() + InpSafetyBuffer) { g_state = ST_TARGET_REACHED; break; }
         if(RecoveryExhausted()) { g_state = ST_CLOSE_ALL; break; }
         // re-evaluate AI; if it flips to the opposite high-confidence call, hand back to wait
         AISignal s = AIPredict();
         if(ConfidencePass(s))
           {
            if(s.dir == AI_UP && g_state == ST_DOWN_RECOVERY) g_state = ST_AI_WAIT;
            if(s.dir == AI_DOWN && g_state == ST_UP_RECOVERY) g_state = ST_AI_WAIT;
           }
         break;
        }
      case ST_TARGET_REACHED:
        {
         g_state = ST_CLOSE_ALL;
         break;
        }
      case ST_CLOSE_ALL:
        {
         CloseEverything();
         if(SideCount(InpMagicBase,POSITION_TYPE_SELL)+SideCount(InpMagicBase,POSITION_TYPE_BUY)
          + SideCount(InpMagicRecovery,POSITION_TYPE_SELL)+SideCount(InpMagicRecovery,POSITION_TYPE_BUY) == 0)
           {
            g_cooldownEnd = TimeCurrent() + 60;
            g_lockedLot = 0.0; g_recStart = 0; g_recStartEq = 0.0; g_recPeak = 0.0;
            g_state = ST_COOLDOWN;
           }
         break;
        }
      case ST_COOLDOWN:
        {
         if(TimeCurrent() >= g_cooldownEnd) g_state = ST_IDLE;
         break;
        }
      case ST_EMERGENCY:
        {
         CloseEverything();
         if(PositionsTotal() == 0 && OrdersTotal() == 0)
           { g_cooldownEnd = TimeCurrent() + 300; g_state = ST_COOLDOWN; }
         break;
        }
     }
  }
//+------------------------------------------------------------------+
