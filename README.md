# Time-Based Daily Range Breakout EA (MetaTrader 5)

An Expert Advisor for **MetaTrader 5** written exclusively in **pure MQL5** (with zero MT4 legacy code). It implements a **Time-Based Daily Range Breakout** strategy with dynamic range-based Stop-Loss (SL) and Take-Profit (TP), automatic monetary risk lot sizing, One-Cancels-Other (OCO) order execution, and end-of-day time exits.

---

## 🌟 Key Features

1. **Precision Time-Window Range Calculation**
   - User inputs for **Range Start Time** and **Range End Time** using integer hours and minutes (0–23 and 0–59) for straightforward step-optimization in the MT5 Strategy Tester.
   - Accurately identifies the highest high and lowest low formed during this exact window every trading day.
   - High-resolution M1 data is utilized to guarantee minute-level precision regardless of which chart timeframe the EA is attached to.

2. **Smart Breakout & Entry Management**
   - **Inside Range**: Places a **Buy Stop** at the range High and a **Sell Stop** at the range Low right when the Range End Time arrives.
   - **Already Broken Out**: If the price has already broken beyond the High or Low when Range End Time is reached (or is closer than broker minimum stop levels), it opens an immediate **Market Order** in the direction of the breakout.
   - **Strict 1 Trade Per Day Rule**: Enforces only one trade direction per calendar day.

3. **One-Cancels-Other (OCO) vs. Both Sides Mode**
   - **OCO Mode (`InpEnableOCO = true`)**: Dual-layer OCO architecture ensures only one breakout side is traded per day. When one side executes, the opposing pending order is instantly cancelled.
   - **Both Sides Mode (`InpEnableOCO = false`)**: Allows both Buy and Sell breakout orders to remain active in the same session. If Buy triggers, Sell Stop remains intact, allowing traders to capture market reversals or two-way daily expansion without deleting orders.

4. **Dynamic Risk-Based Lot Sizing (Cash or % Risk)**
   - Supports 3 risk modes via `InpRiskMode`:
     - **Fixed Monetary Risk**: Specify cash risk directly in account deposit currency (e.g. $50).
     - **Balance Percentage**: Calculate risk dynamically from account balance (e.g. 1.0% or 2.0%).
     - **Equity Percentage**: Calculate risk dynamically from live account equity.
   - Lot sizes are dynamically calculated using MT5's native `OrderCalcProfit` (with secondary tick-value fallback) based on the exact stop-loss distance.
   - Automatically conforms to broker lot constraints: `SYMBOL_VOLUME_MIN`, `SYMBOL_VOLUME_MAX`, and `SYMBOL_VOLUME_STEP`.
   - Uses `MathFloor` quantization to guarantee monetary risk does not exceed your specified limit.

5. **Dynamic Range Factors for SL and TP**
   - Does not use static pips. Stop Loss and Take Profit distances adapt dynamically each day to market volatility based on the calculated range size ($High - Low$):
     $$\text{SL Distance} = \text{Range Size} \times \text{SL Range Factor}$$
     $$\text{TP Distance} = \text{Range Size} \times \text{TP Range Factor}$$
   - Includes a **Without Take-Profit** toggle (`InpWithoutTP`) to allow trades to run open until hit by Stop-Loss or closed by the Time Exit.

6. **End-of-Day Time Exit**
   - Forcefully closes any open position and purges all active pending orders at the designated **Close All Time** (e.g., 20:00).
   - Locks trading until the next day's range window begins.

7. **Visual Chart Display & HUD Dashboard**
   - Draws a semi-transparent shaded range box covering $[Start, End]$ and extends breakout levels to the Close All Time.
   - Displays a clean real-time status dashboard directly on the chart with live metrics (Range High/Low/Size, calculated lot size, effective risk, open orders, current phase).
   - Automatically cleans up all chart objects upon deinitialization (`OnDeinit`).

8. **Runtime Efficient & Broker Adaptive**
   - Early returns in `OnTick` eliminate unnecessary CPU cycles.
   - Automatic execution filling mode detection (`ORDER_FILLING_FOK`, `ORDER_FILLING_IOC`, `ORDER_FILLING_RETURN`) ensures compatibility across all Forex, CFD, Indices, Crypto, and Futures brokers.

---

## 📋 Input Parameters

