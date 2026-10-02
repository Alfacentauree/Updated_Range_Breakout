//+------------------------------------------------------------------+
//|                                           RangeBreakout_EA.mq5   |
//|                             Copyright 2026, Advanced Algo Trader |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2026, Advanced Algo Trader"
#property link        "https://www.mql5.com"
#property version     "1.00"
#property description "Time-Based Daily Range Breakout Expert Advisor for MetaTrader 5"
#property description "Strictly MQL5 with Dynamic Range SL/TP, OCO Logic, and Time-Based Exit"

//--- Include Standard MQL5 Trade Classes (No MT4 code)
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUM DEFINITIONS                                                 |
//+------------------------------------------------------------------+
enum ENUM_RISK_MODE
{
   RISK_FIXED_AMOUNT    = 0, // Fixed Monetary Risk ($/€ per trade)
   RISK_PERCENT_BALANCE = 1, // Percentage of Account Balance (%)
   RISK_PERCENT_EQUITY  = 2  // Percentage of Account Equity (%)
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

//--- 1. Range Time Settings (Integers for Easy Tester Optimization)
input group "=== 1. Range Time Settings ==="
input int    InpRangeStartHour    = 3;        // Range Start Hour (0 - 23)
input int    InpRangeStartMin     = 0;        // Range Start Minute (0 - 59)
input int    InpRangeEndHour      = 6;        // Range End Hour (0 - 23)
input int    InpRangeEndMin       = 0;        // Range End Minute (0 - 59)
input int    InpCloseAllHour      = 20;       // Close All Hour (0 - 23)
input int    InpCloseAllMin       = 0;        // Close All Minute (0 - 59)
input int    InpEntryToleranceMin = 30;       // Max Mins Past Range End for Entry (0 = unlimited)

//--- 2. Risk & Money Management Settings
input group "=== 2. Risk & Money Management ==="
input ENUM_RISK_MODE InpRiskMode  = RISK_FIXED_AMOUNT; // Risk Mode (Fixed Money or % Risk)
input double InpRiskAmount        = 50.0;     // Fixed Monetary Risk ($/€ per trade)
input double InpRiskPercent       = 1.0;      // Risk Percentage per trade (e.g. 1.0 = 1%)
input double InpSLRangeFactor     = 1.0;      // SL Range Factor (SL Dist = Factor * Range)
input double InpTPRangeFactor     = 1.5;      // TP Range Factor (TP Dist = Factor * Range)
input bool   InpWithoutTP         = false;    // Trade Without Take-Profit (Run Open)
input double InpMaxSpreadPoints   = 50.0;     // Max Spread Allowed in Points (0 = disabled)

//--- 3. Visuals & Chart Display
input group "=== 3. Visual Settings ==="
input bool   InpDrawVisuals       = true;     // Draw Range & Breakout Levels
input color  InpBoxColor          = clrDodgerBlue; // Range Box / Outline Color
input color  InpBuyColor          = clrMediumSeaGreen; // High / Buy Level Color
input color  InpSellColor         = clrCrimson;    // Low / Sell Level Color
input int    InpLineWidth         = 2;        // Breakout Level Line Width
input bool   InpShowDashboard     = true;     // Show On-Chart HUD Status

//--- 4. EA Execution & Magic Number
input group "=== 4. EA Execution Settings ==="
input bool   InpEnableOCO         = true;     // Enable OCO (true = 1 Side Only, false = Allow Both Sides)
input ulong  InpMagicNumber       = 20260930; // Magic Number
input ulong  InpDeviationPoints   = 10;       // Max Slippage in Points
input string InpTradeComment      = "RBO_MQL5"; // Trade Order Comment

//+------------------------------------------------------------------+
//| GLOBAL OBJECTS & STATE VARIABLES                                 |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  positionInfo;
COrderInfo     orderInfo;

// Daily Tracking State
int      g_last_day_id            = -1;
bool     g_range_calculated       = false;
bool     g_orders_placed_today    = false;
bool     g_position_opened_today  = false;
bool     g_day_closed_executed    = false;

// Range Values for Current Day
double   g_range_high             = 0.0;
double   g_range_low              = 0.0;
double   g_range_size             = 0.0;
double   g_calculated_lot         = 0.0;

// Object Name Prefix for Chart Visuals
const string PREFIX = "RBO_";

//+------------------------------------------------------------------+
//| Helper: Configure Broker Filling Mode                            |
//+------------------------------------------------------------------+
void SetProperFillingMode(CTrade &trade_obj, string symbol)
{
   uint filling = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if ((filling & SYMBOL_FILLING_FOK) != 0)
      trade_obj.SetTypeFilling(ORDER_FILLING_FOK);
   else if ((filling & SYMBOL_FILLING_IOC) != 0)
      trade_obj.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade_obj.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Helper: Normalize Price to Symbol Digits & Tick Size             |
//+------------------------------------------------------------------+
double NormalizePrice(double price)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tick_size > 0.0)
      return NormalizeDouble(MathRound(price / tick_size) * tick_size, _Digits);
   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
//| Helper: Convert Hours & Minutes of a Base Date into datetime     |
//+------------------------------------------------------------------+
datetime ConstructDateTime(datetime base_time, int hour, int minute)
{
   MqlDateTime dt;
   TimeToStruct(base_time, dt);
   dt.hour = hour;
   dt.min  = minute;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Calculate Start, End, and Close Datetimes for Today              |
//+------------------------------------------------------------------+
void GetScheduleTimes(datetime current_time, datetime &start_dt, datetime &end_dt, datetime &close_dt)
{
   start_dt = ConstructDateTime(current_time, InpRangeStartHour, InpRangeStartMin);
   end_dt   = ConstructDateTime(current_time, InpRangeEndHour, InpRangeEndMin);
   close_dt = ConstructDateTime(current_time, InpCloseAllHour, InpCloseAllMin);

   // Handle overnight range window (e.g. 22:00 to 02:00)
   if (end_dt <= start_dt)
   {
      if (current_time < end_dt)
         start_dt -= 86400; // Range started yesterday
      else
         end_dt += 86400;   // Range ends tomorrow
   }

   // Handle close time if set past midnight after end time
   if (close_dt <= end_dt)
   {
      close_dt += 86400;
   }
}

//+------------------------------------------------------------------+
//| Calculate Daily Range High and Low over [start_dt, end_dt)       |
//+------------------------------------------------------------------+
bool CalculateRange(datetime start_dt, datetime end_dt, double &high, double &low)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, false);

