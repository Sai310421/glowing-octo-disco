//+------------------------------------------------------------------+
//|                                             CBSurvivor_v1.mq5     |
//|                        AMOS Level 50 - EA Factory (Layer 06)      |
//|                                                                  |
//|  Faithful reproduction of the "CB Survivor EA" per its manual     |
//|  (CB_Survivor_Manual.pdf): hedged nanpin grid whose profit       |
//|  engine is per-lot cashback (CB) volume, kept alive by four      |
//|  survival mechanisms:                                            |
//|    (1) BASKET   - combined BUY+SELL basket TP excluding "stuck"  |
//|                   positions (loss > StuckThreshold)              |
//|    (2) TailCut  - realized-profit POOL buys out the worst stuck  |
//|                   position when pool >= its loss                 |
//|    (3) ReverseGrid - counter-side nanpin chain that refills the  |
//|                   pool once the main side exceeds TriggerCount   |
//|    (4) SlotFree - at MaxPositions, force-close the newest pos    |
//|                   (TriggerA distance / gap, TriggerB rotation    |
//|                   stagnation) to keep the grid breathing         |
//|  plus BulkClear (equity >= base + target => flatten) and an      |
//|  on-chart panel with the manual's buttons and CB accounting.     |
//|                                                                  |
//|  Items the manual does NOT specify, implemented as flagged       |
//|  assumptions (see README): initial seeding (1 BUY + 1 SELL),     |
//|  reverse-grid TP unit, reverse-grid dissolve rule, TriggerA/B    |
//|  OR-combination, pool consumption sign on TailCut.               |
//|                                                                  |
//|  NOT deployable until demo-tested (manual's own warning) and     |
//|  Phase C validated (Rules 3/7). Nanpin grids carry unbounded     |
//|  tail risk: the pool/BulkClear soften but do NOT remove it.      |
//|  "pips" here = 10 * _Point (XAUUSD 2-digit: 1 pip = $0.10).      |
//+------------------------------------------------------------------+
#property copyright "MSS Group / AMOS"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_WEEKEND_ACTION { ACTION_NONE = 0, CLOSE_ALL_WE };

input group "EA basic (manual section 2)"
input long   InpMagic            = 55555; // MagicNumber (main grid)
input double InpBaseLot          = 0.01;  // BaseLotSize
input double InpNanpinPips       = 25;    // NanpinPips: adverse distance between adds
input int    InpMaxPositions     = 25;    // MaxPositions per side

input group "Basket TP (section 3)"
input double InpNormalProfit     = 3.3;   // NormalProfit USD (rec. XAUUSD: 1.0)
input double InpStuckThreshold   = 3.3;   // StuckThreshold USD: loss beyond => stuck

input group "Nanpin lot multiplier (section 7)"
input int    InpNanpinLotFrom    = 20;    // apply multiplier from this level on
input double InpNanpinLotMult    = 1.0;   // lot multiplier (rec. XAUUSD: 2.0)

input group "BulkClear (section 8)"
input double InpBulkClearProfit  = 10.0;  // equity >= base + this => flatten all
input bool   InpAutoStopAfterClear = false;

input group "SlotFree / Offset2 (section 6)"
input double InpOffset2ExtraPips = 75;    // TriggerA: newest-entry distance (rec. 50)
input double InpOffset2GapPips   = 125;   // gap newest-2nd => close one extra (rec. 100)
input int    InpOffset2Cooldown  = 5;     // seconds between firings
input double InpRotationWindowH  = 1.0;   // TriggerB observation window (hours)
input double InpRotationThreshold = 70.0; // % of previous window's closes => stagnation

input group "ReverseGrid (section 5)"
input bool   InpEnableReverseGrid = true;
input int    InpRevTriggerCount  = 25;    // main-side count to activate (rec. 10)
input double InpRevNanpinMult    = 1.5;   // reverse nanpin interval = NanpinPips * this
input double InpRevTPPerBaseLot  = 1.0;   // ASSUMPTION: reverse per-pos TP, USD per BaseLot

