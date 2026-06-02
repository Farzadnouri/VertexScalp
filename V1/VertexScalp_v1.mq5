//+------------------------------------------------------------------+
//|                                            VertexScalp_v1.mq5    |
//|       Prop-Firm-Safe BB Mean-Reversion Scalper — EURUSD M5       |
//|                                                                    |
//|  PROMPT 1 — Foundation                                             |
//|    • Input parameter groups (10 groups)                            |
//|    • TradeDirection enum                                           |
//|    • All 6 indicator handles with INVALID_HANDLE guard             |
//|    • CTrade / CPositionInfo / CAccountInfo objects                 |
//|    • State variables: DayStartBalance, LastTradeTime, TradingHalted|
//|    • OnInit  — handle creation + state init                        |
//|    • OnDeinit — IndicatorRelease for every handle                  |
//|  PROMPT 2 — Signal Engine                                          |
//|    • Global indicator buffer arrays (series-ordered, 3 bars)       |
//|    • RefreshIndicatorData() — single CopyBuffer pass per tick      |
//|    • GetCurrentSpread() — (Ask-Bid)/Point                          |
//|    • GetBuySignal()  — BB lower touch + RSI + SMA slope + MACD     |
//|    • GetSellSignal() — BB upper touch + RSI + SMA slope + MACD     |
//|    • OnTick wired: refresh → signal → PrintFormat log              |
//|  PROMPT 3 — ATR Volatility Gate + Chart Dashboard                  |
//|    • IsVolatilityOK() — manual ATR SMA + multiplier threshold      |
//|    • Dead-market guard (min ATR) + spread-spike guard              |
//|    • UpdateDashboard() — Comment() overlay on chart                |
//|    • OnTick: vol gate → signal → dashboard (every tick)            |
//|  PROMPT 4 — Trade Execution & Risk                                  |
//|    • MinBarsBetweenTrades input (default 3)                        |
//|    • CalculateLotSize() — risk-based sizing with broker normalise  |
//|    • HasOpenPosition / HasOpenBuy / HasOpenSell                    |
//|    • IsBarGapOK() — M5 bar count since LastTradeTime               |
//|    • OpenBuy() / OpenSell() — price, SL, TP, log                  |
//|    • OnTick wired: all 5 guards → open → UpdateLastTradeTime       |
//|  PROMPT 5 — Drawdown Protection System (prop-firm safety layer)    |
//|    • InitialBalance global — set once at OnInit, never changes     |
//|    • UpdateDayStartBalance() — static day-key, resets each day     |
//|    • GetDailyDrawdownPercent() / GetTotalDrawdownPercent()         |
//|    • CloseAllPositions() — full position sweep on limit breach     |
//|    • CheckDrawdownLimits() — Alert + halt + close on breach        |
//|    • Dashboard: DD%, status ACTIVE/HALTED, equity, day-start bal  |
//|    • OnTick: UpdateDayStartBalance → CheckDrawdownLimits first     |
//|  PROMPT 6 — Session Filter, News Blackout, Final Assembly          |
//|    • IsWithinTradingSession() — London + NY windows + GMT offset   |
//|    • IsNewsBlackout() — 3 configurable news times ± blackout mins  |
//|    • News_Hour/Minute_1-3 inputs (default -1 = disabled)           |
//|    • Consolidated 11-line Comment() dashboard                      |
//|    • OnTick: full 10-step ordered execution chain                  |
//+------------------------------------------------------------------+
#property copyright   "VertexScalp EA"
#property link        ""
#property version     "1.00"
#property description "Prop-firm-safe Bollinger Band mean-reversion scalper for EURUSD M5"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                       |
//+------------------------------------------------------------------+
enum ENUM_TRADE_DIRECTION
{
   BOTH      = 0,  // Both directions
   BUY_ONLY  = 1,  // Buy only
   SELL_ONLY = 2   // Sell only
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                   |
//+------------------------------------------------------------------+

// ── General Settings ────────────────────────────────────────────────
input group              "=== General Settings ==="
input int                   MagicNumber        = 123456;          // Magic Number
input string                EA_Comment         = "VertexScalp_v1"; // Order comment
input ENUM_TRADE_DIRECTION  TradeDirection          = BOTH;   // Trade direction
input int                   MinBarsBetweenTrades    = 4;      // Min M5 bars between entries

// ── Bollinger Bands ─────────────────────────────────────────────────
input group              "=== Bollinger Bands ==="
input int                   BB_Period          = 20;               // BB period
input double                BB_Deviation       = 2.0;              // BB standard deviations
input ENUM_APPLIED_PRICE    BB_Price           = PRICE_CLOSE;      // BB applied price

// ── RSI Filter ──────────────────────────────────────────────────────
input group              "=== RSI Filter ==="
input int                   RSI_Period         = 14;               // RSI period
input ENUM_APPLIED_PRICE    RSI_Price          = PRICE_CLOSE;      // RSI applied price
input double                RSI_UpLevel        = 60.0;             // RSI threshold for longs
input double                RSI_DownLevel      = 40.0;             // RSI threshold for shorts

// ── MACD Filter ─────────────────────────────────────────────────────
input group              "=== MACD Filter ==="
input bool                  Use_MACD           = false;            // Enable MACD filter
input int                   MACD_Fast          = 12;               // MACD fast EMA
input int                   MACD_Slow          = 26;               // MACD slow EMA
input int                   MACD_Signal        = 9;                // MACD signal period
input ENUM_APPLIED_PRICE    MACD_Price         = PRICE_CLOSE;      // MACD applied price

// ── SMA Trend Filter ────────────────────────────────────────────────
input group              "=== SMA Trend Filter ==="
input bool                  Use_SMA_Filter     = true;             // Enable SMA trend filter
input int                   SMA_Period         = 20;               // SMA period
input ENUM_APPLIED_PRICE    SMA_Price          = PRICE_CLOSE;      // SMA applied price

// ── ATR Volatility Gate ─────────────────────────────────────────────
input group              "=== ATR Volatility Gate ==="
input bool                  Use_ATR_Filter     = true;             // Enable ATR volatility gate
input int                   ATR_Period         = 14;               // ATR period
input int                   ATR_SMA_Period     = 20;               // SMA period applied to ATR
input double                ATR_Multiplier     = 0.75;             // ATR must be >= multiplier × ATR-SMA

// ── Risk Management ─────────────────────────────────────────────────
input group              "=== Risk Management ==="
input double                Risk_Percent       = 0.5;              // Risk per trade (% of balance)
input int                   SL_Points          = 80;               // Stop loss in points
input double                TP_RR              = 1.0;              // Take-profit risk:reward ratio
input int                   Max_Spread_Points  = 15;               // Max allowed spread (points)

// ── Drawdown Protection ─────────────────────────────────────────────
input group              "=== Drawdown Protection ==="
input double                Max_Daily_DD_Percent  = 4.0;           // Max daily drawdown (%)
input double                Max_Total_DD_Percent  = 8.0;           // Max total drawdown (%)

// ── Session Filter ──────────────────────────────────────────────────
input group              "=== Session Filter ==="
input bool                  Use_Session_Filter    = true;          // Enable session filter
input int                   London_Start_Hour     = 8;             // London open  (server hour)
input int                   London_End_Hour       = 17;            // London close (server hour)
input int                   NewYork_Start_Hour    = 13;            // New York open  (server hour)
input int                   NewYork_End_Hour      = 22;            // New York close (server hour)
input int                   GMT_Offset            = 0;             // Broker GMT offset (hours)

// ── News Blackout ───────────────────────────────────────────────────
input group              "=== News Blackout ==="
input bool                  Use_News_Blackout     = true;  // Enable news blackout
input int                   News_Blackout_Minutes = 30;    // Block window ± minutes around news
input int                   News_Hour_1           = -1;    // News event 1 hour   (-1 = disabled)
input int                   News_Minute_1         = 0;     // News event 1 minute
input int                   News_Hour_2           = -1;    // News event 2 hour   (-1 = disabled)
input int                   News_Minute_2         = 0;     // News event 2 minute
input int                   News_Hour_3           = -1;    // News event 3 hour   (-1 = disabled)
input int                   News_Minute_3         = 0;     // News event 3 minute

// ── ADX Kill Switch ──────────────────────────────────────────────────
input group              "=== ADX Kill Switch ==="
input bool   Use_ADX_Filter   = true;   // Enable ADX trend filter (blocks entries in trending markets)
input int    ADX_Period        = 14;     // ADX period
input double ADX_Threshold    = 30.0;   // ADX threshold: above = trending (blocked), below = ranging (allowed)

//+------------------------------------------------------------------+
//| INDICATOR HANDLES                                                  |
//+------------------------------------------------------------------+
int bb_handle;       // Bollinger Bands
int rsi_handle;      // RSI
int macd_handle;     // MACD
int sma_handle;      // SMA trend filter
int atr_handle;      // ATR
int atr_sma_handle;  // SMA applied to ATR buffer (volatility baseline)
int adx_handle;      // ADX kill switch

//+------------------------------------------------------------------+
//| TRADE OBJECTS                                                      |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  positionInfo;
CAccountInfo   accountInfo;

//+------------------------------------------------------------------+
//| STATE VARIABLES                                                    |
//+------------------------------------------------------------------+
double   InitialBalance;    // Balance captured once at OnInit — used for total DD
double   DayStartBalance;   // Balance snapshot reset each new calendar day
datetime LastTradeTime;     // Time of last executed trade
bool     TradingHalted;     // True when any drawdown limit has been breached

//+------------------------------------------------------------------+
//| INDICATOR BUFFER ARRAYS                                            |
//| Set as series: [0]=current (forming), [1]=last closed, [2]=prior  |
//+------------------------------------------------------------------+
double g_Open[], g_High[], g_Low[], g_Close[];
double g_BB_Middle[], g_BB_Upper[], g_BB_Lower[];
double g_RSI[];
double g_MACD_Main[], g_MACD_Sig[];
double g_SMA[];

//+------------------------------------------------------------------+
//| ATR DISPLAY CACHE  (populated by IsVolatilityOK each tick)        |
//+------------------------------------------------------------------+
double g_ATR_Current   = 0.0;   // ATR[1] — last closed bar
double g_ATR_SMA       = 0.0;   // Simple average of ATR over ATR_SMA_Period bars
double g_ATR_Threshold = 0.0;   // g_ATR_SMA * ATR_Multiplier
bool   g_VolGateOpen   = false; // Last result of IsVolatilityOK()
string g_LastSignal    = "NONE"; // Last evaluated signal: BUY / SELL / NONE

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // ── Trade object setup ──────────────────────────────────────────
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   // ── Create indicator handles ────────────────────────────────────