   // Fetch high-resolution M1 rates for exact minute-level precision
   int copied = CopyRates(_Symbol, PERIOD_M1, start_dt, end_dt, rates);
   if (copied <= 0)
   {
      // Fallback to current chart period if M1 is unavailable
      copied = CopyRates(_Symbol, _Period, start_dt, end_dt, rates);
      if (copied <= 0)
      {
         PrintFormat("Range Breakout: Failed to fetch rates between %s and %s. Error: %d",
                     TimeToString(start_dt), TimeToString(end_dt), GetLastError());
         return false;
      }
   }

   double max_high = -DBL_MAX;
   double min_low  = DBL_MAX;
   int valid_bars = 0;

   for (int i = 0; i < copied; i++)
   {
      // Include only bars opening within the range window [start_dt, end_dt)
      if (rates[i].time >= start_dt && rates[i].time < end_dt)
      {
         if (rates[i].high > max_high) max_high = rates[i].high;
         if (rates[i].low < min_low)   min_low  = rates[i].low;
         valid_bars++;
      }
   }

   if (valid_bars == 0 || max_high <= 0 || min_low >= DBL_MAX || max_high <= min_low)
   {
      PrintFormat("Range Breakout: Insufficient or invalid bars in window [%s - %s]. High: %f, Low: %f",
                  TimeToString(start_dt), TimeToString(end_dt), max_high, min_low);
      return false;
   }

   high = NormalizePrice(max_high);
   low  = NormalizePrice(min_low);
   return true;
}

//+------------------------------------------------------------------+
//| Helper: Get Effective Monetary Risk for Trade Sizing             |
//+------------------------------------------------------------------+
double GetEffectiveRiskMoney()
{
   if (InpRiskMode == RISK_FIXED_AMOUNT)
   {
      return InpRiskAmount;
   }
   else if (InpRiskMode == RISK_PERCENT_BALANCE)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      return balance * (InpRiskPercent / 100.0);
   }
   else if (InpRiskMode == RISK_PERCENT_EQUITY)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      return equity * (InpRiskPercent / 100.0);
   }
   return InpRiskAmount;
}

