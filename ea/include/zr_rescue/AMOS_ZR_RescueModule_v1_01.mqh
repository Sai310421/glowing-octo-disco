//+------------------------------------------------------------------+
//| AMOS_ZR_RescueModule_v1_01.mqh                                   |
//| Zone Recovery Rescue Module for AMOS 4x3 State Router             |
//| Purpose: Rescue / basket recovery / PCI-style completion exit      |
//+------------------------------------------------------------------+
#property strict

#ifndef __AMOS_ZR_RESCUE_MODULE_V1_01__
#define __AMOS_ZR_RESCUE_MODULE_V1_01__

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//====================================================================
// Required external objects / variables
//====================================================================
// The parent EA must define and own these objects/variables.
// Example in AMOS_Main.mq5:
//   input ulong InpMagicNumber = 2607001;
//   CTrade m_trade;
//   CPositionInfo m_position;
//   double m_pip_size = 0.01; // XAUUSD example; set correctly per broker
//
// This module uses them as extern references.
extern ulong         InpMagicNumber;
extern CTrade        m_trade;
extern CPositionInfo m_position;
extern double        m_pip_size;

//====================================================================
// Market State / Strategy Slot / Rescue Policy
//====================================================================
enum ENUM_AMOS_MARKET_STATE
{
   STATE_NO_TRADE = 0,
   STATE_RANGE    = 1,
   STATE_TREND    = 2,
   STATE_CHAOS    = 3
};

enum ENUM_AMOS_STRATEGY_SLOT
{
   SLOT_SMALL_PROFIT = 0,
   SLOT_DIRECTIONAL  = 1,
   SLOT_ICT_BOOST    = 2
};

enum ENUM_ZR_RESCUE_POLICY
{
   ZR_POLICY_OFF = 0,
   ZR_POLICY_EXIT_ONLY,
   ZR_POLICY_SOFT,
   ZR_POLICY_NORMAL,
   ZR_POLICY_AGGRESSIVE
};

//====================================================================
// Zone Recovery Inputs
//====================================================================
enum ENUM_ZR_LOT_METHOD     { ZR_LOT_MULTIPLY, ZR_LOT_ADDITION, ZR_LOT_MARTINGALE };
enum ENUM_ZR_TARGET_PROFIT  { ZR_PROFIT_ZERO, ZR_PROFIT_FIXED };
enum ENUM_ZR_ANCHOR_MODE    { ZR_ANCHOR_FIRST, ZR_ANCHOR_ROLLING };

input group "=== AMOS ZR Rescue Core ==="
input ENUM_TIMEFRAMES       InpZoneATRTF                 = PERIOD_H1;
input int                   InpZoneATRPeriod             = 14;
input double                InpZoneATRMultiplier         = 0.25;
input double                InpZoneWidthFactor           = 1.10;      // BT compare: 1.10 rolling vs 1.00 fixed
input ENUM_ZR_ANCHOR_MODE   InpZoneAnchorMode            = ZR_ANCHOR_ROLLING;
input ENUM_ZR_LOT_METHOD    InpZRLotMethod               = ZR_LOT_MULTIPLY;
input double                InpZRLotCoefficient          = 1.35;
input double                InpZRAddLotStep              = 0.01;      // used only when ZR_LOT_ADDITION
input int                   InpZRMaxTurnCount            = 4;
input int                   InpZRMinBarsBetweenAdds      = 3;
input bool                  InpZRForceCloseAtMaxTurn     = false;
input int                   InpZRBasketMaxHoldingMins    = 360;
input ENUM_ZR_TARGET_PROFIT InpZRTargetProfitType        = ZR_PROFIT_FIXED;
input int                   InpZRTargetProfitMoney       = 30;
input int                   InpZRInitialMaxHoldingMins   = 60;
input bool                  InpZRInitialExitLossOnly     = true;

input group "=== AMOS ZR Rescue Guard ==="
input bool                  InpZRModuleEnabled           = true;
input double                InpZRMaxEquityDDPercent      = 5.0;
input double                InpZRHardEquityDDPercent     = 8.0;
input double                InpZRMaxSpreadPips           = 5.0;
input bool                  InpZRDisableNewsTime         = true;
input bool                  InpZRDisableStrongTrend      = true;
input bool                  InpZRUsePCICompletion        = true;
input bool                  InpZRUseCashbackCredit       = true;
input double                InpZRCashbackPerLotRound     = 0.0;      // account currency per 1.00 lot round-turn estimate
input double                InpZRCommissionPerLotRound   = 0.0;      // external round-turn commission per 1.00 lot
input double                InpZRRiskPenaltyFactor       = 1.0;
input double                InpZRTrendADXLimit           = 32.0;
input ENUM_TIMEFRAMES       InpZRTrendTF                 = PERIOD_M15;
input int                   InpZRADXPeriod               = 14;
input int                   InpZRFastEMA                 = 20;
input int                   InpZRSlowEMA                 = 50;
input bool                  InpZRDebugLog                = true;

input group "=== AMOS ZR Execution Freeze Guard ==="
input bool                  InpZROrderFailFreezeEnabled  = true;     // skip delayed execution after failed order
input double                InpZROrderFailFreezePips     = 2.0;      // max distance from zone boundary before freezing retry
input int                   InpZROrderFreezeBars         = 1;        // minimum bars to freeze after delayed failure

//====================================================================
// Constants / State
//====================================================================
#define ZR_MAGIC_OFFSET       100
#define ZR_COMMENT            "ZR_Position"
#define ZR_LOCK_PIPS          5.0
#define ZR_REF_LOT            0.01
#define ZR_POSITION_NONE      ((ENUM_POSITION_TYPE)-1)