   bb_handle = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, BB_Price);
   if(bb_handle == INVALID_HANDLE)
   {
      Print("ERROR: iBands handle creation failed");
      return INIT_FAILED;
   }

   rsi_handle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, RSI_Price);
   if(rsi_handle == INVALID_HANDLE)
   {
      Print("ERROR: iRSI handle creation failed");
      return INIT_FAILED;
   }

   macd_handle = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, MACD_Price);
   if(macd_handle == INVALID_HANDLE)
   {
      Print("ERROR: iMACD handle creation failed");
      return INIT_FAILED;
   }

   sma_handle = iMA(_Symbol, PERIOD_CURRENT, SMA_Period, 0, MODE_SMA, SMA_Price);
   if(sma_handle == INVALID_HANDLE)
   {
      Print("ERROR: iMA (SMA trend) handle creation failed");
      return INIT_FAILED;
   }

   atr_handle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atr_handle == INVALID_HANDLE)
   {
      Print("ERROR: iATR handle creation failed");
      return INIT_FAILED;
   }

   // ATR SMA handle — optional optimisation; ATR SMA is calculated manually
   // in IsVolatilityOK() so this handle is never used for data.
   // Non-fatal: some broker builds reject the handle-as-applied-price technique.
   atr_sma_handle = iMA(_Symbol, PERIOD_CURRENT, ATR_SMA_Period, 0, MODE_SMA,
                        (ENUM_APPLIED_PRICE)atr_handle);
   if(atr_sma_handle == INVALID_HANDLE)
      Print("WARN: ATR SMA handle not created (manual SMA used — no impact on logic)");

   adx_handle = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   if(adx_handle == INVALID_HANDLE)
   {
      Print("ERROR: iADX handle creation failed");
      return INIT_FAILED;
   }

   // ── Initialise state ────────────────────────────────────────────
   InitialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);  // fixed reference, never resets
   DayStartBalance = InitialBalance;
   LastTradeTime   = 0;
   TradingHalted   = false;

   Print("VertexScalp_v1 initialized | Symbol: ", _Symbol,
         " | TF: ", EnumToString(Period()),
         " | Magic: ", MagicNumber);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(bb_handle);
   IndicatorRelease(rsi_handle);
   IndicatorRelease(macd_handle);
   IndicatorRelease(sma_handle);
   IndicatorRelease(atr_handle);
   IndicatorRelease(atr_sma_handle);
   IndicatorRelease(adx_handle);
   Comment("");   // clear chart overlay
}