input group "Weekend (section 9)"
input ENUM_WEEKEND_ACTION InpWeekendAction = ACTION_NONE;

input group "Panel / CB (section 10)"
input double InpCBPerLot         = 5.0;   // cashback USD per 1.0 lot traded (rec. 15.0)
input bool   InpShowPanel        = true;

input group "Misc"
input long   InpMagicReverse     = 55556; // reverse-grid magic (kept separate)
input int    InpSlippage         = 20;

CTrade  trade;
bool    g_auto      = true;
bool    g_basket    = true;   // (1) combined basket mode (manual recommends ON)
bool    g_tailcut   = true;   // (2)
bool    g_slotfree  = true;   // (4)
double  g_pool      = 0.0;    // realized-profit pool
datetime g_poolNegSince = 0;
double  g_baseEquity = 0.0;   // BulkClear reference (SYNC BAL)
double  g_cbLots    = 0.0;    // cumulative closed volume for CB accounting
double  g_dayProfit = 0.0;
int     g_dayStamp  = 0;
datetime g_lastSlotFree = 0;
datetime g_closeTimes[];      // realized-close timestamps for TriggerB

#define PIP (10.0 * _Point)

string GV(const string k) { return(StringFormat("CBS_%d_%s", (int)InpMagic, k)); }

void SaveState()
  {
   GlobalVariableSet(GV("pool"), g_pool);
   GlobalVariableSet(GV("base"), g_baseEquity);
   GlobalVariableSet(GV("cb"), g_cbLots);
   GlobalVariableSet(GV("auto"), g_auto ? 1 : 0);
   GlobalVariableSet(GV("bask"), g_basket ? 1 : 0);
   GlobalVariableSet(GV("tail"), g_tailcut ? 1 : 0);
   GlobalVariableSet(GV("slot"), g_slotfree ? 1 : 0);
  }

void LoadState()
  {
   if(GlobalVariableCheck(GV("pool"))) g_pool = GlobalVariableGet(GV("pool"));
   if(GlobalVariableCheck(GV("base"))) g_baseEquity = GlobalVariableGet(GV("base"));
   if(GlobalVariableCheck(GV("cb")))   g_cbLots = GlobalVariableGet(GV("cb"));
   if(GlobalVariableCheck(GV("auto"))) g_auto = GlobalVariableGet(GV("auto")) > 0;
   if(GlobalVariableCheck(GV("bask"))) g_basket = GlobalVariableGet(GV("bask")) > 0;
   if(GlobalVariableCheck(GV("tail"))) g_tailcut = GlobalVariableGet(GV("tail")) > 0;
   if(GlobalVariableCheck(GV("slot"))) g_slotfree = GlobalVariableGet(GV("slot")) > 0;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpBaseLot <= 0 || InpNanpinPips <= 0 || InpMaxPositions < 1 ||
      InpNormalProfit <= 0 || InpStuckThreshold <= 0 || InpNanpinLotFrom < 1 ||
      InpNanpinLotMult < 1.0 || InpRevNanpinMult <= 0 || InpRevTriggerCount < 1 ||
      InpMagic == InpMagicReverse)
     {
      Print("CBS: invalid inputs.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   LoadState();
   if(g_baseEquity <= 0.0) g_baseEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpShowPanel) { EventSetTimer(1); DrawPanel(); }
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   SaveState();
   EventKillTimer();
   ObjectsDeleteAll(0, "CBS_");
  }

//+------------------------------------------------------------------+
//| Position helpers (magic+type filtered)                           |
//+------------------------------------------------------------------+
bool Mine(const long magic, const string sym, const long want)
  { return(magic == want && sym == _Symbol); }

int CountSide(const long magic, const int type)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!Mine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), magic)) continue;
      if(type >= 0 && (int)PositionGetInteger(POSITION_TYPE) != type) continue;
      n++;
     }
   return(n);
  }