| Parameter | Type | Default | Description |
| :--- | :---: | :---: | :--- |
| **`InpRangeStartHour`** | `int` | `3` | Range Start Hour (0 – 23) |
| **`InpRangeStartMin`** | `int` | `0` | Range Start Minute (0 – 59) |
| **`InpRangeEndHour`** | `int` | `6` | Range End Hour (0 – 23) |
| **`InpRangeEndMin`** | `int` | `0` | Range End Minute (0 – 59) |
| **`InpCloseAllHour`** | `int` | `20` | Close All Hour (0 – 23) |
| **`InpCloseAllMin`** | `int` | `0` | Close All Minute (0 – 59) |
| **`InpEntryToleranceMin`** | `int` | `30` | Max minutes past Range End allowed to enter (0 = unlimited until Close All) |
| **`InpRiskMode`** | `enum` | `RISK_FIXED_AMOUNT` | Risk Mode: Fixed Cash ($), % of Balance, or % of Equity |
| **`InpRiskAmount`** | `double` | `50.0` | Fixed monetary risk per trade (used when Risk Mode = Fixed) |
| **`InpRiskPercent`** | `double` | `1.0` | Risk percentage per trade (used when Risk Mode = % of Balance/Equity) |
| **`InpSLRangeFactor`** | `double` | `1.0` | Stop Loss Factor (SL distance = `Range Size * Factor`) |
| **`InpTPRangeFactor`** | `double` | `1.5` | Take Profit Factor (TP distance = `Range Size * Factor`) |
| **`InpWithoutTP`** | `bool` | `false` | If `true`, trade has no TP and runs open until SL or Close All Time |
| **`InpMaxSpreadPoints`** | `double` | `50.0` | Max spread allowed in points (0 to disable spread check) |
| **`InpDrawVisuals`** | `bool` | `true` | Draw Range Box and Breakout Levels on the chart |
| **`InpBoxColor`** | `color` | `clrDodgerBlue` | Color of the range rectangle box |
| **`InpBuyColor`** | `color` | `clrMediumSeaGreen` | Color of the High breakout / Buy Stop level |
| **`InpSellColor`** | `color` | `clrCrimson` | Color of the Low breakout / Sell Stop level |
| **`InpLineWidth`** | `int` | `2` | Width of the breakout level trendlines |
| **`InpShowDashboard`** | `bool` | `true` | Show on-chart HUD information comment |
| **`InpEnableOCO`** | `bool` | `true` | `true` = OCO (1 side only), `false` = Allow both sides in 1 day (no cancellation) |
| **`InpMagicNumber`** | `ulong` | `20260930` | Unique EA magic number to track trades and orders |
| **`InpDeviationPoints`** | `ulong` | `10` | Maximum slippage allowed in points |
| **`InpTradeComment`** | `string` | `"RBO_MQL5"` | Comment attached to orders and deals |

---

## 🛠 Installation Instructions

1. Open **MetaTrader 5**.
2. Click **File -> Open Data Folder** (or press `Ctrl + Shift + D`).
3. Navigate to `MQL5/Experts/`.
4. Copy `RangeBreakout_EA.mq5` (source) and `RangeBreakout_EA.ex5` (compiled binary) into `MQL5/Experts/` (or a subfolder like `MQL5/Experts/Breakout/`).
5. In MT5, open the **Navigator** panel (`Ctrl + N`), right-click on **Expert Advisors**, and click **Refresh**.
6. Drag **RangeBreakout_EA** onto any chart (e.g., EURUSD, GBPUSD, XAUUSD, NAS100).
7. In the **Common** tab, ensure **Allow Algo Trading** is checked.
8. Set your desired hours, risk amount, and multipliers in the **Inputs** tab and click **OK**.

---

## 🔬 MT5 Strategy Tester & Optimization

Because all time parameters are integers (`InpRangeStartHour`, `InpRangeEndHour`, `InpCloseAllHour`, etc.), you can easily optimize:

1. Open the MT5 Strategy Tester (`Ctrl + R`).
2. Select `RangeBreakout_EA.ex5`.
3. In the **Inputs** tab, check the box next to:
   - `InpRangeStartHour`: Start = `0`, Step = `1`, Stop = `4`
   - `InpRangeEndHour`: Start = `5`, Step = `1`, Stop = `9`
   - `InpSLRangeFactor`: Start = `0.5`, Step = `0.25`, Stop = `1.5`
   - `InpTPRangeFactor`: Start = `1.0`, Step = `0.5`, Stop = `3.0`
4. Choose **Fast genetic based algorithm** or **Every tick based on real ticks**.
5. Click **Start** to find the optimal breakout session times and risk-reward ratios for your instrument.

---

## 🛡 Risk Management Example

Suppose:
- **Account Currency**: USD
- **Symbol**: EURUSD
- **InpRiskAmount**: `$50.00`
- **Range High**: `1.08500`
- **Range Low**: `1.08200`
- **Range Size**: `0.00300` (300 points / 30 pips)
- **InpSLRangeFactor**: `1.0` (SL distance = 300 points)
- **InpTPRangeFactor**: `1.5` (TP distance = 450 points)

When Range End is reached:
- **Buy Stop**: Entry = `1.08500`, SL = `1.08200`, TP = `1.08950`
- Loss per 1.0 lot on 300 points = $300.00
- Required Lot Size = $\frac{\$50.00}{\$300.00} = 0.1666 \to$ normalized to **0.16 Lots**.
- If Buy Stop triggers: Loss at SL is strictly capped at $\approx \$48.00 \le \$50.00$.
- Immediately upon trigger, the Sell Stop at `1.08200` is **cancelled (OCO)**.
- If neither SL nor TP is hit by `InpCloseAllHour:InpCloseAllMin`, the trade is forcefully closed at market.