//+------------------------------------------------------------------+
//| RefreshIndicatorData                                               |
//| Populates all global buffer arrays once per tick.                  |
//| Arrays are set as series before CopyBuffer so [0]=current bar.    |
//| Returns false if any copy fails (not enough history yet).          |
//+------------------------------------------------------------------+
bool RefreshIndicatorData()
{
   ArraySetAsSeries(g_Open,      true);
   ArraySetAsSeries(g_High,      true);
   ArraySetAsSeries(g_Low,       true);
   ArraySetAsSeries(g_Close,     true);
   ArraySetAsSeries(g_BB_Middle, true);
   ArraySetAsSeries(g_BB_Upper,  true);
   ArraySetAsSeries(g_BB_Lower,  true);
   ArraySetAsSeries(g_RSI,       true);
   ArraySetAsSeries(g_MACD_Main, true);
   ArraySetAsSeries(g_MACD_Sig,  true);
   ArraySetAsSeries(g_SMA,       true);

   if(CopyOpen (_Symbol, PERIOD_CURRENT, 0, 3, g_Open)      < 3) return false;
   if(CopyHigh (_Symbol, PERIOD_CURRENT, 0, 3, g_High)      < 3) return false;
   if(CopyLow  (_Symbol, PERIOD_CURRENT, 0, 3, g_Low)       < 3) return false;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 3, g_Close)     < 3) return false;
   if(CopyBuffer(bb_handle,   0, 0, 3, g_BB_Middle)         < 3) return false;
   if(CopyBuffer(bb_handle,   1, 0, 3, g_BB_Upper)          < 3) return false;
   if(CopyBuffer(bb_handle,   2, 0, 3, g_BB_Lower)          < 3) return false;
   if(CopyBuffer(rsi_handle,  0, 0, 3, g_RSI)               < 3) return false;
   if(CopyBuffer(macd_handle, 0, 0, 3, g_MACD_Main)         < 3) return false;
   if(CopyBuffer(macd_handle, 1, 0, 3, g_MACD_Sig)          < 3) return false;
   if(CopyBuffer(sma_handle,  0, 0, 3, g_SMA)               < 3) return false;

   return true;
}