struct SZoneRecoveryState
{
   bool               active;
   bool               recovery_started;
   double             anchor_price;
   double             rolling_anchor;
   double             zone_width;
   int                current_zone;
   int                turn_count;
   datetime           last_order_bar;
   double             last_cross_price;
   bool               order_lock;
   bool               order_freeze_active;
   datetime           order_freeze_bar;
   double             order_freeze_boundary;
   ENUM_ORDER_TYPE    order_freeze_type;
   int                order_freeze_turn;
   ENUM_POSITION_TYPE first_type;
   double             first_lot;
   double             last_lot;
   datetime           first_entry_time;
   ENUM_AMOS_MARKET_STATE  state;
   ENUM_AMOS_STRATEGY_SLOT slot;
   ENUM_ZR_RESCUE_POLICY   policy;
};

SZoneRecoveryState g_zr;
double g_zr_fixed_zone_width = 0.0;
int    m_zr_atr_handle       = INVALID_HANDLE;
int    m_zr_adx_handle       = INVALID_HANDLE;
int    m_zr_fast_ema_handle  = INVALID_HANDLE;
int    m_zr_slow_ema_handle  = INVALID_HANDLE;

//====================================================================
// Utility: string conversion
//====================================================================
string ZRStateToString(ENUM_AMOS_MARKET_STATE state)
{
   if(state == STATE_NO_TRADE) return "NO_TRADE";
   if(state == STATE_RANGE)    return "RANGE";
   if(state == STATE_TREND)    return "TREND";
   if(state == STATE_CHAOS)    return "CHAOS";
   return "UNKNOWN";
}

string ZRSlotToString(ENUM_AMOS_STRATEGY_SLOT slot)
{
   if(slot == SLOT_SMALL_PROFIT) return "SMALL_PROFIT";
   if(slot == SLOT_DIRECTIONAL)  return "DIRECTIONAL";
   if(slot == SLOT_ICT_BOOST)    return "ICT_BOOST";
   return "UNKNOWN";
}

string ZRPolicyToString(ENUM_ZR_RESCUE_POLICY policy)
{
   if(policy == ZR_POLICY_OFF)        return "OFF";
   if(policy == ZR_POLICY_EXIT_ONLY)  return "EXIT_ONLY";
   if(policy == ZR_POLICY_SOFT)       return "SOFT";
   if(policy == ZR_POLICY_NORMAL)     return "NORMAL";
   if(policy == ZR_POLICY_AGGRESSIVE) return "AGGRESSIVE";
   return "UNKNOWN";
}

void ZRLog(string event_name,
           string reason,
           ENUM_AMOS_MARKET_STATE state = STATE_NO_TRADE,
           ENUM_AMOS_STRATEGY_SLOT slot = SLOT_SMALL_PROFIT,
           ENUM_ZR_RESCUE_POLICY policy = ZR_POLICY_OFF)
{
   if(!InpZRDebugLog) return;

   double buy_lots = 0.0, sell_lots = 0.0;
   // avoid forward warning: local implementation below exists
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      long mg = (long)m_position.Magic();
      if(mg != (long)InpMagicNumber && mg != ((long)InpMagicNumber + ZR_MAGIC_OFFSET)) continue;
      if(m_position.PositionType() == POSITION_TYPE_BUY) buy_lots += m_position.Volume();
      else sell_lots += m_position.Volume();
   }

   PrintFormat("%s | symbol=%s state=%s slot=%s policy=%s profit=%.2f completion=%.2f turn=%d buyLot=%.2f sellLot=%.2f spread=%.2f reason=%s",
               event_name,
               _Symbol,
               ZRStateToString(state),
               ZRSlotToString(slot),
               ZRPolicyToString(policy),
               0.0,
               0.0,
               g_zr.turn_count,
               buy_lots,
               sell_lots,
               0.0,
               reason);
}

//====================================================================
// Magic / comment helpers
//====================================================================
long GetZRMagic()
{
   return (long)InpMagicNumber + ZR_MAGIC_OFFSET;
}

bool IsZRComment(string comment)
{
   return (StringFind(comment, ZR_COMMENT) >= 0);
}

bool IsBasketMagic(long magic)
{
   return (magic == (long)InpMagicNumber || magic == GetZRMagic());
}

bool IsInZoneRecovery()
{
   return g_zr.active;
}

//====================================================================
// Policy router: 4 modes x 3 slots
//====================================================================
ENUM_ZR_RESCUE_POLICY GetZRPolicy(ENUM_AMOS_MARKET_STATE state, ENUM_AMOS_STRATEGY_SLOT slot)
{
   if(state == STATE_NO_TRADE)
      return ZR_POLICY_EXIT_ONLY;

   if(state == STATE_RANGE)
   {
      if(slot == SLOT_SMALL_PROFIT) return ZR_POLICY_AGGRESSIVE;
      if(slot == SLOT_DIRECTIONAL)  return ZR_POLICY_NORMAL;
      if(slot == SLOT_ICT_BOOST)    return ZR_POLICY_SOFT;
   }

   if(state == STATE_TREND)
   {
      if(slot == SLOT_SMALL_PROFIT) return ZR_POLICY_SOFT;
      if(slot == SLOT_DIRECTIONAL)  return ZR_POLICY_NORMAL;
      if(slot == SLOT_ICT_BOOST)    return ZR_POLICY_SOFT;
   }

   if(state == STATE_CHAOS)
      return ZR_POLICY_EXIT_ONLY;

   return ZR_POLICY_OFF;
}

//====================================================================
// Policy parameter mapping
//====================================================================
double ZRPolicyLotCoefficient(ENUM_ZR_RESCUE_POLICY policy)
{
   if(policy == ZR_POLICY_EXIT_ONLY)  return MathMin(InpZRLotCoefficient, 1.10);
   if(policy == ZR_POLICY_SOFT)       return MathMin(InpZRLotCoefficient, 1.25);
   if(policy == ZR_POLICY_NORMAL)     return MathMin(MathMax(InpZRLotCoefficient, 1.20), 1.35);
   if(policy == ZR_POLICY_AGGRESSIVE) return MathMin(MathMax(InpZRLotCoefficient, 1.30), 1.45);
   return 1.0;
}