//+------------------------------------------------------------------+
//| Dynamic Lot Size Calculation based on Fixed or Percent Risk      |
//+------------------------------------------------------------------+
double CalculateLotSize(ENUM_ORDER_TYPE order_type, double entry_price, double sl_price)
{
   double risk_money = GetEffectiveRiskMoney();
   if (risk_money <= 0.0)
      return 0.0;

   double sl_distance = MathAbs(entry_price - sl_price);
   if (sl_distance <= 0.0)
      return 0.0;

   double raw_lots = 0.0;
   double profit_1_lot = 0.0;

   // 1. Primary Method: MT5 native OrderCalcProfit (takes currency conversions & specs into account)
   if (OrderCalcProfit(order_type, _Symbol, 1.0, entry_price, sl_price, profit_1_lot) && profit_1_lot < 0.0)
   {
      double loss_1_lot = MathAbs(profit_1_lot);
      if (loss_1_lot > 0.0)
         raw_lots = risk_money / loss_1_lot;
   }
   else
   {
      // 2. Secondary Fallback: Tick Size and Tick Value
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if (tick_value <= 0.0)
         tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

      if (tick_size > 0.0 && tick_value > 0.0)
      {
         double ticks = sl_distance / tick_size;
         double loss_1_lot = ticks * tick_value;
         if (loss_1_lot > 0.0)
            raw_lots = risk_money / loss_1_lot;
      }
   }

   if (raw_lots <= 0.0)
   {
      Print("Range Breakout: Unable to calculate lot size from risk parameters.");
      return 0.0;
   }

   // Symbol volume constraints
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (step_lot <= 0.0) step_lot = 0.01;

   // Quantize down with MathFloor to ensure risk does not exceed InpRiskAmount
   double lots = MathFloor(raw_lots / step_lot) * step_lot;

   // Determine decimal digits of volume step
   int lot_digits = 0;
   double s = step_lot;
   while (s < 1.0 && lot_digits < 8)
   {
      s *= 10.0;
      lot_digits++;
   }
   lots = NormalizeDouble(lots, lot_digits);

   // Clamp within broker limits
   if (lots < min_lot) lots = min_lot;
   if (lots > max_lot) lots = max_lot;

   return lots;
}