//+------------------------------------------------------------------+
//| GetCurrentSpread                                                   |
//| Returns live spread in points.                                     |
//+------------------------------------------------------------------+
double GetCurrentSpread()
{
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID))
          / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
//| GetBuySignal                                                       |
//| All active conditions must pass. Uses index [1] (last closed bar). |
//+------------------------------------------------------------------+
bool GetBuySignal()
{
   // TradeDirection gate
   if(TradeDirection == SELL_ONLY) return false;

   // ── Spread filter ───────────────────────────────────────────────
   if(GetCurrentSpread() > (double)Max_Spread_Points) return false;

   // ── Bollinger Band: rejection confirmation ───────────────────────
   // log values on every check for debugging
   PrintFormat("BUY CHECK: BB_Lower[2]=%.2f low[2]=%.2f close[1]=%.2f open[1]=%.2f",
               g_BB_Lower[2], g_Low[2], g_Close[1], g_Open[1]);
   if(g_Low[2]   > g_BB_Lower[2]) return false;  // bar[2] low must touch lower band
   if(g_Close[1] <= g_BB_Lower[1]) return false; // bar[1] must close back above lower band
   if(g_Close[1] <= g_Open[1])    return false;  // bar[1] must be bullish (rejection confirmed)

   // ── RSI: oversold relative to DownLevel ─────────────────────────
   if(g_RSI[1] >= RSI_DownLevel) return false;

   // ── SMA slope: flat or turning up ───────────────────────────────
   // Accepts up to 0.1% decline to tolerate sideways markets
   if(Use_SMA_Filter)
   {
      if(g_SMA[1] < g_SMA[2] * 0.999) return false;
   }

   // ── MACD: bullish momentum (main > signal OR histogram rising) ───
   if(Use_MACD)
   {
      bool main_above   = (g_MACD_Main[1] > g_MACD_Sig[1]);
      bool hist_rising  = ((g_MACD_Main[1] - g_MACD_Sig[1]) > (g_MACD_Main[2] - g_MACD_Sig[2]));
      if(!main_above && !hist_rising) return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| GetSellSignal                                                      |
//| All active conditions must pass. Uses index [1] (last closed bar). |
//+------------------------------------------------------------------+
bool GetSellSignal()
{
   // TradeDirection gate
   if(TradeDirection == BUY_ONLY) return false;

   // ── Spread filter ───────────────────────────────────────────────
   if(GetCurrentSpread() > (double)Max_Spread_Points) return false;

   // ── Bollinger Band: rejection confirmation ───────────────────────
   // log values on every check for debugging
   PrintFormat("SELL CHECK: BB_Upper[2]=%.2f high[2]=%.2f close[1]=%.2f open[1]=%.2f",
               g_BB_Upper[2], g_High[2], g_Close[1], g_Open[1]);
   if(g_High[2]  < g_BB_Upper[2]) return false;  // bar[2] high must touch upper band
   if(g_Close[1] >= g_BB_Upper[1]) return false; // bar[1] must close back below upper band
   if(g_Close[1] >= g_Open[1])    return false;  // bar[1] must be bearish (rejection confirmed)

   // ── RSI: overbought relative to UpLevel ─────────────────────────
   if(g_RSI[1] <= RSI_UpLevel) return false;

   // ── SMA slope: flat or turning down ─────────────────────────────
   // Accepts up to 0.1% rise to tolerate sideways markets
   if(Use_SMA_Filter)
   {
      if(g_SMA[1] > g_SMA[2] * 1.001) return false;
   }

   // ── MACD: bearish momentum (main < signal OR histogram falling) ──
   if(Use_MACD)
   {
      bool main_below   = (g_MACD_Main[1] < g_MACD_Sig[1]);
      bool hist_falling = ((g_MACD_Main[1] - g_MACD_Sig[1]) < (g_MACD_Main[2] - g_MACD_Sig[2]));
      if(!main_below && !hist_falling) return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| IsVolatilityOK                                                     |
//| Replicates Vertex ATR Volatility Filter v2.2 inline.              |
//| Copies ATR_SMA_Period+1 raw ATR values, computes a manual SMA     |
//| over the last ATR_SMA_Period closed bars, then checks              |
//|   ATR[1] >= ATR_SMA * ATR_Multiplier                              |
//| Also gates on spread spikes and a dead-market ATR floor.          |
//| Populates g_ATR_Current / g_ATR_SMA / g_ATR_Threshold / g_VolGateOpen.
//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
   // ── Spread spike guard (fast path) ──────────────────────────────
   if(GetCurrentSpread() > (double)Max_Spread_Points)
   {
      g_VolGateOpen = false;
      return false;
   }

   // ── Copy ATR_SMA_Period + 1 bars of ATR data ─────────────────────
   // [0]=current forming, [1]=last closed, [2..ATR_SMA_Period]=history
   int  need = ATR_SMA_Period + 1;
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   if(CopyBuffer(atr_handle, 0, 0, need, atr_buf) < need)
   {
      g_VolGateOpen = false;
      return false;           // not enough history yet
   }

   // ── Dead-market floor: ATR[1] must exceed 5 × Point ─────────────
   double min_atr = 0.5 * _Point * 10.0;   // = 5 × Point
   if(atr_buf[1] < min_atr)
   {
      g_ATR_Current   = atr_buf[1];
      g_ATR_SMA       = 0.0;
      g_ATR_Threshold = 0.0;
      g_VolGateOpen   = false;
      return false;
   }

   // ── Manual ATR SMA over last ATR_SMA_Period closed bars ──────────
   // Average bars [1] through [ATR_SMA_Period] — skip [0] (forming bar)
   double atr_sum = 0.0;
   for(int i = 1; i <= ATR_SMA_Period; i++)
      atr_sum += atr_buf[i];
   double atr_sma = atr_sum / ATR_SMA_Period;

   double threshold = atr_sma * ATR_Multiplier;

   // ── Cache for dashboard ──────────────────────────────────────────
   g_ATR_Current   = atr_buf[1];
   g_ATR_SMA       = atr_sma;
   g_ATR_Threshold = threshold;

   // ── Gate: ATR[1] must be >= threshold (GREEN = adequate vol) ─────
   if(!Use_ATR_Filter)
   {
      g_VolGateOpen = true;
      return true;
   }

   g_VolGateOpen = (atr_buf[1] >= threshold);
   return g_VolGateOpen;
}

//+------------------------------------------------------------------+
//| IsWithinTradingSession                                             |
//| Returns true if the broker's current hour (adjusted for           |
//| GMT_Offset) falls inside the London OR New York session window.   |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   if(!Use_Session_Filter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // +48 before mod guards against negative results on any platform
   int hour = (dt.hour + GMT_Offset + 48) % 24;

   bool london  = (hour >= London_Start_Hour  && hour < London_End_Hour);
   bool newyork = (hour >= NewYork_Start_Hour && hour < NewYork_End_Hour);

   return (london || newyork);
}

//+------------------------------------------------------------------+
//| IsNewsBlackout                                                     |
//| Returns TRUE when trading is ALLOWED (no active blackout).        |
//| Returns FALSE when the current time is within News_Blackout_Minutes|
//| of any enabled news event.  Set News_Hour_X = -1 to disable.     |
//+------------------------------------------------------------------+
bool IsNewsBlackout()
{
   if(!Use_News_Blackout) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMins = dt.hour * 60 + dt.min;

   int newsHours[]   = { News_Hour_1,   News_Hour_2,   News_Hour_3   };
   int newsMins[]    = { News_Minute_1, News_Minute_2, News_Minute_3 };

   for(int i = 0; i < 3; i++)
   {
      if(newsHours[i] < 0) continue;                    // -1 means disabled
      int eventMins = newsHours[i] * 60 + newsMins[i];
      if(MathAbs(nowMins - eventMins) <= News_Blackout_Minutes)
         return false;                                   // inside blackout window
   }

   return true;   // clear — no active blackout
}

//+------------------------------------------------------------------+
//| UpdateDashboard                                                    |
//| Writes a live overlay to the chart via Comment().                  |
//| Called every tick so values stay current.                          |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   string nl  = "\n";
   string div = "══════════════════════════════" + nl;

   // ── Compute live values ──────────────────────────────────────────
   double dailyDD   = GetDailyDrawdownPercent();
   double totalDD   = GetTotalDrawdownPercent();
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   bool   inSession = IsWithinTradingSession();
   bool   newsClear = IsNewsBlackout();

   // ── Format status strings ────────────────────────────────────────
   string status  = TradingHalted ? "■ HALTED"        : "▶ ACTIVE";
   string sesStr  = inSession     ? "IN  session"     : "OUT session";
   string newsStr = newsClear     ? "NO  blackout"    : "YES blackout";
   string volStr  = g_VolGateOpen ? "GREEN  (pass)"   : "RED    (block)";
   string lastTrd = (LastTradeTime > 0)
                    ? TimeToString(LastTradeTime, TIME_DATE | TIME_MINUTES)
                    : "N/A";

   Comment(
      div +
      "  === VERTEX SCALP v1 ==="                                          + nl +
      "  " + _Symbol + "  " + EnumToString(Period())                      + nl +
      div +
      "  Status        :  " + status                                       + nl +
      "  Session       :  " + sesStr                                       + nl +
      "  News Blackout :  " + newsStr                                      + nl +
      "  ATR Gate      :  " + volStr                                       + nl +
      "  Spread        :  " + DoubleToString(GetCurrentSpread(), 1)
                            + " pts"                                       + nl +
      div +
      "  Day Start Bal :  " + DoubleToString(DayStartBalance, 2)          + nl +
      "  Equity        :  " + DoubleToString(equity, 2)                   + nl +
      "  Daily  DD     :  " + DoubleToString(dailyDD, 2) + "% / "
                            + DoubleToString(Max_Daily_DD_Percent, 2)
                            + "%"                                          + nl +
      "  Total  DD     :  " + DoubleToString(totalDD, 2) + "% / "
                            + DoubleToString(Max_Total_DD_Percent, 2)
                            + "%"                                          + nl +
      div +
      "  Last Signal   :  " + g_LastSignal                                 + nl +
      "  Last Trade    :  " + lastTrd                                      + nl +
      div
   );
}

//+------------------------------------------------------------------+
//| UpdateDayStartBalance                                              |
//| Detects calendar-day rollover via a static day-key and resets     |
//| DayStartBalance to the current balance.  Called every tick.       |
//+------------------------------------------------------------------+
void UpdateDayStartBalance()
{
   static int lastDayKey = -1;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int dayKey = dt.year * 10000 + dt.mon * 100 + dt.day;

   if(dayKey != lastDayKey)
   {
      DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDayKey      = dayKey;
      PrintFormat("New trading day %04d-%02d-%02d | DayStartBalance: %.2f",
                  dt.year, dt.mon, dt.day, DayStartBalance);
   }
}

//+------------------------------------------------------------------+
//| GetDailyDrawdownPercent                                            |
//| Returns equity drawdown from DayStartBalance as a positive %.     |
//+------------------------------------------------------------------+
double GetDailyDrawdownPercent()
{
   if(DayStartBalance <= 0.0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return ((DayStartBalance - equity) / DayStartBalance) * 100.0;
}

//+------------------------------------------------------------------+
//| GetTotalDrawdownPercent                                            |
//| Returns equity drawdown from InitialBalance as a positive %.      |
//+------------------------------------------------------------------+
double GetTotalDrawdownPercent()
{
   if(InitialBalance <= 0.0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return ((InitialBalance - equity) / InitialBalance) * 100.0;
}

//+------------------------------------------------------------------+
//| CloseAllPositions                                                  |
//| Emergency sweep — closes every position belonging to this EA.     |
//| Iterates in reverse to avoid index shifting on removal.           |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   Print("CloseAllPositions: emergency close triggered");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!positionInfo.SelectByIndex(i))             continue;
      if(positionInfo.Magic()  != (long)MagicNumber) continue;
      if(positionInfo.Symbol() != _Symbol)           continue;

      ulong ticket = positionInfo.Ticket();
      if(trade.PositionClose(ticket))
         PrintFormat("  Closed #%I64u | %s %.2f lots | P&L: %.2f",
                     ticket,
                     EnumToString(positionInfo.PositionType()),
                     positionInfo.Volume(),
                     positionInfo.Profit());
      else
         PrintFormat("  FAILED to close #%I64u: [%d] %s",
                     ticket, trade.ResultRetcode(), trade.ResultComment());
   }
}

//+------------------------------------------------------------------+
//| CheckDrawdownLimits                                                |
//| The prop-firm safety gate.  Checks daily and total DD each tick.  |
//| On breach: sets TradingHalted, closes all positions, fires Alert. |
//| Returns false on breach (caller should stop further logic).       |
//+------------------------------------------------------------------+
bool CheckDrawdownLimits()
{
   // Already halted — no need to re-check, just stay halted
   if(TradingHalted) return false;

   double dailyDD = GetDailyDrawdownPercent();
   double totalDD = GetTotalDrawdownPercent();

   if(dailyDD >= Max_Daily_DD_Percent)
   {
      TradingHalted = true;
      CloseAllPositions();
      Alert("DAILY DRAWDOWN LIMIT REACHED - EA HALTED");
      PrintFormat("!!! HALTED: Daily DD %.2f%% >= limit %.2f%% | Equity: %.2f | DayStart: %.2f",
                  dailyDD, Max_Daily_DD_Percent,
                  AccountInfoDouble(ACCOUNT_EQUITY), DayStartBalance);
      return false;
   }

   if(totalDD >= Max_Total_DD_Percent)
   {
      TradingHalted = true;
      CloseAllPositions();
      Alert("TOTAL DRAWDOWN LIMIT REACHED - EA HALTED");
      PrintFormat("!!! HALTED: Total DD %.2f%% >= limit %.2f%% | Equity: %.2f | InitBal: %.2f",
                  totalDD, Max_Total_DD_Percent,
                  AccountInfoDouble(ACCOUNT_EQUITY), InitialBalance);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| CalculateLotSize                                                   |
//| Sizes a position so the SL loss equals Risk_Percent of balance.   |
//| slPoints — stop-loss distance in MQL5 points (integer count).     |
//|                                                                    |
//| Formula: lots = riskAmount / (slPoints × _Point × tickVal/tickSz) |
//|   • slPoints × _Point  converts points → price distance           |
//|   • tickVal / tickSz   converts price distance → $ loss per lot   |
//| Lot is floored to broker volume step then clamped to [min, max].  |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
{
   if(slPoints <= 0.0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt   = balance * (Risk_Percent / 100.0);
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickVal <= 0.0 || tickSz <= 0.0) return minLot;

   // Risk per lot for this SL distance (in account currency)
   double riskPerLot = slPoints * _Point * (tickVal / tickSz);
   if(riskPerLot <= 0.0) return minLot;

   double lots = riskAmt / riskPerLot;

   // Normalise to broker step, then clamp
   if(lotStep > 0.0) lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, NormalizeDouble(lots, 2)));

   return lots;
}

//+------------------------------------------------------------------+
//| Position helpers — filter by MagicNumber + Symbol                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(positionInfo.SelectByIndex(i) &&
         positionInfo.Magic()  == MagicNumber &&
         positionInfo.Symbol() == _Symbol)
         return true;
   return false;
}