int ZRPolicyMaxTurns(ENUM_ZR_RESCUE_POLICY policy)
{
   if(policy == ZR_POLICY_EXIT_ONLY)  return MathMin(InpZRMaxTurnCount, 2);
   if(policy == ZR_POLICY_SOFT)       return MathMin(InpZRMaxTurnCount, 3);
   if(policy == ZR_POLICY_NORMAL)     return MathMin(MathMax(InpZRMaxTurnCount, 3), 4);
   if(policy == ZR_POLICY_AGGRESSIVE) return MathMin(MathMax(InpZRMaxTurnCount, 4), 5);
   return 0;
}

int ZRPolicyTargetMoney(ENUM_ZR_RESCUE_POLICY policy)
{
   if(policy == ZR_POLICY_EXIT_ONLY)  return MathMin(InpZRTargetProfitMoney, 10);
   if(policy == ZR_POLICY_SOFT)       return MathMin(InpZRTargetProfitMoney, 30);
   if(policy == ZR_POLICY_NORMAL)     return MathMin(MathMax(InpZRTargetProfitMoney, 30), 50);
   if(policy == ZR_POLICY_AGGRESSIVE) return MathMin(MathMax(InpZRTargetProfitMoney, 50), 80);
   return 0;
}

int ZRPolicyMaxHoldingMins(ENUM_ZR_RESCUE_POLICY policy)
{
   if(policy == ZR_POLICY_EXIT_ONLY)  return MathMin(InpZRBasketMaxHoldingMins, 180);
   if(policy == ZR_POLICY_SOFT)       return MathMin(InpZRBasketMaxHoldingMins, 240);
   if(policy == ZR_POLICY_NORMAL)     return MathMin(MathMax(InpZRBasketMaxHoldingMins, 180), 360);
   if(policy == ZR_POLICY_AGGRESSIVE) return MathMin(MathMax(InpZRBasketMaxHoldingMins, 240), 360);
   return 0;
}

//====================================================================
// Account / market guards
//====================================================================
double GetCurrentSpreadPips()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(m_pip_size <= 0.0) return 999999.0;
   return (ask - bid) / m_pip_size;
}

double GetEquityDDPercent()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0.0) return 0.0;
   double dd = (balance - equity) / balance * 100.0;
   return MathMax(0.0, dd);
}

bool IsNewsDangerTime()
{
   // Safe default: no news calendar dependency.
   // Parent EA can replace this module-level function if needed by moving it to adapter layer.
   return false;
}

int GetEMADirection()
{
   double fast[2], slow[2];
   if(m_zr_fast_ema_handle == INVALID_HANDLE || m_zr_slow_ema_handle == INVALID_HANDLE) return 0;
   if(CopyBuffer(m_zr_fast_ema_handle, 0, 1, 2, fast) < 2) return 0;
   if(CopyBuffer(m_zr_slow_ema_handle, 0, 1, 2, slow) < 2) return 0;
   if(fast[0] > slow[0] && fast[0] > fast[1]) return 1;
   if(fast[0] < slow[0] && fast[0] < fast[1]) return -1;
   return 0;
}

double GetADXValue()
{
   double adx[1];
   if(m_zr_adx_handle == INVALID_HANDLE) return 0.0;
   if(CopyBuffer(m_zr_adx_handle, 0, 1, 1, adx) < 1) return 0.0;
   return adx[0];
}

bool IsStrongTrendNow()
{
   double adx = GetADXValue();
   int dir = GetEMADirection();
   return (adx >= InpZRTrendADXLimit && dir != 0);
}

bool IsStrongTrendAgainstRecovery(ENUM_AMOS_MARKET_STATE state)
{
   if(state != STATE_TREND) return false;
   if(!IsStrongTrendNow()) return false;
   return true;
}

bool IsBreakoutFailureConfirmed()
{
   // Conservative default: false. Parent EA should pass STATE_BREAKOUT only when it has its own failure logic.
   // To allow breakout rescue, integrate this with MSS/Sweep failure/VWAP re-entry/FVG failure.
   return false;
}

//====================================================================
// Basket helpers
//====================================================================
int CountBasketPositions(bool zr_only = false)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      long magic = (long)m_position.Magic();
      string comm = m_position.Comment();
      if(zr_only)
      {
         if(magic == GetZRMagic() || (magic == (long)InpMagicNumber && IsZRComment(comm))) count++;
      }
      else
      {
         if(IsBasketMagic(magic)) count++;
      }
   }
   return count;
}

bool IsZRSuppressingIndividualExits()
{
   if(!g_zr.active) return false;
   if(g_zr.recovery_started) return true;
   if(CountBasketPositions(false) > 1) return true;
   return false;
}

void ResetZoneRecovery()
{
   g_zr.active = false;
   g_zr.recovery_started = false;
   g_zr.anchor_price = 0.0;
   g_zr.rolling_anchor = 0.0;
   g_zr.zone_width = 0.0;
   g_zr.current_zone = 0;
   g_zr.turn_count = 0;
   g_zr.last_order_bar = 0;
   g_zr.last_cross_price = 0.0;
   g_zr.order_lock = false;
   g_zr.order_freeze_active = false;
   g_zr.order_freeze_bar = 0;
   g_zr.order_freeze_boundary = 0.0;
   g_zr.order_freeze_type = ORDER_TYPE_BUY;
   g_zr.order_freeze_turn = -1;
   g_zr.first_type = ZR_POSITION_NONE;
   g_zr.first_lot = 0.0;
   g_zr.last_lot = 0.0;
   g_zr.first_entry_time = 0;
   g_zr.state = STATE_NO_TRADE;
   g_zr.slot = SLOT_SMALL_PROFIT;
   g_zr.policy = ZR_POLICY_OFF;
}

