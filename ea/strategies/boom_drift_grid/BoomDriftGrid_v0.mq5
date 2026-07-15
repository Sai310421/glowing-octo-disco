//+------------------------------------------------------------------+
//|                                          BoomDriftGrid_v0.mq5     |
//|                        AMOS Level 50 - EA Factory (Layer 06)      |
//|                                                                  |
//|  Reactive, drift-biased SELL grid + BUY STOP reverse hedge for   |
//|  Deriv BOOM_100 (M1). Implements docs/inbox/boom_drift_grid.md.  |
//|                                                                  |
//|  v0 has NO stop-loss by design (section 6). NOT deployable until |
//|  Phase C validation passes (Monte Carlo P10, Rules 3/4) and a    |
//|  human approves (Layer 12). Prices are handled in index price    |
//|  units (the units shown on the chart), matching the spec's "pt". |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "0.10"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_EXIT_MODE
  {
   EXIT_A_PER_POSITION_TP = 0, // A: per-position TP (entry - c_tp*Delta)
   EXIT_B_BASKET_TP       = 1, // B: basket TP (close all at Pi_tgt)
   EXIT_C_TRAILING_BASKET = 2  // C: trailing basket (give back c_tr of peak)
  };

input group "Grid (section 3)"
input double InpDelta         = 50.0;  // Delta: grid pitch, index price units
input double InpLot           = 0.01;  // L: fixed lot per level (no martingale)
input int    InpNMax          = 10;    // N_max: max concurrent SELL positions

input group "Reverse hedge (section 4)"
input bool   InpUseBuyHedge   = true;  // enable BUY STOP reverse hedge
input double InpBuyStopDist    = 50.0; // d_bs: BUY STOP distance (price units)

input group "Exit (section 5)"
input ENUM_EXIT_MODE InpExitMode = EXIT_B_BASKET_TP; // exit rule A/B/C
input double InpCtp           = 1.0;   // A: c_tp multiplier of Delta
input double InpBasketTgt     = 5.0;   // B: Pi_tgt basket target (account ccy)
input double InpCtr           = 0.5;   // C: trailing give-back fraction of peak

input group "Spike filter (section 8.2 preview; v0 default OFF)"
input bool   InpUseSpikeFilter = false; // halt new SELLs during an up-spike
input int    InpSpikeLookback  = 5;     // tau bars
input double InpSpikeMaxVel    = 40.0;  // v_max: price units per bar

input group "Misc"
input long   InpMagic         = 550100; // magic number
input int    InpSlippage      = 10;     // deviation in points

CTrade trade;
double g_peakBasket = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Ownership helper                                                 |
//+------------------------------------------------------------------+
bool IsMine(const long magic, const string sym)
  {
   return(magic == InpMagic && sym == _Symbol);
  }

int SellCount()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) n++;
     }
   return(n);
  }

int MyPositionCount()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(IsMine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) n++;
     }
   return(n);
  }

double LowestSellEntry()
  {
   double lo = 0.0; bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      double e = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!found || e < lo) { lo = e; found = true; }
     }
   return(found ? lo : 0.0);
  }

double BasketProfit()
  {
   double p = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      p += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return(p);
  }

int PendingCount(const ENUM_ORDER_TYPE type)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsMine((long)OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue;
      if(OrderGetInteger(ORDER_TYPE) == type) n++;
     }
   return(n);
  }

bool HasBuyPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) return(true);
     }
   return(false);
  }

void DeletePendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!IsMine((long)OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue;
      trade.OrderDelete(t);
     }
  }

void CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!IsMine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      trade.PositionClose(t);
     }
   DeletePendings();
   g_peakBasket = 0.0;
  }

double MinStopDist()
  {
   return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point);
  }

// section 8.2 preview: detect an up-spike and pause new SELL entries.
bool SpikeActive()
  {
   if(!InpUseSpikeFilter) return(false);
   int tau = MathMax(1, InpSpikeLookback);
   double now  = iClose(_Symbol, PERIOD_CURRENT, 0);
   double past = iClose(_Symbol, PERIOD_CURRENT, tau);
   if(now == 0.0 || past == 0.0) return(false);
   double vel = MathAbs(now - past) / tau;
   return(vel >= InpSpikeMaxVel);
  }

//+------------------------------------------------------------------+
//| Exit management (section 5)                                      |
//+------------------------------------------------------------------+
void ManageExit()
  {
   if(MyPositionCount() == 0) { g_peakBasket = 0.0; return; }

   if(InpExitMode == EXIT_A_PER_POSITION_TP)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(!IsMine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
         if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         double tp    = NormalizeDouble(entry - InpCtp * InpDelta, _Digits);
         if(MathAbs(PositionGetDouble(POSITION_TP) - tp) > _Point)
            trade.PositionModify(t, PositionGetDouble(POSITION_SL), tp);
        }
      return;
     }

   double pnl = BasketProfit();
   if(InpExitMode == EXIT_B_BASKET_TP)
     {
      if(pnl >= InpBasketTgt) CloseAll();
      return;
     }

   // EXIT_C_TRAILING_BASKET
   if(pnl > g_peakBasket) g_peakBasket = pnl;
   if(g_peakBasket > 0.0 && pnl <= g_peakBasket * (1.0 - InpCtr)) CloseAll();
  }

//+------------------------------------------------------------------+
//| SELL grid (section 3): arm the next SELL STOP one Delta lower     |
//+------------------------------------------------------------------+
void ManageSellGrid()
  {
   if(SpikeActive()) return;
   if(SellCount() >= InpNMax) return;
   if(PendingCount(ORDER_TYPE_SELL_STOP) > 0) return; // one armed at a time

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ref = (SellCount() > 0) ? LowestSellEntry() : bid;
   double level = NormalizeDouble(ref - InpDelta, _Digits);
   if(bid - level < MinStopDist())
      level = NormalizeDouble(bid - MinStopDist() - _Point, _Digits);

   trade.SellStop(InpLot, level, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BDG_v0 grid");
  }

//+------------------------------------------------------------------+
//| Reverse hedge (section 4): one BUY STOP while SELL-exposed        |
//+------------------------------------------------------------------+
void ManageBuyHedge()
  {
   if(!InpUseBuyHedge) return;
   if(SellCount() == 0) return;                    // hedge only when exposed
   if(PendingCount(ORDER_TYPE_BUY_STOP) > 0) return;
   if(HasBuyPosition()) return;                    // hedge already live

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double level = NormalizeDouble(ask + InpBuyStopDist, _Digits);
   if(level - ask < MinStopDist())
      level = NormalizeDouble(ask + MinStopDist() + _Point, _Digits);

   trade.BuyStop(InpLot, level, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BDG_v0 hedge");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageExit();
   ManageSellGrid();
   ManageBuyHedge();
  }
//+------------------------------------------------------------------+