bool HasOpenBuy()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(positionInfo.SelectByIndex(i) &&
         positionInfo.Magic()       == MagicNumber &&
         positionInfo.Symbol()      == _Symbol     &&
         positionInfo.PositionType() == POSITION_TYPE_BUY)
         return true;
   return false;
}

bool HasOpenSell()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(positionInfo.SelectByIndex(i) &&
         positionInfo.Magic()       == MagicNumber &&
         positionInfo.Symbol()      == _Symbol     &&
         positionInfo.PositionType() == POSITION_TYPE_SELL)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| IsBarGapOK                                                         |
//| Returns true if at least MinBarsBetweenTrades M5 bars have        |
//| completed since the last trade entry.                              |
//+------------------------------------------------------------------+
bool IsBarGapOK()
{
   if(LastTradeTime == 0) return true;
   // iBarShift: how many M5 bars back does LastTradeTime fall?
   int shift = iBarShift(_Symbol, PERIOD_M5, LastTradeTime, false);
   return (shift >= MinBarsBetweenTrades);
}

//+------------------------------------------------------------------+
//| OpenBuy                                                            |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl   = ask  - SL_Points * _Point;
   double tp   = ask  + SL_Points * TP_RR * _Point;
   double lots = CalculateLotSize(SL_Points);

   if(!trade.Buy(lots, _Symbol, ask, sl, tp, EA_Comment))
   {
      PrintFormat("BUY FAILED [%d]: %s", trade.ResultRetcode(), trade.ResultComment());
      return false;
   }
   PrintFormat("BUY opened: lots=%.2f SL=%.5f TP=%.5f", lots, sl, tp);
   return true;
}