void GetBasketLots(double &buy_lots, double &sell_lots)
{
   buy_lots = 0.0;
   sell_lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      if(!IsBasketMagic((long)m_position.Magic())) continue;
      double vol = m_position.Volume();
      if(m_position.PositionType() == POSITION_TYPE_BUY) buy_lots += vol;
      else sell_lots += vol;
   }
}

double GetBasketProfit()
{
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      if(!IsBasketMagic((long)m_position.Magic())) continue;
      total += m_position.Profit() + m_position.Swap() + m_position.Commission();
   }
   return total;
}

bool CloseBasketWithRetry(int max_retry = 3)
{
   bool all_ok = true;

   for(int pass = 0; pass < max_retry; pass++)
   {
      bool pass_had_close = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!m_position.SelectByIndex(i)) continue;
         if(m_position.Symbol() != _Symbol) continue;
         if(!IsBasketMagic((long)m_position.Magic())) continue;

         ulong ticket = m_position.Ticket();
         if(!m_trade.PositionClose(ticket))
         {
            all_ok = false;
            PrintFormat("ZR_CLOSE_RETRY_FAIL | ticket=%I64u retcode=%d desc=%s", ticket, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         }
         else
         {
            pass_had_close = true;
         }
      }

      if(CountBasketPositions(false) == 0)
      {
         g_zr_fixed_zone_width = 0.0;
         ResetZoneRecovery();
         return true;
      }

      if(!pass_had_close) break;
      Sleep(50);
   }

   if(CountBasketPositions(false) == 0)
   {
      g_zr_fixed_zone_width = 0.0;
      ResetZoneRecovery();
      return all_ok;
   }

   return false;
}

bool CloseBasket()
{
   bool ok = CloseBasketWithRetry(3);
   if(ok)
   {
      g_zr_fixed_zone_width = 0.0;
      ResetZoneRecovery();
   }
   return ok;
}

void StripBasketSLTP()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      if(!IsBasketMagic((long)m_position.Magic())) continue;
      double sl = m_position.StopLoss();
      double tp = m_position.TakeProfit();
      if(sl != 0.0 || tp != 0.0)
      {
         if(!m_trade.PositionModify(m_position.Ticket(), 0.0, 0.0))
            PrintFormat("ZR_STRIP_SLTP_FAIL | ticket=%I64u retcode=%d", m_position.Ticket(), m_trade.ResultRetcode());
      }
   }
}

//====================================================================
// Zone math
//====================================================================
int GetZoneLevel(double price, double anchor, double base_width, double factor)
{
   if(base_width <= 0.0) return 0;
   double diff = price - anchor;
   if(MathAbs(diff) < 1e-12) return 0;
   if(factor <= 0.0) factor = 1.0;

   int sign = (diff > 0.0) ? 1 : -1;
   double abs_diff = MathAbs(diff);

   if(MathAbs(factor - 1.0) < 1e-9)
      return sign * (int)MathFloor(abs_diff / base_width);

   int level = 0;
   double cum = 0.0;
   while(level < 100)
   {
      double band = base_width * MathPow(factor, level);
      if(cum + band > abs_diff + 1e-10) break;
      cum += band;
      level++;
   }
   return sign * level;
}

double GetEffectiveZoneWidth(double base_width, int step_index)
{
   if(base_width <= 0.0) return 0.0;
   if(step_index < 0) step_index = 0;
   if(InpZoneWidthFactor <= 0.0) return base_width;
   return base_width * MathPow(InpZoneWidthFactor, step_index);
}

//====================================================================
// Completion / PCI-style exit
//====================================================================
double GetEstimatedCashbackForBasket()
{
   if(!InpZRUseCashbackCredit || InpZRCashbackPerLotRound <= 0.0) return 0.0;

   double total_lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      if(!IsBasketMagic((long)m_position.Magic())) continue;
      total_lots += m_position.Volume();
   }

   return total_lots * InpZRCashbackPerLotRound;
}

double GetZRUnwindRiskPenalty()
{
   // Penalty rises when spread and DD rise. This prevents closing criteria from being too optimistic.
   double spread_pips = GetCurrentSpreadPips();
   double dd_percent  = GetEquityDDPercent();
   double penalty = 0.0;

   if(spread_pips > InpZRMaxSpreadPips * 0.7)
      penalty += (spread_pips - InpZRMaxSpreadPips * 0.7) * 0.5;

   if(dd_percent > InpZRMaxEquityDDPercent * 0.7)
      penalty += (dd_percent - InpZRMaxEquityDDPercent * 0.7) * 2.0;

   return MathMax(0.0, penalty);
}

double GetZRTargetProfitMoney()
{
   if(InpZRTargetProfitType == ZR_PROFIT_ZERO) return 0.0;

   int target_input = ZRPolicyTargetMoney(g_zr.policy);
   double first_lot = g_zr.first_lot;
   if(first_lot <= 0.0) first_lot = ZR_REF_LOT;
   return (double)target_input * (first_lot / ZR_REF_LOT);
}

double GetZRBasketRoundLots()
{
   double total_lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      if(!IsBasketMagic((long)m_position.Magic())) continue;
      total_lots += m_position.Volume();
   }
   return total_lots;
}

double GetEstimatedExternalCommissionForBasket()
{
   if(InpZRCommissionPerLotRound <= 0.0) return 0.0;
   return GetZRBasketRoundLots() * InpZRCommissionPerLotRound;
}