double PosProfit(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return(0.0);
   return(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
  }

// newest / 2nd-newest entry of a side (by POSITION_TIME)
void NewestTwo(const long magic, const int type, ulong &t1, ulong &t2)
  {
   datetime best1 = 0, best2 = 0;
   t1 = t2 = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!Mine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), magic)) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
      if(ot >= best1) { best2 = best1; t2 = t1; best1 = ot; t1 = t; }
      else if(ot >= best2) { best2 = ot; t2 = t; }
     }
  }

double LastEntryPrice(const long magic, const int type)
  {
   ulong t1, t2;
   NewestTwo(magic, type, t1, t2);
   if(t1 == 0) return(0.0);
   PositionSelectByTicket(t1);
   return(PositionGetDouble(POSITION_PRICE_OPEN));
  }

// realized close with pool + CB + rotation bookkeeping
bool ClosePos(const ulong ticket, const string why)
  {
   if(!PositionSelectByTicket(ticket)) return(false);
   double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   double vol = PositionGetDouble(POSITION_VOLUME);
   if(!trade.PositionClose(ticket)) { Print("CBS: close failed (", why, ") ", trade.ResultRetcodeDescription()); return(false); }
   g_pool += profit;                      // ALL realized PnL feeds the pool (section 4)
   g_cbLots += vol;
   g_dayProfit += profit;
   int n = ArraySize(g_closeTimes);
   ArrayResize(g_closeTimes, n + 1);
   g_closeTimes[n] = TimeCurrent();
   SaveState();
   return(true);
  }

void CloseSide(const long magic, const int type, const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!Mine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), magic)) continue;
      if(type >= 0 && (int)PositionGetInteger(POSITION_TYPE) != type) continue;
      ClosePos(t, why);
     }
  }

double NanpinLot(const int level)
  {
   double lot = InpBaseLot;
   if(level >= InpNanpinLotFrom) lot *= InpNanpinLotMult; // section 7 / flowchart
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathRound(lot / step) * step;
   return(MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)));
  }

//+------------------------------------------------------------------+
//| Main hedged nanpin grid                                          |
//+------------------------------------------------------------------+
void ManageMainGrid()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // seed: ASSUMPTION - keep one starter position per side (hedged grid)
   if(CountSide(InpMagic, POSITION_TYPE_BUY) == 0)
      trade.Buy(NanpinLot(1), _Symbol, 0.0, 0.0, 0.0, "CBS seed B");
   if(CountSide(InpMagic, POSITION_TYPE_SELL) == 0)
      trade.Sell(NanpinLot(1), _Symbol, 0.0, 0.0, 0.0, "CBS seed S");

   // nanpin: add when price moved NanpinPips AGAINST the side's newest entry
   int nb = CountSide(InpMagic, POSITION_TYPE_BUY);
   if(nb > 0 && nb < InpMaxPositions)
     {
      double last = LastEntryPrice(InpMagic, POSITION_TYPE_BUY);
      if(last > 0 && last - ask >= InpNanpinPips * PIP)
         trade.Buy(NanpinLot(nb + 1), _Symbol, 0.0, 0.0, 0.0, "CBS nanpin B");
     }
   int ns = CountSide(InpMagic, POSITION_TYPE_SELL);
   if(ns > 0 && ns < InpMaxPositions)
     {
      double last = LastEntryPrice(InpMagic, POSITION_TYPE_SELL);
      if(last > 0 && bid - last >= InpNanpinPips * PIP)
         trade.Sell(NanpinLot(ns + 1), _Symbol, 0.0, 0.0, 0.0, "CBS nanpin S");
     }
  }

//+------------------------------------------------------------------+
//| (1) Basket TP - combined or per-side, stuck positions excluded   |
//+------------------------------------------------------------------+
void BasketScan(const int type, double &pnl, ulong &tickets[])
  {
   ArrayResize(tickets, 0);
   pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!Mine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), InpMagic)) continue;
      if(type >= 0 && (int)PositionGetInteger(POSITION_TYPE) != type) continue;
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(-p > InpStuckThreshold) continue;      // stuck: excluded from the basket
      pnl += p;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = t;
     }
  }