//+------------------------------------------------------------------+
//| OpenSell                                                           |
//+------------------------------------------------------------------+
bool OpenSell()
{
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl   = bid  + SL_Points * _Point;
   double tp   = bid  - SL_Points * TP_RR * _Point;
   double lots = CalculateLotSize(SL_Points);

   if(!trade.Sell(lots, _Symbol, bid, sl, tp, EA_Comment))
   {
      PrintFormat("SELL FAILED [%d]: %s", trade.ResultRetcode(), trade.ResultComment());
      return false;
   }
   PrintFormat("SELL opened: lots=%.2f SL=%.5f TP=%.5f", lots, sl, tp);
   return true;
}

//+------------------------------------------------------------------+
//| IsADXRanging                                                       |
//| Returns true when the market is ranging (ADX main < ADX_Threshold).|
//| Returns false when trending (ADX main >= ADX_Threshold) — entries |
//| should be blocked.  If the filter is disabled, always returns true.|
//+------------------------------------------------------------------+
bool IsADXRanging()
{
   if(!Use_ADX_Filter) return true;

   double adx_buf[];
   ArraySetAsSeries(adx_buf, true);
   if(CopyBuffer(adx_handle, 0, 0, 2, adx_buf) < 2) return true; // not enough history — allow

   return (adx_buf[1] < ADX_Threshold);
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ── STEP 1: Day rollover ─────────────────────────────────────────
   UpdateDayStartBalance();

   // ── STEP 2: Hard halt check (fastest exit — no recalculation) ───
   if(TradingHalted)
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 3: Live drawdown check — sets TradingHalted on breach ──
   if(!CheckDrawdownLimits())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 4: Session filter ───────────────────────────────────────
   if(!IsWithinTradingSession())
   {
      Print("Outside session");
      UpdateDashboard();
      return;
   }

   // ── STEP 5: News blackout ────────────────────────────────────────
   if(!IsNewsBlackout())
   {
      Print("News blackout active");
      UpdateDashboard();
      return;
   }

   // ── STEP 6: ATR volatility gate ──────────────────────────────────
   if(!IsVolatilityOK())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 6.5: ADX kill switch — block entries in trending markets ─
   if(!IsADXRanging())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 7: No pyramiding — skip if position already open ────────
   if(HasOpenPosition())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 8: Minimum bar gap between entries ───────────────────────
   if(!IsBarGapOK())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 9: Populate indicator buffers (deferred until needed) ───
   if(!RefreshIndicatorData())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 10: Signal evaluation and order placement ───────────────
   bool buy  = GetBuySignal();
   bool sell = GetSellSignal();

   PrintFormat("BUY=%d SELL=%d Spread=%.1f", buy, sell, GetCurrentSpread());

   if(buy && TradeDirection != SELL_ONLY)
   {
      g_LastSignal = "BUY";
      if(OpenBuy()) LastTradeTime = TimeCurrent();
   }
   else if(sell && TradeDirection != BUY_ONLY)
   {
      g_LastSignal = "SELL";
      if(OpenSell()) LastTradeTime = TimeCurrent();
   }
   else
   {
      g_LastSignal = "NONE";
   }

   // ── Dashboard: always runs on the execution path ─────────────────
   UpdateDashboard();
}
//+------------------------------------------------------------------+