double GetZRCompletionValue()
{
   double basket_profit = GetBasketProfit();

   if(!InpZRUsePCICompletion)
      return basket_profit;

   double estimated_cb      = GetEstimatedCashbackForBasket();
   double total_commission  = GetEstimatedExternalCommissionForBasket();
   double risk_penalty      = GetZRUnwindRiskPenalty() * InpZRRiskPenaltyFactor;

   return basket_profit + estimated_cb - total_commission - risk_penalty;
}

//====================================================================
// Lot calculation
//====================================================================
int VolumeDigitsFromStep(double step)
{
   if(step <= 0.0) return 2;
   if(step < 0.0015) return 3;
   if(step < 0.015)  return 2;
   if(step < 0.15)   return 1;
   return 0;
}

double NormalizeVolumeUp(double lot)
{
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0.0) step = 0.01;
   lot = MathCeil(lot / step) * step;
   lot = MathMin(max_lot, MathMax(min_lot, lot));
   return NormalizeDouble(lot, VolumeDigitsFromStep(step));
}

double CalculateZRLot(ENUM_ORDER_TYPE order_type, double prev_lot)
{
   double lot = prev_lot;
   double buy_lots = 0.0, sell_lots = 0.0;
   GetBasketLots(buy_lots, sell_lots);

   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double coeff   = ZRPolicyLotCoefficient(g_zr.policy);

   if(prev_lot <= 0.0) prev_lot = MathMax(min_lot, g_zr.first_lot);

   if(InpZRLotMethod == ZR_LOT_MULTIPLY)
   {
      lot = prev_lot * coeff;
   }
   else if(InpZRLotMethod == ZR_LOT_ADDITION)
   {
      lot = prev_lot + InpZRAddLotStep;
   }
   else
   {
      bool is_buy = (order_type == ORDER_TYPE_BUY);
      if(is_buy) lot = sell_lots - buy_lots + min_lot;
      else       lot = buy_lots - sell_lots + min_lot;
      if(lot < min_lot) lot = min_lot;
   }

   return NormalizeVolumeUp(lot);
}

//====================================================================
// Order lock / throttle / delayed execution freeze
//====================================================================
double ZRCurrentMidPrice()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (ask + bid) / 2.0;
}

double ZRDistancePips(double a, double b)
{
   if(m_pip_size <= 0.0) return 999999.0;
   return MathAbs(a - b) / m_pip_size;
}

void ClearZROrderFreeze(string reason = "clear")
{
   if(g_zr.order_freeze_active)
      ZRLog("ZR_ORDER_FREEZE_CLEAR", reason, g_zr.state, g_zr.slot, g_zr.policy);
   g_zr.order_freeze_active = false;
   g_zr.order_freeze_boundary = 0.0;
   g_zr.order_freeze_turn = -1;
}

void FreezeZROrderTurn(ENUM_ORDER_TYPE order_type, double boundary_price, string reason)
{
   g_zr.order_freeze_active = true;
   g_zr.order_freeze_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_zr.order_freeze_boundary = boundary_price;
   g_zr.order_freeze_type = order_type;
   g_zr.order_freeze_turn = g_zr.turn_count;
   LockZROrder(ZRCurrentMidPrice());
   ZRLog("ZR_ORDER_FREEZE", reason, g_zr.state, g_zr.slot, g_zr.policy);
}

bool IsZROrderFreezeActive(double ref_price)
{
   if(!InpZROrderFailFreezeEnabled || !g_zr.order_freeze_active) return false;

   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(InpZROrderFreezeBars > 0 && g_zr.order_freeze_bar > 0)
   {
      int shift_last = iBarShift(_Symbol, PERIOD_CURRENT, g_zr.order_freeze_bar, false);
      if(shift_last >= 0 && shift_last < InpZROrderFreezeBars) return true;
   }

   // Retry only after price returns close to the original zone boundary.
   if(ZRDistancePips(ref_price, g_zr.order_freeze_boundary) <= InpZROrderFailFreezePips)
   {
      ClearZROrderFreeze("price_returned_to_boundary");
      return false;
   }
   return true;
}

bool ShouldFreezeAfterOrderFail(double boundary_price)
{
   if(!InpZROrderFailFreezeEnabled) return false;
   if(InpZROrderFailFreezePips <= 0.0) return true;
   return (ZRDistancePips(ZRCurrentMidPrice(), boundary_price) > InpZROrderFailFreezePips);
}

double ZRZoneBoundaryPrice(double anchor, double base_width, double factor, int target_zone)
{
   if(target_zone == 0 || base_width <= 0.0) return anchor;
   int sign = (target_zone > 0) ? 1 : -1;
   int levels = MathAbs(target_zone);
   double dist = 0.0;
   for(int k = 0; k < levels; k++)
   {
      double mult = (MathAbs(factor - 1.0) < 1e-9 || factor <= 0.0) ? 1.0 : MathPow(factor, k);
      dist += base_width * mult;
   }
   return anchor + sign * dist;
}

bool CanPlaceZROrder(double ref_price)
{
   if(IsZROrderFreezeActive(ref_price)) return false;
   if(g_zr.last_order_bar == 0) return true;

   if(InpZRMinBarsBetweenAdds > 0)
   {
      int shift_last = iBarShift(_Symbol, PERIOD_CURRENT, g_zr.last_order_bar, false);
      if(shift_last >= 0 && shift_last < InpZRMinBarsBetweenAdds) return false;
      return true;
   }

   if(!g_zr.order_lock) return true;
   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur_bar != g_zr.last_order_bar) return true;
   if(m_pip_size > 0.0 && MathAbs(ref_price - g_zr.last_cross_price) >= ZR_LOCK_PIPS * m_pip_size) return true;
   return false;
}

void LockZROrder(double ref_price)
{
   g_zr.order_lock = true;
   g_zr.last_order_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_zr.last_cross_price = ref_price;
}