void ManageBasket()
  {
   ulong tk[];
   double pnl;
   if(g_basket)
     {
      BasketScan(-1, pnl, tk);
      if(pnl >= InpNormalProfit && ArraySize(tk) > 0)
         for(int i = 0; i < ArraySize(tk); i++) ClosePos(tk[i], "basket");
     }
   else
     {
      for(int side = 0; side <= 1; side++)
        {
         BasketScan(side == 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL, pnl, tk);
         if(pnl >= InpNormalProfit && ArraySize(tk) > 0)
            for(int i = 0; i < ArraySize(tk); i++) ClosePos(tk[i], "basket1s");
        }
     }
  }

//+------------------------------------------------------------------+
//| (2) TailCut - pool buys out the single worst stuck position      |
//+------------------------------------------------------------------+
void ManageTailCut()
  {
   if(!g_tailcut || g_pool <= 0.0) return;
   ulong worst = 0;
   double worstLoss = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!Mine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), InpMagic)) continue;
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(-p > InpStuckThreshold && -p > worstLoss) { worstLoss = -p; worst = t; }
     }
   if(worst != 0 && g_pool >= worstLoss)
      ClosePos(worst, "tailcut");        // realized loss is debited from pool inside ClosePos
  }

//+------------------------------------------------------------------+
//| (3) ReverseGrid - counter-side chain that refills the pool       |
//+------------------------------------------------------------------+
void ManageReverseGrid()
  {
   if(!InpEnableReverseGrid) return;
   int nb = CountSide(InpMagic, POSITION_TYPE_BUY);
   int ns = CountSide(InpMagic, POSITION_TYPE_SELL);
   int mainTotal = nb + ns;
   int revType = (nb >= ns) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY; // opposite of dominant

   trade.SetExpertMagicNumber(InpMagicReverse);

   if(mainTotal > InpRevTriggerCount)
     {
      int nr = CountSide(InpMagicReverse, revType);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double gap = InpNanpinPips * InpRevNanpinMult * PIP;
      double last = LastEntryPrice(InpMagicReverse, revType);
      bool addOK = (nr == 0) ||
                   (revType == POSITION_TYPE_BUY  && last > 0 && last - ask >= gap) ||
                   (revType == POSITION_TYPE_SELL && last > 0 && bid - last >= gap);
      if(nr < InpMaxPositions && addOK)
        {
         if(revType == POSITION_TYPE_BUY) trade.Buy(InpBaseLot, _Symbol, 0.0, 0.0, 0.0, "CBS revgrid B");
         else                             trade.Sell(InpBaseLot, _Symbol, 0.0, 0.0, 0.0, "CBS revgrid S");
        }
     }

   // per-position TP -> pool refill ("プール補充": each reverse close feeds the pool)
   double tpUSD = InpRevTPPerBaseLot;   // ASSUMPTION: USD per BaseLot position
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!Mine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), InpMagicReverse)) continue;
      if(PosProfit(t) >= tpUSD * (PositionGetDouble(POSITION_VOLUME) / InpBaseLot))
         ClosePos(t, "revTP");
     }

   // dissolve (flowchart "逆グリッド解消"): main back under trigger =>
   // ASSUMPTION: close the reverse basket once it is not losing
   if(mainTotal <= InpRevTriggerCount && CountSide(InpMagicReverse, -1) > 0)
     {
      double pnl = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(!Mine((long)PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL), InpMagicReverse)) continue;
         pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      if(pnl >= 0.0) CloseSide(InpMagicReverse, -1, "revdissolve");
     }

   trade.SetExpertMagicNumber(InpMagic);
  }