//+------------------------------------------------------------------+
//| Delete All Remaining Pending Orders with EA Magic Number         |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (orderInfo.SelectByIndex(i))
      {
         if (orderInfo.Symbol() == _Symbol && orderInfo.Magic() == InpMagicNumber)
         {
            ulong ticket = orderInfo.Ticket();
            if (trade.OrderDelete(ticket))
            {
               PrintFormat("Range Breakout: Deleted pending order #%I64u", ticket);
            }
            else
            {
               PrintFormat("Range Breakout: Failed to delete pending order #%I64u. Error: %u",
                           ticket, trade.ResultRetcode());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close All Open Positions with EA Magic Number                    |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if (positionInfo.SelectByIndex(i))
      {
         if (positionInfo.Symbol() == _Symbol && positionInfo.Magic() == InpMagicNumber)
         {
            ulong ticket = positionInfo.Ticket();
            if (trade.PositionClose(ticket))
            {
               PrintFormat("Range Breakout: Closed position #%I64u", ticket);
            }
            else
            {
               PrintFormat("Range Breakout: Failed to close position #%I64u. Error: %u",
                           ticket, trade.ResultRetcode());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Chart Visuals: Draw Daily Range Box and Breakout Lines           |
//+------------------------------------------------------------------+
void DrawRangeVisuals(datetime start_dt, datetime end_dt, datetime close_dt, double high, double low)
{
   if (!InpDrawVisuals) return;

   string day_str = TimeToString(start_dt, TIME_DATE);
   string box_name  = PREFIX + "Box_"  + day_str;
   string high_name = PREFIX + "High_" + day_str;
   string low_name  = PREFIX + "Low_"  + day_str;
   string lbl_high  = PREFIX + "LblH_" + day_str;
   string lbl_low   = PREFIX + "LblL_" + day_str;

   // 1. Range Rectangle Box
   if (ObjectFind(0, box_name) < 0)
      ObjectCreate(0, box_name, OBJ_RECTANGLE, 0, start_dt, high, end_dt, low);
   else
   {
      ObjectMove(0, box_name, 0, start_dt, high);
      ObjectMove(0, box_name, 1, end_dt, low);
   }
   ObjectSetInteger(0, box_name, OBJPROP_COLOR, InpBoxColor);
   ObjectSetInteger(0, box_name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, box_name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, box_name, OBJPROP_BACK, true);
   ObjectSetInteger(0, box_name, OBJPROP_FILL, true);
   ObjectSetInteger(0, box_name, OBJPROP_SELECTABLE, false);

   // 2. High Line (Buy Stop breakout level extended to Close All time)
   if (ObjectFind(0, high_name) < 0)
      ObjectCreate(0, high_name, OBJ_TREND, 0, start_dt, high, close_dt, high);
   else
   {
      ObjectMove(0, high_name, 0, start_dt, high);
      ObjectMove(0, high_name, 1, close_dt, high);
   }
   ObjectSetInteger(0, high_name, OBJPROP_COLOR, InpBuyColor);
   ObjectSetInteger(0, high_name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, high_name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, high_name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, high_name, OBJPROP_SELECTABLE, false);

   // 3. Low Line (Sell Stop breakout level extended to Close All time)
   if (ObjectFind(0, low_name) < 0)
      ObjectCreate(0, low_name, OBJ_TREND, 0, start_dt, low, close_dt, low);
   else
   {
      ObjectMove(0, low_name, 0, start_dt, low);
      ObjectMove(0, low_name, 1, close_dt, low);
   }
   ObjectSetInteger(0, low_name, OBJPROP_COLOR, InpSellColor);
   ObjectSetInteger(0, low_name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, low_name, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, low_name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, low_name, OBJPROP_SELECTABLE, false);

   // 4. Text Labels
   double points = (high - low) / _Point;
   string text_h = StringFormat(" Range High: %.*f (Buy Breakout)", _Digits, high);
   string text_l = StringFormat(" Range Low: %.*f (Sell Breakout) | Size: %.1f pts", _Digits, low, points);

   if (ObjectFind(0, lbl_high) < 0)
      ObjectCreate(0, lbl_high, OBJ_TEXT, 0, end_dt, high);
   else
      ObjectMove(0, lbl_high, 0, end_dt, high);
   ObjectSetString(0, lbl_high, OBJPROP_TEXT, text_h);
   ObjectSetInteger(0, lbl_high, OBJPROP_COLOR, InpBuyColor);
   ObjectSetInteger(0, lbl_high, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, lbl_high, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);

   if (ObjectFind(0, lbl_low) < 0)
      ObjectCreate(0, lbl_low, OBJ_TEXT, 0, end_dt, low);
   else
      ObjectMove(0, lbl_low, 0, end_dt, low);
   ObjectSetString(0, lbl_low, OBJPROP_TEXT, text_l);
   ObjectSetInteger(0, lbl_low, OBJPROP_COLOR, InpSellColor);
   ObjectSetInteger(0, lbl_low, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, lbl_low, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Remove All Visual Objects Created by the EA                      |
//+------------------------------------------------------------------+
void CleanUpVisuals()
{
   ObjectsDeleteAll(0, PREFIX);
   Comment("");
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| On-Chart HUD Status Dashboard                                    |
//+------------------------------------------------------------------+
void UpdateDashboard(datetime now, datetime start_dt, datetime end_dt, datetime close_dt)
{
   if (!InpShowDashboard) return;

   string status_str = "Waiting for Range Start";
   if (now >= close_dt || g_day_closed_executed)
      status_str = "Day Closed (Done until tomorrow)";
   else if (g_position_opened_today)
      status_str = "Position Active (Trade In Progress)";
   else if (g_orders_placed_today)
      status_str = InpEnableOCO ? "Pending Orders Active (Monitoring OCO)" : "Pending Orders Active (Both Sides)";
   else if (now >= end_dt)
      status_str = "Evaluating Breakout";
   else if (now >= start_dt)
      status_str = "Range Window Forming...";

   int open_pos_count = 0;
   for (int i = 0; i < PositionsTotal(); i++)
   {
      if (positionInfo.SelectByIndex(i))
      {
         if (positionInfo.Symbol() == _Symbol && positionInfo.Magic() == InpMagicNumber)
            open_pos_count++;
      }
   }

   int pending_order_count = 0;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (orderInfo.SelectByIndex(i))
      {
         if (orderInfo.Symbol() == _Symbol && orderInfo.Magic() == InpMagicNumber)
            pending_order_count++;
      }
   }

   string tp_str = InpWithoutTP ? "None (Open Runner)" : StringFormat("%.2fx Range (%.1f pts)", InpTPRangeFactor, (g_range_size * InpTPRangeFactor) / _Point);
   string sl_str = StringFormat("%.2fx Range (%.1f pts)", InpSLRangeFactor, (g_range_size * InpSLRangeFactor) / _Point);

   string risk_str = "";
   double effective_risk = GetEffectiveRiskMoney();
   if (InpRiskMode == RISK_FIXED_AMOUNT)
      risk_str = StringFormat("Fixed $%.2f", InpRiskAmount);
   else if (InpRiskMode == RISK_PERCENT_BALANCE)
      risk_str = StringFormat("%.2f%% of Bal ($%.2f)", InpRiskPercent, effective_risk);
   else
      risk_str = StringFormat("%.2f%% of Eq ($%.2f)", InpRiskPercent, effective_risk);

   string text = "";
   text += "========================================================\n";
   text += "       TIME-BASED RANGE BREAKOUT EA (MQL5)              \n";
   text += "========================================================\n";
   text += StringFormat("  Server Time:      %s\n", TimeToString(now, TIME_DATE | TIME_SECONDS));
   text += StringFormat("  Range Window:     %02d:%02d -> %02d:%02d\n", InpRangeStartHour, InpRangeStartMin, InpRangeEndHour, InpRangeEndMin);
   text += StringFormat("  Close All Time:   %02d:%02d\n", InpCloseAllHour, InpCloseAllMin);
   text += StringFormat("  Current Phase:    %s\n", status_str);
   text += "--------------------------------------------------------\n";
   if (g_range_calculated)
   {
      text += StringFormat("  Range High:       %.*f\n", _Digits, g_range_high);
      text += StringFormat("  Range Low:        %.*f\n", _Digits, g_range_low);
      text += StringFormat("  Range Size:       %.1f points (%.*f)\n", g_range_size / _Point, _Digits, g_range_size);
      text += StringFormat("  Stop Loss:        %s\n", sl_str);
      text += StringFormat("  Take Profit:      %s\n", tp_str);
      text += StringFormat("  Risk Settings:    %s  |  Calculated Lot: %.2f\n", risk_str, g_calculated_lot);
   }
   else
   {
      text += "  Range Info:       [Awaiting Range End Time]\n";
      text += StringFormat("  Risk Settings:    %s\n", risk_str);
   }
   text += "--------------------------------------------------------\n";
   text += StringFormat("  Execution Mode:   %s\n", InpEnableOCO ? "OCO (1 Side Only)" : "Both Sides Allowed (No Cancel)");
   text += StringFormat("  Open Positions:   %d  |  Pending Orders: %d\n", open_pos_count, pending_order_count);
   text += StringFormat("  Traded Today:     %s  |  Day Finished: %s\n",
                        g_orders_placed_today ? (InpEnableOCO ? "Yes (1 Trade / Day)" : "Yes (Both Sides Active)") : "No",
                        g_day_closed_executed ? "Yes" : "No");
   text += "========================================================";

   Comment(text);
}

//+------------------------------------------------------------------+
//| Check and Execute Entry at Range End Time                        |
//+------------------------------------------------------------------+
void ProcessRangeEndEntry(datetime start_dt, datetime end_dt, datetime close_dt)
{
   // Check entry tolerance limit
   if (InpEntryToleranceMin > 0)
   {
      datetime max_entry_time = end_dt + (InpEntryToleranceMin * 60);
      if (TimeCurrent() > max_entry_time)
      {
         PrintFormat("Range Breakout: Range End was more than %d minutes ago. Skipping today's entry.", InpEntryToleranceMin);
         g_orders_placed_today = true;
         return;
      }
   }

   // Check spread filter
   MqlTick tick;
   if (!SymbolInfoTick(_Symbol, tick))
   {
      Print("Range Breakout: Failed to get current tick.");
      return;
   }

   double current_spread = (tick.ask - tick.bid) / _Point;
   if (InpMaxSpreadPoints > 0.0 && current_spread > InpMaxSpreadPoints)
   {
      PrintFormat("Range Breakout: Spread too high (%.1f points > max %.1f). Skipping entry.",
                  current_spread, InpMaxSpreadPoints);
      return;
   }

   // Calculate today's range
   if (!CalculateRange(start_dt, end_dt, g_range_high, g_range_low))
   {
      Print("Range Breakout: Range calculation failed. Entry aborted.");
      return;
   }

   g_range_size = g_range_high - g_range_low;
   g_range_calculated = true;

   // Draw chart visuals
   DrawRangeVisuals(start_dt, end_dt, close_dt, g_range_high, g_range_low);

   // Dynamic SL and TP distances based on range size
   double sl_dist = g_range_size * InpSLRangeFactor;
   double tp_dist = InpWithoutTP ? 0.0 : (g_range_size * InpTPRangeFactor);

   // Minimum broker stop level distance
   int stop_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop_dist = stop_level * _Point;

   //-----------------------------------------------------------------
   // RULE 2: Breakout detection vs Pending Orders
   //-----------------------------------------------------------------
   // Condition A: Price already broke out above Range High -> Instant Market BUY
   if (tick.ask >= g_range_high - min_stop_dist)
   {
      double entry_price = tick.ask;
      double sl_price = NormalizePrice(entry_price - sl_dist);
      double tp_price = InpWithoutTP ? 0.0 : NormalizePrice(entry_price + tp_dist);

      double lots = CalculateLotSize(ORDER_TYPE_BUY, entry_price, sl_price);
      if (lots <= 0.0)
      {
         Print("Range Breakout: Calculated lot size is 0. Cannot open Market BUY.");
         return;
      }
      g_calculated_lot = lots;

      PrintFormat("Range Breakout: Price (Ask: %.*f) already broken out above Range High (%.*f). Opening Market BUY!",
                  _Digits, entry_price, _Digits, g_range_high);

      if (trade.Buy(lots, _Symbol, entry_price, sl_price, tp_price, InpTradeComment))
      {
         g_orders_placed_today = true;
         g_position_opened_today = true;
         PrintFormat("Range Breakout: Market BUY executed. Ticket: #%I64u, Lots: %.2f, SL: %.*f, TP: %.*f",
                     trade.ResultDeal(), lots, _Digits, sl_price, _Digits, tp_price);
      }
      else
      {
         PrintFormat("Range Breakout: Market BUY failed. Retcode: %u", trade.ResultRetcode());
      }

      // If user enabled Both Sides mode, place the opposing Sell Stop at Range Low
      if (!InpEnableOCO && tick.bid > g_range_low + min_stop_dist)
      {
         double sell_entry = g_range_low;
         double sell_sl    = NormalizePrice(sell_entry + sl_dist);
         double sell_tp    = InpWithoutTP ? 0.0 : NormalizePrice(sell_entry - tp_dist);
         double sell_lots  = CalculateLotSize(ORDER_TYPE_SELL, sell_entry, sell_sl);
         if (sell_lots > 0.0)
         {
            if (trade.SellStop(sell_lots, sell_entry, _Symbol, sell_sl, sell_tp, ORDER_TIME_GTC, 0, InpTradeComment))
            {
               PrintFormat("Range Breakout (Both Sides Mode): Placed opposing Sell Stop #%I64u @ %.*f | SL: %.*f | TP: %.*f",
                           trade.ResultOrder(), _Digits, sell_entry, _Digits, sell_sl, _Digits, sell_tp);
            }
         }
      }
      return;
   }

   // Condition B: Price already broke out below Range Low -> Instant Market SELL
   if (tick.bid <= g_range_low + min_stop_dist)
   {
      double entry_price = tick.bid;
      double sl_price = NormalizePrice(entry_price + sl_dist);
      double tp_price = InpWithoutTP ? 0.0 : NormalizePrice(entry_price - tp_dist);

      double lots = CalculateLotSize(ORDER_TYPE_SELL, entry_price, sl_price);
      if (lots <= 0.0)
      {
         Print("Range Breakout: Calculated lot size is 0. Cannot open Market SELL.");
         return;
      }
      g_calculated_lot = lots;

      PrintFormat("Range Breakout: Price (Bid: %.*f) already broken out below Range Low (%.*f). Opening Market SELL!",
                  _Digits, entry_price, _Digits, g_range_low);

      if (trade.Sell(lots, _Symbol, entry_price, sl_price, tp_price, InpTradeComment))
      {
         g_orders_placed_today = true;
         g_position_opened_today = true;
         PrintFormat("Range Breakout: Market SELL executed. Ticket: #%I64u, Lots: %.2f, SL: %.*f, TP: %.*f",
                     trade.ResultDeal(), lots, _Digits, sl_price, _Digits, tp_price);
      }
      else
      {
         PrintFormat("Range Breakout: Market SELL failed. Retcode: %u", trade.ResultRetcode());
      }

      // If user enabled Both Sides mode, place the opposing Buy Stop at Range High
      if (!InpEnableOCO && tick.ask < g_range_high - min_stop_dist)
      {
         double buy_entry  = g_range_high;
         double buy_sl     = NormalizePrice(buy_entry - sl_dist);
         double buy_tp     = InpWithoutTP ? 0.0 : NormalizePrice(buy_entry + tp_dist);
         double buy_lots   = CalculateLotSize(ORDER_TYPE_BUY, buy_entry, buy_sl);
         if (buy_lots > 0.0)
         {
            if (trade.BuyStop(buy_lots, buy_entry, _Symbol, buy_sl, buy_tp, ORDER_TIME_GTC, 0, InpTradeComment))
            {
               PrintFormat("Range Breakout (Both Sides Mode): Placed opposing Buy Stop #%I64u @ %.*f | SL: %.*f | TP: %.*f",
                           trade.ResultOrder(), _Digits, buy_entry, _Digits, buy_sl, _Digits, buy_tp);
            }
         }
      }
      return;
   }

   // Condition C: Price is strictly inside range -> Place Buy Stop & Sell Stop (OCO Pair)
   double buy_entry  = g_range_high;
   double buy_sl     = NormalizePrice(buy_entry - sl_dist);
   double buy_tp     = InpWithoutTP ? 0.0 : NormalizePrice(buy_entry + tp_dist);
   double buy_lots   = CalculateLotSize(ORDER_TYPE_BUY, buy_entry, buy_sl);

   double sell_entry = g_range_low;
   double sell_sl    = NormalizePrice(sell_entry + sl_dist);
   double sell_tp    = InpWithoutTP ? 0.0 : NormalizePrice(sell_entry - tp_dist);
   double sell_lots  = CalculateLotSize(ORDER_TYPE_SELL, sell_entry, sell_sl);

   if (buy_lots <= 0.0 || sell_lots <= 0.0)
   {
      Print("Range Breakout: Invalid lot sizes calculated for pending orders. Aborting.");
      return;
   }
   g_calculated_lot = buy_lots;

   bool buy_ok = trade.BuyStop(buy_lots, buy_entry, _Symbol, buy_sl, buy_tp, ORDER_TIME_GTC, 0, InpTradeComment);
   if (!buy_ok)
   {
      PrintFormat("Range Breakout: Failed to place Buy Stop. Retcode: %u", trade.ResultRetcode());
   }
   else
   {
      PrintFormat("Range Breakout: Placed Buy Stop #%I64u @ %.*f | SL: %.*f | TP: %.*f | Lots: %.2f",
                  trade.ResultOrder(), _Digits, buy_entry, _Digits, buy_sl, _Digits, buy_tp, buy_lots);
   }

   bool sell_ok = trade.SellStop(sell_lots, sell_entry, _Symbol, sell_sl, sell_tp, ORDER_TIME_GTC, 0, InpTradeComment);
   if (!sell_ok)
   {
      PrintFormat("Range Breakout: Failed to place Sell Stop. Retcode: %u", trade.ResultRetcode());
   }
   else
   {
      PrintFormat("Range Breakout: Placed Sell Stop #%I64u @ %.*f | SL: %.*f | TP: %.*f | Lots: %.2f",
                  trade.ResultOrder(), _Digits, sell_entry, _Digits, sell_sl, _Digits, sell_tp, sell_lots);
   }

   if (buy_ok || sell_ok)
   {
      g_orders_placed_today = true;
   }
}

//+------------------------------------------------------------------+
//| Check and Execute OCO Safety Sweep                               |
//+------------------------------------------------------------------+
void CheckOCOCondition()
{
   if (!InpEnableOCO) return;
   if (!g_orders_placed_today || g_day_closed_executed) return;

   // Check if we have an open position from our EA
   bool position_found = false;
   for (int i = 0; i < PositionsTotal(); i++)
   {
      if (positionInfo.SelectByIndex(i))
      {
         if (positionInfo.Symbol() == _Symbol && positionInfo.Magic() == InpMagicNumber)
         {
            position_found = true;
            break;
         }
      }
   }

   // If a position exists, delete all remaining pending orders (OCO rule)
   if (position_found)
   {
      g_position_opened_today = true;
      DeleteAllPendingOrders();
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate Parameter Inputs
   if (InpRangeStartHour < 0 || InpRangeStartHour > 23 ||
       InpRangeEndHour < 0   || InpRangeEndHour > 23   ||
       InpCloseAllHour < 0   || InpCloseAllHour > 23)
   {
      Print("Init Error: Hour parameters must be between 0 and 23.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if (InpRangeStartMin < 0 || InpRangeStartMin > 59 ||
       InpRangeEndMin < 0   || InpRangeEndMin > 59   ||
       InpCloseAllMin < 0   || InpCloseAllMin > 59)
   {
      Print("Init Error: Minute parameters must be between 0 and 59.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if (InpRangeStartHour == InpRangeEndHour && InpRangeStartMin == InpRangeEndMin)
   {
      Print("Init Error: Range Start Time cannot be equal to Range End Time.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if (InpRiskMode == RISK_FIXED_AMOUNT && InpRiskAmount <= 0.0)
   {
      Print("Init Error: Fixed Risk Amount must be greater than 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if ((InpRiskMode == RISK_PERCENT_BALANCE || InpRiskMode == RISK_PERCENT_EQUITY) && InpRiskPercent <= 0.0)
   {
      Print("Init Error: Risk Percentage must be greater than 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if (InpSLRangeFactor <= 0.0)
   {
      Print("Init Error: SL Range Factor must be greater than 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if (!InpWithoutTP && InpTPRangeFactor <= 0.0)
   {
      Print("Init Error: TP Range Factor must be greater than 0 when Without TP is false.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Initialize CTrade Settings
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   SetProperFillingMode(trade, _Symbol);

   PrintFormat("Range Breakout EA initialized on %s. Magic: %I64u, Risk Mode: %d, SL Factor: %.2f, TP Factor: %.2f, OCO: %s",
               _Symbol, InpMagicNumber, (int)InpRiskMode, InpSLRangeFactor, InpTPRangeFactor, InpEnableOCO ? "Enabled" : "Disabled (Both Sides Allowed)");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CleanUpVisuals();
   PrintFormat("Range Breakout EA deinitialized. Reason code: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert Trade Transaction Event Handler (Fast Event-Driven OCO)   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Listen for Deal Add events to execute OCO instantly upon order execution
   if (trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if (HistoryDealSelect(trans.deal))
      {
         string deal_symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
         ulong  deal_magic  = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

         if (deal_symbol == _Symbol && deal_magic == InpMagicNumber && entry == DEAL_ENTRY_IN)
         {
            g_position_opened_today = true;
            if (InpEnableOCO)
            {
               PrintFormat("OCO Event: Entry Deal #%I64u confirmed. Immediately deleting opposite pending order.", trans.deal);
               DeleteAllPendingOrders();
            }
            else
            {
               PrintFormat("Entry Deal #%I64u confirmed. Both Sides Mode: Keeping opposite pending order active.", trans.deal);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function (Runtime Efficient Execution)               |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int current_day_id = dt.year * 10000 + dt.mon * 100 + dt.day;

   // 1. Date Rollover: Reset daily state on each new calendar day
   if (current_day_id != g_last_day_id)
   {
      g_last_day_id           = current_day_id;
      g_range_calculated      = false;
      g_orders_placed_today   = false;
      g_position_opened_today = false;
      g_day_closed_executed   = false;
      g_range_high            = 0.0;
      g_range_low             = 0.0;
      g_range_size            = 0.0;
      g_calculated_lot        = 0.0;
   }

   // 2. Schedule Times for Current Day
   datetime start_dt, end_dt, close_dt;
   GetScheduleTimes(now, start_dt, end_dt, close_dt);

   // 3. Fast Exit: If Close All Time reached for today
   if (now >= close_dt)
   {
      if (!g_day_closed_executed)
      {
         PrintFormat("Close All Time reached (%s). Forcefully closing all positions and pending orders.",
                     TimeToString(now));
         CloseAllPositions();
         DeleteAllPendingOrders();
         g_day_closed_executed = true;
      }
      UpdateDashboard(now, start_dt, end_dt, close_dt);
      return; // Fast return: No new trades allowed until next day's range
   }

   // 4. Fast Exit: If current time is prior to range start
   if (now < start_dt)
   {
      UpdateDashboard(now, start_dt, end_dt, close_dt);
      return; // Waiting for range to begin
   }

   // 5. Forming Window: Range is currently being formed [start_dt, end_dt)
   if (now < end_dt)
   {
      // Optional: Real-time visual update during range formation
      if (InpDrawVisuals)
      {
         double cur_h, cur_l;
         if (CalculateRange(start_dt, now, cur_h, cur_l))
         {
            g_range_high = cur_h;
            g_range_low  = cur_l;
            g_range_size = cur_h - cur_l;
            g_range_calculated = true;
            DrawRangeVisuals(start_dt, end_dt, close_dt, cur_h, cur_l);
         }
      }
      UpdateDashboard(now, start_dt, end_dt, close_dt);
      return;
   }

   // 6. Range End reached [end_dt <= now < close_dt]
   // Check OCO logic if orders were already placed
   if (g_orders_placed_today)
   {
      if (InpEnableOCO)
         CheckOCOCondition();
      UpdateDashboard(now, start_dt, end_dt, close_dt);
      return; // Trade for today already managed. Exit early!
   }

   // 7. Place Breakout Orders (Pending or Market)
   ProcessRangeEndEntry(start_dt, end_dt, close_dt);

   // Update HUD Dashboard
   UpdateDashboard(now, start_dt, end_dt, close_dt);
}
//+------------------------------------------------------------------+