bool OpenZRPosition(ENUM_ORDER_TYPE order_type, double lot)
{
   long prev_magic = (long)m_trade.RequestMagic();
   m_trade.SetExpertMagicNumber(GetZRMagic());

   bool result = false;
   if(order_type == ORDER_TYPE_BUY)
      result = m_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, ZR_COMMENT);
   else
      result = m_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, ZR_COMMENT);

   if(prev_magic > 0) m_trade.SetExpertMagicNumber(prev_magic);
   else              m_trade.SetExpertMagicNumber((long)InpMagicNumber);

   if(result)
   {
      g_zr.last_lot = lot;
      ZRLog("ZR_ADD", (order_type == ORDER_TYPE_BUY ? "BUY" : "SELL"), g_zr.state, g_zr.slot, g_zr.policy);
   }
   else
   {
      PrintFormat("ZR_ORDER_FAIL | type=%s lot=%.3f retcode=%d desc=%s",
                  (order_type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  lot,
                  m_trade.ResultRetcode(),
                  m_trade.ResultRetcodeDescription());
   }

   return result;
}

//====================================================================
// Rescue start conditions
//====================================================================
bool BasketHasFloatingLoss()
{
   return (GetBasketProfit() < 0.0);
}

bool CanStartZRRescue(ENUM_AMOS_MARKET_STATE state, ENUM_AMOS_STRATEGY_SLOT slot)
{
   if(!InpZRModuleEnabled) return false;

   ENUM_ZR_RESCUE_POLICY policy = GetZRPolicy(state, slot);
   if(policy == ZR_POLICY_OFF)
   {
      ZRLog("ZR_BLOCK_POLICY", "policy_off", state, slot, policy);
      return false;
   }

   if(GetCurrentSpreadPips() > InpZRMaxSpreadPips)
   {
      ZRLog("ZR_BLOCK_SPREAD", "spread_over_limit", state, slot, policy);
      return false;
   }

   if(GetEquityDDPercent() > InpZRMaxEquityDDPercent)
   {
      ZRLog("ZR_BLOCK_DD", "dd_over_start_limit", state, slot, policy);
      return false;
   }

   if(InpZRDisableNewsTime && IsNewsDangerTime())
   {
      ZRLog("ZR_BLOCK_NEWS", "news_danger_time", state, slot, policy);
      return false;
   }

   if(InpZRDisableStrongTrend && IsStrongTrendAgainstRecovery(state))
   {
      ZRLog("ZR_BLOCK_TREND", "strong_trend_guard", state, slot, policy);
      return false;
   }

   // CHAOS is not a recovery-start environment. It is exit-only / lock management.
   if(state == STATE_CHAOS)
   {
      ZRLog("ZR_BLOCK_CHAOS", "chaos_exit_only_no_new_rescue", state, slot, policy);
      return false;
   }

   return true;
}

//====================================================================
// Init before recovery: initial single position control
//====================================================================
bool TryExitInitialBeforeZRRecovery()
{
   if(!g_zr.active || g_zr.recovery_started) return false;

   ulong ticket = 0;
   ENUM_POSITION_TYPE ptype = ZR_POSITION_NONE;
   datetime open_time = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      if((long)m_position.Magic() != (long)InpMagicNumber) continue;
      if(IsZRComment(m_position.Comment())) continue;

      ticket = m_position.Ticket();
      ptype = m_position.PositionType();
      open_time = (datetime)m_position.Time();
      break;
   }

   if(ticket == 0) return false;
   if(!m_position.SelectByTicket(ticket)) return false;

   datetime ref_time = (g_zr.first_entry_time > 0) ? g_zr.first_entry_time : open_time;
   if(InpZRInitialMaxHoldingMins > 0 && TimeCurrent() - ref_time >= (uint)InpZRInitialMaxHoldingMins * 60)
   {
      double pos_profit = m_position.Profit() + m_position.Swap() + m_position.Commission();
      if(!InpZRInitialExitLossOnly || pos_profit <= 0.0)
      {
         if(m_trade.PositionClose(ticket))
         {
            ResetZoneRecovery();
            ZRLog("ZR_INITIAL_EXIT", "initial_time_exit_before_recovery");
            return true;
         }
      }
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pos_sl = m_position.StopLoss();
   bool sl_hit = false;

   if(pos_sl > 0.0)
   {
      if(ptype == POSITION_TYPE_BUY  && bid <= pos_sl) sl_hit = true;
      if(ptype == POSITION_TYPE_SELL && ask >= pos_sl) sl_hit = true;
   }

   if(sl_hit)
   {
      if(m_trade.PositionClose(ticket))
      {
         ResetZoneRecovery();
         ZRLog("ZR_INITIAL_EXIT", "initial_sl_exit_before_recovery");
         return true;
      }
   }
   return false;
}