//+------------------------------------------------------------------+
//| (4) SlotFree / Offset2 - keep the grid breathing at full slots   |
//+------------------------------------------------------------------+
int RecentCloses(const datetime from, const datetime to)
  {
   int n = 0;
   for(int i = ArraySize(g_closeTimes) - 1; i >= 0; i--)
      if(g_closeTimes[i] >= from && g_closeTimes[i] < to) n++;
   return(n);
  }

void ManageSlotFree()
  {
   if(!g_slotfree) return;
   if(TimeCurrent() - g_lastSlotFree < InpOffset2Cooldown) return;

   for(int side = 0; side <= 1; side++)
     {
      int type = (side == 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      if(CountSide(InpMagic, type) < InpMaxPositions) continue;

      ulong t1, t2;
      NewestTwo(InpMagic, type, t1, t2);
      if(t1 == 0) continue;
      PositionSelectByTicket(t1);
      double e1 = PositionGetDouble(POSITION_PRICE_OPEN);
      double px = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      bool trigA = MathAbs(px - e1) >= InpOffset2ExtraPips * PIP;

      // TriggerB: close-rotation stagnation vs the previous window
      datetime now = TimeCurrent();
      int win = (int)(InpRotationWindowH * 3600);
      int cur = RecentCloses(now - win, now);
      int prev = RecentCloses(now - 2 * win, now - win);
      bool trigB = (prev > 0 && cur < prev * InpRotationThreshold / 100.0);

      if(trigA || trigB)      // ASSUMPTION: manual lists both triggers; OR-combined
        {
         int nClose = 1;
         if(t2 != 0)
           {
            PositionSelectByTicket(t2);
            double e2 = PositionGetDouble(POSITION_PRICE_OPEN);
            if(MathAbs(e1 - e2) >= InpOffset2GapPips * PIP) nClose = 2; // gap rule: +1
           }
         ClosePos(t1, "slotfree");
         if(nClose == 2 && t2 != 0) ClosePos(t2, "slotfree2");
         g_lastSlotFree = TimeCurrent();
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| BulkClear + pool reset + weekend                                 |
//+------------------------------------------------------------------+
void ManageBulkClear()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq >= g_baseEquity + InpBulkClearProfit)
     {
      CloseSide(InpMagic, -1, "bulkclear");
      CloseSide(InpMagicReverse, -1, "bulkclear");
      g_baseEquity = AccountInfoDouble(ACCOUNT_EQUITY); // re-anchor after the clear
      if(InpAutoStopAfterClear) g_auto = false;
      SaveState();
     }
  }

void ManagePoolReset()
  {
   if(g_pool >= 0.0) { g_poolNegSince = 0; return; }
   if(g_poolNegSince == 0) { g_poolNegSince = TimeCurrent(); return; }
   if(TimeCurrent() - g_poolNegSince >= 5) { g_pool = 0.0; g_poolNegSince = 0; SaveState(); }
  }

bool WeekendHalt()
  {
   MqlDateTime st;
   TimeToStruct(TimeTradeServer(), st);
   bool we = (st.day_of_week == 6 || st.day_of_week == 0);
   if(we && InpWeekendAction == CLOSE_ALL_WE)
     {
      CloseSide(InpMagic, -1, "weekend");
      CloseSide(InpMagicReverse, -1, "weekend");
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Panel (section 10-11)                                            |
//+------------------------------------------------------------------+
void Btn(const string name, const int x, const int y, const int w, const string text, const color bg)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, 22);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
  }

void Lbl(const string name, const int x, const int y, const string text, const color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void DrawPanel()
  {
   if(!InpShowPanel) return;
   double bpnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      long m = (long)PositionGetInteger(POSITION_MAGIC);
      if((m == InpMagic || m == InpMagicReverse) && PositionGetString(POSITION_SYMBOL) == _Symbol)
         bpnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   int y = 20;
   Lbl("CBS_t", 10, y, "CB Survivor v1.00 (repro)", clrWhite); y += 18;
   Lbl("CBS_pnl",  10, y, StringFormat("Basket P&L: %+.2f USD", bpnl), bpnl >= 0 ? clrLime : clrOrangeRed); y += 16;
   Lbl("CBS_pool", 10, y, StringFormat("Pool: %.2f USD", g_pool), clrAqua); y += 16;
   Lbl("CBS_day",  10, y, StringFormat("Today: %+.2f USD", g_dayProfit), clrWhite); y += 16;
   Lbl("CBS_cb",   10, y, StringFormat("CB: %.2f lot = %.2f USD", g_cbLots, g_cbLots * InpCBPerLot), clrGold); y += 16;
   Lbl("CBS_cnt",  10, y, StringFormat("B:%d S:%d Rev:%d", CountSide(InpMagic, POSITION_TYPE_BUY),
        CountSide(InpMagic, POSITION_TYPE_SELL), CountSide(InpMagicReverse, -1)), clrSilver); y += 20;
   Btn("CBS_auto", 10, y, 90, g_auto ? "AUTO ON" : "STOPPED", g_auto ? clrGreen : clrFireBrick);
   Btn("CBS_sync", 105, y, 90, "SYNC BAL", clrSlateGray); y += 26;
   Btn("CBS_call", 10, y, 90, "CLOSE ALL", clrFireBrick);
   Btn("CBS_cbuy", 105, y, 90, "CLOSE BUY", clrSlateGray); y += 26;
   Btn("CBS_csell", 10, y, 90, "CLOSE SELL", clrSlateGray);
   Btn("CBS_hedge", 105, y, 90, "HEDGE LOCK", clrSlateGray); y += 26;
   Btn("CBS_bask", 10, y, 90, g_basket ? "BASKET ON" : "BASKET OFF", g_basket ? clrGreen : clrGray);
   Btn("CBS_tail", 105, y, 90, g_tailcut ? "TailCut ON" : "TailCut OFF", g_tailcut ? clrGreen : clrGray); y += 26;
   Btn("CBS_slot", 10, y, 90, g_slotfree ? "SlotFree ON" : "SlotFree OFF", g_slotfree ? clrGreen : clrGray);
   ChartRedraw();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(sparam == "CBS_auto") g_auto = !g_auto;
   else if(sparam == "CBS_sync") g_baseEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   else if(sparam == "CBS_call") { CloseSide(InpMagic, -1, "btn"); CloseSide(InpMagicReverse, -1, "btn"); }
   else if(sparam == "CBS_cbuy") CloseSide(InpMagic, POSITION_TYPE_BUY, "btn");
   else if(sparam == "CBS_csell") CloseSide(InpMagic, POSITION_TYPE_SELL, "btn");
   else if(sparam == "CBS_hedge")
     {
      trade.Buy(InpBaseLot, _Symbol, 0.0, 0.0, 0.0, "CBS hedgelock");
      trade.Sell(InpBaseLot, _Symbol, 0.0, 0.0, 0.0, "CBS hedgelock");
     }
   else if(sparam == "CBS_bask") g_basket = !g_basket;
   else if(sparam == "CBS_tail") g_tailcut = !g_tailcut;
   else if(sparam == "CBS_slot") g_slotfree = !g_slotfree;
   else return;
   SaveState();
   DrawPanel();
  }

void OnTimer() { DrawPanel(); }

//+------------------------------------------------------------------+
void OnTick()
  {
   MqlDateTime st;
   TimeToStruct(TimeTradeServer(), st);
   int stamp = st.year * 1000 + st.day_of_year;
   if(stamp != g_dayStamp) { g_dayStamp = stamp; g_dayProfit = 0.0; }

   ManagePoolReset();
   if(WeekendHalt()) { DrawPanel(); return; }
   if(!g_auto) return;

   ManageBasket();      // (1)
   ManageTailCut();     // (2)
   ManageReverseGrid(); // (3)
   ManageSlotFree();    // (4)
   ManageBulkClear();
   ManageMainGrid();
  }
//+------------------------------------------------------------------+