bool TryInitZoneRecovery(ENUM_AMOS_MARKET_STATE state, ENUM_AMOS_STRATEGY_SLOT slot)
{
   if(g_zr.active) return false;
   if(!CanStartZRRescue(state, slot)) return false;

   int first_count = 0;
   double anchor = 0.0, first_lot = 0.0;
   ENUM_POSITION_TYPE first_type = ZR_POSITION_NONE;
   datetime earliest = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol) continue;
      if((long)m_position.Magic() != (long)InpMagicNumber) continue;
      if(IsZRComment(m_position.Comment())) continue;

      first_count++;
      datetime ot = (datetime)m_position.Time();
      if(earliest == 0 || ot < earliest)
      {
         earliest = ot;
         anchor = m_position.PriceOpen();
         first_lot = m_position.Volume();
         first_type = m_position.PositionType();
      }
   }

   if(first_count != 1) return false;
   if(!BasketHasFloatingLoss()) return false;

   double zone_width = 0.0;
   if(g_zr_fixed_zone_width > 0.0)
   {
      zone_width = g_zr_fixed_zone_width;
   }
   else
   {
      double atr_buf[1];
      if(m_zr_atr_handle == INVALID_HANDLE) return false;
      if(CopyBuffer(m_zr_atr_handle, 0, 1, 1, atr_buf) < 1 || atr_buf[0] <= 0.0) return false;
      zone_width = atr_buf[0] * InpZoneATRMultiplier;
   }

   if(zone_width <= 0.0) return false;

   g_zr.active = true;
   g_zr.recovery_started = false;
   g_zr.anchor_price = anchor;
   g_zr.rolling_anchor = anchor;
   g_zr.zone_width = zone_width;
   g_zr.current_zone = 0;
   g_zr.turn_count = 0;
   g_zr.first_type = first_type;
   g_zr.first_lot = first_lot;
   g_zr.last_lot = first_lot;
   g_zr.first_entry_time = earliest;
   g_zr.order_lock = false;
   g_zr.order_freeze_active = false;
   g_zr.order_freeze_bar = 0;
   g_zr.order_freeze_boundary = 0.0;
   g_zr.order_freeze_type = ORDER_TYPE_BUY;
   g_zr.order_freeze_turn = -1;
   g_zr.state = state;
   g_zr.slot = slot;
   g_zr.policy = GetZRPolicy(state, slot);
   g_zr_fixed_zone_width = 0.0;

   ZRLog("ZR_ARMED", "initial_position_registered", state, slot, g_zr.policy);
   return true;
}

//====================================================================
// Main handler
//====================================================================
void HandleZoneRecovery(ENUM_AMOS_MARKET_STATE state, ENUM_AMOS_STRATEGY_SLOT slot)
{
   if(!InpZRModuleEnabled) return;

   int pos_count = CountBasketPositions(false);
   if(pos_count == 0)
   {
      if(g_zr.active) ResetZoneRecovery();
      return;
   }

   double dd = GetEquityDDPercent();
   if(dd >= InpZRHardEquityDDPercent)
   {
      ZRLog("ZR_CLOSE_DD", "hard_dd_close", state, slot, GetZRPolicy(state, slot));
      CloseBasket();
      return;
   }

   if(!g_zr.active)
   {
      TryInitZoneRecovery(state, slot);
      if(!g_zr.active) return;
   }

   // Keep latest context, but do not weaken active policy accidentally unless state becomes more defensive.
   ENUM_ZR_RESCUE_POLICY latest_policy = GetZRPolicy(state, slot);
   g_zr.state = state;
   g_zr.slot  = slot;
   if(latest_policy < g_zr.policy)
   {
      g_zr.policy = latest_policy;
      ZRLog("ZR_POLICY_CHANGE", "policy_defensive_update", state, slot, g_zr.policy);
   }

   double completion_value = GetZRCompletionValue();
   double target = GetZRTargetProfitMoney();
   if(completion_value >= target)
   {
      ZRLog((target <= 0.0 ? "ZR_CLOSE_ZERO" : "ZR_CLOSE_PROFIT"), "completion_target_reached", state, slot, g_zr.policy);
      CloseBasket();
      return;
   }

   int max_hold = ZRPolicyMaxHoldingMins(g_zr.policy);
   if(g_zr.recovery_started && max_hold > 0 && g_zr.first_entry_time > 0)
   {
      if(TimeCurrent() - g_zr.first_entry_time >= (uint)max_hold * 60)
      {
         ZRLog("ZR_CLOSE_TIME", "basket_time_exit", state, slot, g_zr.policy);
         CloseBasket();
         return;
      }
   }

   if(GetCurrentSpreadPips() > InpZRMaxSpreadPips)
   {
      ZRLog("ZR_BLOCK_SPREAD", "spread_block_during_management", state, slot, g_zr.policy);
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double mid = (ask + bid) / 2.0;
   double anchor = g_zr.anchor_price;
   double zw = g_zr.zone_width;

   if(!g_zr.recovery_started)
   {
      if(TryExitInitialBeforeZRRecovery()) return;

      bool trigger = false;
      ENUM_ORDER_TYPE hedge_type = ORDER_TYPE_BUY;

      if(g_zr.first_type == POSITION_TYPE_BUY && bid <= anchor - zw)
      {
         trigger = true;
         hedge_type = ORDER_TYPE_SELL;
      }
      else if(g_zr.first_type == POSITION_TYPE_SELL && ask >= anchor + zw)
      {
         trigger = true;
         hedge_type = ORDER_TYPE_BUY;
      }

      if(trigger && CanPlaceZROrder(mid))
      {
         double lot = CalculateZRLot(hedge_type, g_zr.last_lot);
         double boundary_price = (hedge_type == ORDER_TYPE_SELL ? anchor - zw : anchor + zw);
         if(OpenZRPosition(hedge_type, lot))
         {
            ClearZROrderFreeze("order_success");
            g_zr.recovery_started = true;
            g_zr.turn_count = 1;
            g_zr.rolling_anchor = mid;
            g_zr.current_zone = GetZoneLevel(mid, anchor, zw, InpZoneWidthFactor);
            StripBasketSLTP();
            LockZROrder(mid);
            ZRLog("ZR_START", "first_hedge_opened", state, slot, g_zr.policy);
         }
         else if(ShouldFreezeAfterOrderFail(boundary_price))
         {
            FreezeZROrderTurn(hedge_type, boundary_price, "first_hedge_failed_price_left_boundary");
         }
      }
      return;
   }

   int max_turns = ZRPolicyMaxTurns(g_zr.policy);
   if(g_zr.turn_count >= max_turns)
   {
      if(InpZRForceCloseAtMaxTurn)
      {
         ZRLog("ZR_CLOSE_MAXTURN", "max_turn_force_close", state, slot, g_zr.policy);
         CloseBasket();
      }
      else
      {
         ZRLog("ZR_STOP_ADD", "max_turn_reached_no_more_add", state, slot, g_zr.policy);
      }
      return;
   }

   if(g_zr.policy == ZR_POLICY_EXIT_ONLY && g_zr.turn_count >= 1)
   {
      ZRLog("ZR_STOP_ADD", "exit_only_single_rescue_limit", state, slot, g_zr.policy);
      return;
   }

   if(InpZoneAnchorMode == ZR_ANCHOR_ROLLING)
   {
      double eff_zw = GetEffectiveZoneWidth(zw, g_zr.turn_count - 1);
      if(eff_zw <= 0.0) return;

      double roll = g_zr.rolling_anchor;
      bool triggered = false;
      ENUM_ORDER_TYPE add_type = ORDER_TYPE_BUY;

      double boundary_price = 0.0;
      if(mid >= roll + eff_zw)      { add_type = ORDER_TYPE_BUY;  triggered = true; boundary_price = roll + eff_zw; }
      else if(mid <= roll - eff_zw) { add_type = ORDER_TYPE_SELL; triggered = true; boundary_price = roll - eff_zw; }

      if(!triggered || !CanPlaceZROrder(mid)) return;

      double lot = CalculateZRLot(add_type, g_zr.last_lot);
      if(OpenZRPosition(add_type, lot))
      {
         ClearZROrderFreeze("order_success");
         g_zr.rolling_anchor = mid;
         g_zr.turn_count++;
         LockZROrder(mid);
      }
      else if(ShouldFreezeAfterOrderFail(boundary_price))
      {
         FreezeZROrderTurn(add_type, boundary_price, "rolling_add_failed_price_left_boundary");
      }
      return;
   }

   int new_zone = GetZoneLevel(mid, anchor, zw, InpZoneWidthFactor);
   if(new_zone == g_zr.current_zone) return;
   if(!CanPlaceZROrder(mid)) return;

   ENUM_ORDER_TYPE add_type;
   if(new_zone < g_zr.current_zone) add_type = ORDER_TYPE_BUY;
   else                             add_type = ORDER_TYPE_SELL;

   double boundary_price = ZRZoneBoundaryPrice(anchor, zw, InpZoneWidthFactor, new_zone);
   double lot = CalculateZRLot(add_type, g_zr.last_lot);
   if(OpenZRPosition(add_type, lot))
   {
      ClearZROrderFreeze("order_success");
      g_zr.current_zone = new_zone;
      g_zr.turn_count++;
      LockZROrder(mid);
   }
   else if(ShouldFreezeAfterOrderFail(boundary_price))
   {
      FreezeZROrderTurn(add_type, boundary_price, "fixed_anchor_add_failed_price_left_boundary");
   }
}

// Backward compatible overload: default to RANGE x SMALL_PROFIT when parent EA has no router yet.
void HandleZoneRecovery()
{
   HandleZoneRecovery(STATE_RANGE, SLOT_SMALL_PROFIT);
}

//====================================================================
// Trade transaction hook
//====================================================================
void OnTradeTransactionZR(const MqlTradeTransaction &trans,
                          const MqlTradeRequest &request,
                          const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_IN) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagicNumber) return;

   double atr_buf[1];
   if(m_zr_atr_handle != INVALID_HANDLE && CopyBuffer(m_zr_atr_handle, 0, 0, 1, atr_buf) >= 1 && atr_buf[0] > 0.0)
      g_zr_fixed_zone_width = atr_buf[0] * InpZoneATRMultiplier;
}

//====================================================================
// Lifecycle hooks
//====================================================================
bool InitZoneRecoveryModule()
{
   ResetZoneRecovery();

   m_zr_atr_handle = iATR(_Symbol, InpZoneATRTF, InpZoneATRPeriod);
   if(m_zr_atr_handle == INVALID_HANDLE)
   {
      Print("ZR_INIT_FAIL | ATR handle creation failed");
      return false;
   }

   m_zr_adx_handle = iADX(_Symbol, InpZRTrendTF, InpZRADXPeriod);
   if(m_zr_adx_handle == INVALID_HANDLE)
      Print("ZR_WARN | ADX handle creation failed; trend guard weakened");

   m_zr_fast_ema_handle = iMA(_Symbol, InpZRTrendTF, InpZRFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(m_zr_fast_ema_handle == INVALID_HANDLE)
      Print("ZR_WARN | fast EMA handle creation failed; trend guard weakened");

   m_zr_slow_ema_handle = iMA(_Symbol, InpZRTrendTF, InpZRSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(m_zr_slow_ema_handle == INVALID_HANDLE)
      Print("ZR_WARN | slow EMA handle creation failed; trend guard weakened");

   Print("ZR_INIT_OK | AMOS ZR Rescue Module v1.01 loaded");
   return true;
}

void DeinitZoneRecoveryModule()
{
   if(m_zr_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(m_zr_atr_handle);
      m_zr_atr_handle = INVALID_HANDLE;
   }
   if(m_zr_adx_handle != INVALID_HANDLE)
   {
      IndicatorRelease(m_zr_adx_handle);
      m_zr_adx_handle = INVALID_HANDLE;
   }
   if(m_zr_fast_ema_handle != INVALID_HANDLE)
   {
      IndicatorRelease(m_zr_fast_ema_handle);
      m_zr_fast_ema_handle = INVALID_HANDLE;
   }
   if(m_zr_slow_ema_handle != INVALID_HANDLE)
   {
      IndicatorRelease(m_zr_slow_ema_handle);
      m_zr_slow_ema_handle = INVALID_HANDLE;
   }
}

#endif // __AMOS_ZR_RESCUE_MODULE_V1_01__
//+------------------------------------------------------------------+
