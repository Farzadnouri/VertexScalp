//+------------------------------------------------------------------+
//|                                            VertexScalp_v2.mq5    |
//|       Prop-Firm-Safe BB Mean-Reversion Scalper — EURUSD M5       |
//|                                                                    |
//|  CHANGES FROM v1                                                   |
//|    • ADX_Threshold lowered to 22 (was 30)                        |
//|    • RSI_UpLevel raised to 70, RSI_DownLevel lowered to 30       |
//|    • MACD filter removed                                          |
//|    • SMA trend filter removed                                     |
//|    • Session hours: London 08-12, NY 17-22 (avoids overlap)      |
//|    • [NEW] BB Width Expansion Gate — IsBBWidthOK()               |
//|    • [NEW] H1 RSI Confluence Filter — IsH1RSIOk()                |
//|    • [NEW] ATR-Adaptive Stop Loss — SL = ATR(14) × SL_ATR_Mult  |
//|    • OpenBuy/OpenSell updated for ATR SL                          |
//|    • Dashboard updated: BB width gate + H1 RSI state             |
//+------------------------------------------------------------------+
#property copyright   "VertexScalp EA"
#property link        ""
#property version     "2.00"
#property description "Prop-firm-safe BB mean-reversion scalper — EURUSD M5 — v2"
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
input int                   MagicNumber             = 123456;            // Magic Number
input string                EA_Comment              = "VertexScalp_v2";  // Order comment
input ENUM_TRADE_DIRECTION  TradeDirection          = BOTH;              // Trade direction
input int                   MinBarsBetweenTrades    = 4;                 // Min M5 bars between entries

// ── Bollinger Bands ─────────────────────────────────────────────────
input group              "=== Bollinger Bands ==="
input int                   BB_Period          = 20;               // BB period
input double                BB_Deviation       = 2.0;              // BB standard deviations
input ENUM_APPLIED_PRICE    BB_Price           = PRICE_CLOSE;      // BB applied price

// ── BB Width Expansion Gate (NEW) ───────────────────────────────────
input group              "=== BB Width Expansion Gate ==="
input bool                  Use_BB_Width_Filter     = true;             // Enable BB width expansion filter
input int                   BB_Width_Lookback       = 5;               // Bars to measure expansion over
input double                BB_Width_Max_Expand     = 20.0;            // Max allowed expansion % over lookback

// ── RSI Filter (M5) ─────────────────────────────────────────────────
input group              "=== RSI Filter (M5) ==="
input int                   RSI_Period         = 14;               // RSI period
input ENUM_APPLIED_PRICE    RSI_Price          = PRICE_CLOSE;      // RSI applied price
input double                RSI_UpLevel        = 70.0;             // RSI threshold for sells (overbought)
input double                RSI_DownLevel      = 30.0;             // RSI threshold for buys  (oversold)

// ── H1 RSI Confluence Filter (NEW) ──────────────────────────────────
input group              "=== H1 RSI Confluence Filter ==="
input bool                  Use_H1_RSI_Filter  = true;             // Enable H1 RSI confluence
input int                   H1_RSI_Period      = 14;               // H1 RSI period
input double                H1_RSI_OB          = 65.0;             // H1 RSI overbought level  (sell gate)
input double                H1_RSI_OS          = 35.0;             // H1 RSI oversold level    (buy gate)

// ── ATR Volatility Gate ─────────────────────────────────────────────
input group              "=== ATR Volatility Gate ==="
input bool                  Use_ATR_Filter     = true;             // Enable ATR volatility gate
input int                   ATR_Period         = 14;               // ATR period
input int                   ATR_SMA_Period     = 20;               // SMA period applied to ATR
input double                ATR_Multiplier     = 0.75;             // ATR must be >= multiplier × ATR-SMA

// ── Risk Management ─────────────────────────────────────────────────
input group              "=== Risk Management ==="
input double                Risk_Percent       = 0.5;              // Risk per trade (% of balance)
input double                SL_ATR_Mult        = 1.5;              // Stop loss = ATR(14) × this multiplier
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
input int                   London_End_Hour       = 12;            // London close (server hour) — avoid overlap
input int                   NewYork_Start_Hour    = 17;            // New York open  (post-overlap)
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
input bool                  Use_ADX_Filter   = true;    // Enable ADX trend filter
input int                   ADX_Period        = 14;      // ADX period
input double                ADX_Threshold    = 22.0;    // ADX < threshold = ranging (allowed)

//+------------------------------------------------------------------+
//| INDICATOR HANDLES                                                  |
//+------------------------------------------------------------------+
int bb_handle;        // Bollinger Bands (M5)
int rsi_handle;       // RSI (M5)
int atr_handle;       // ATR (M5) — volatility gate + adaptive SL
int adx_handle;       // ADX (M5) — kill switch
int h1_rsi_handle;    // RSI (H1) — confluence filter (NEW)

//+------------------------------------------------------------------+
//| TRADE OBJECTS                                                      |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  positionInfo;
CAccountInfo   accountInfo;

//+------------------------------------------------------------------+
//| STATE VARIABLES                                                    |
//+------------------------------------------------------------------+
double   InitialBalance;
double   DayStartBalance;
datetime LastTradeTime;
bool     TradingHalted;

//+------------------------------------------------------------------+
//| INDICATOR BUFFER ARRAYS                                            |
//| Series-ordered: [0]=current forming, [1]=last closed, [2]=prior   |
//+------------------------------------------------------------------+
double g_Open[], g_High[], g_Low[], g_Close[];
double g_BB_Middle[], g_BB_Upper[], g_BB_Lower[];
double g_RSI[];

//+------------------------------------------------------------------+
//| CACHE VARIABLES (populated each tick)                             |
//+------------------------------------------------------------------+
double g_ATR_Current   = 0.0;
double g_ATR_SMA       = 0.0;
double g_ATR_Threshold = 0.0;
double g_ATR_SL_Value  = 0.0;   // Actual SL distance in price (ATR × SL_ATR_Mult)
bool   g_VolGateOpen   = false;
bool   g_BBWidthOK     = false;  // NEW
double g_H1_RSI        = 0.0;   // NEW — cached for dashboard
string g_LastSignal    = "NONE";

//+------------------------------------------------------------------+
//| OnInit                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   // Bollinger Bands
   bb_handle = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, BB_Price);
   if(bb_handle == INVALID_HANDLE) { Print("ERROR: iBands handle failed"); return INIT_FAILED; }

   // RSI (M5)
   rsi_handle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, RSI_Price);
   if(rsi_handle == INVALID_HANDLE) { Print("ERROR: iRSI handle failed"); return INIT_FAILED; }

   // ATR (M5) — used for both volatility gate and adaptive SL
   atr_handle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atr_handle == INVALID_HANDLE) { Print("ERROR: iATR handle failed"); return INIT_FAILED; }

   // ADX (M5)
   adx_handle = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   if(adx_handle == INVALID_HANDLE) { Print("ERROR: iADX handle failed"); return INIT_FAILED; }

   // RSI (H1) — NEW confluence filter
   h1_rsi_handle = iRSI(_Symbol, PERIOD_H1, H1_RSI_Period, PRICE_CLOSE);
   if(h1_rsi_handle == INVALID_HANDLE) { Print("ERROR: H1 iRSI handle failed"); return INIT_FAILED; }

   InitialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   DayStartBalance = InitialBalance;
   LastTradeTime   = 0;
   TradingHalted   = false;

   Print("VertexScalp_v2 initialized | Symbol: ", _Symbol,
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
   IndicatorRelease(atr_handle);
   IndicatorRelease(adx_handle);
   IndicatorRelease(h1_rsi_handle);
   Comment("");
}

//+------------------------------------------------------------------+
//| RefreshIndicatorData                                               |
//| Populates price + BB + RSI arrays. Returns false if not ready.    |
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

   if(CopyOpen (_Symbol, PERIOD_CURRENT, 0, 3, g_Open)      < 3) return false;
   if(CopyHigh (_Symbol, PERIOD_CURRENT, 0, 3, g_High)      < 3) return false;
   if(CopyLow  (_Symbol, PERIOD_CURRENT, 0, 3, g_Low)       < 3) return false;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 3, g_Close)     < 3) return false;
   if(CopyBuffer(bb_handle,  0, 0, 3, g_BB_Middle)          < 3) return false;
   if(CopyBuffer(bb_handle,  1, 0, 3, g_BB_Upper)           < 3) return false;
   if(CopyBuffer(bb_handle,  2, 0, 3, g_BB_Lower)           < 3) return false;
   if(CopyBuffer(rsi_handle, 0, 0, 3, g_RSI)                < 3) return false;

   return true;
}

//+------------------------------------------------------------------+
//| GetCurrentSpread                                                   |
//+------------------------------------------------------------------+
double GetCurrentSpread()
{
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID))
          / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
//| IsVolatilityOK                                                     |
//| Replicates Vertex ATR gate inline.                                 |
//| Also computes g_ATR_Current for use in adaptive SL sizing.        |
//+------------------------------------------------------------------+
bool IsVolatilityOK()
{
   if(GetCurrentSpread() > (double)Max_Spread_Points)
   {
      g_VolGateOpen = false;
      return false;
   }

   int    need = ATR_SMA_Period + 1;
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   if(CopyBuffer(atr_handle, 0, 0, need, atr_buf) < need)
   {
      g_VolGateOpen = false;
      return false;
   }

   double min_atr = 0.5 * _Point * 10.0;
   if(atr_buf[1] < min_atr)
   {
      g_ATR_Current = atr_buf[1];
      g_ATR_SMA     = 0.0;
      g_ATR_Threshold = 0.0;
      g_VolGateOpen = false;
      return false;
   }

   double atr_sum = 0.0;
   for(int i = 1; i <= ATR_SMA_Period; i++)
      atr_sum += atr_buf[i];
   double atr_sma   = atr_sum / ATR_SMA_Period;
   double threshold = atr_sma * ATR_Multiplier;

   g_ATR_Current   = atr_buf[1];
   g_ATR_SMA       = atr_sma;
   g_ATR_Threshold = threshold;
   g_ATR_SL_Value  = atr_buf[1] * SL_ATR_Mult;   // cached for OpenBuy/OpenSell

   if(!Use_ATR_Filter)
   {
      g_VolGateOpen = true;
      return true;
   }

   g_VolGateOpen = (atr_buf[1] >= threshold);
   return g_VolGateOpen;
}

//+------------------------------------------------------------------+
//| IsBBWidthOK  — NEW                                                 |
//| Returns false if the BB width has expanded more than               |
//| BB_Width_Max_Expand % over the last BB_Width_Lookback bars.       |
//| Expansion = (width_now - width_oldest) / width_oldest * 100       |
//+------------------------------------------------------------------+
bool IsBBWidthOK()
{
   if(!Use_BB_Width_Filter) { g_BBWidthOK = true; return true; }

   int need = BB_Width_Lookback + 1;   // +1 for current forming bar offset

   double upper_buf[], lower_buf[];
   ArraySetAsSeries(upper_buf, true);
   ArraySetAsSeries(lower_buf, true);

   if(CopyBuffer(bb_handle, 1, 0, need, upper_buf) < need) { g_BBWidthOK = true; return true; }
   if(CopyBuffer(bb_handle, 2, 0, need, lower_buf) < need) { g_BBWidthOK = true; return true; }

   // Width of the most recent closed bar (index 1)
   double width_now    = upper_buf[1] - lower_buf[1];
   // Width BB_Width_Lookback bars ago (index BB_Width_Lookback)
   double width_oldest = upper_buf[BB_Width_Lookback] - lower_buf[BB_Width_Lookback];

   if(width_oldest <= 0.0) { g_BBWidthOK = true; return true; }

   double expand_pct = ((width_now - width_oldest) / width_oldest) * 100.0;

   g_BBWidthOK = (expand_pct < BB_Width_Max_Expand);
   return g_BBWidthOK;
}

//+------------------------------------------------------------------+
//| IsH1RSIOk  — NEW                                                   |
//| For sells: H1 RSI must be >= H1_RSI_OB (overbought).             |
//| For buys:  H1 RSI must be <= H1_RSI_OS (oversold).               |
//| direction: +1 = evaluating a buy, -1 = evaluating a sell.        |
//| When filter is disabled, always returns true.                     |
//+------------------------------------------------------------------+
bool IsH1RSIOk(int direction)
{
   if(!Use_H1_RSI_Filter) return true;

   double h1_rsi_buf[];
   ArraySetAsSeries(h1_rsi_buf, true);
   if(CopyBuffer(h1_rsi_handle, 0, 0, 2, h1_rsi_buf) < 2) return true;  // not enough history

   g_H1_RSI = h1_rsi_buf[1];   // last closed H1 bar

   if(direction == 1)  return (g_H1_RSI <= H1_RSI_OS);   // buy: H1 must be oversold
   if(direction == -1) return (g_H1_RSI >= H1_RSI_OB);   // sell: H1 must be overbought
   return true;
}

//+------------------------------------------------------------------+
//| IsADXRanging                                                       |
//| Returns true when ADX < threshold (ranging — entries allowed).    |
//+------------------------------------------------------------------+
bool IsADXRanging()
{
   if(!Use_ADX_Filter) return true;

   double adx_buf[];
   ArraySetAsSeries(adx_buf, true);
   if(CopyBuffer(adx_handle, 0, 0, 2, adx_buf) < 2) return true;

   return (adx_buf[1] < ADX_Threshold);
}

//+------------------------------------------------------------------+
//| GetBuySignal                                                       |
//+------------------------------------------------------------------+
bool GetBuySignal()
{
   if(TradeDirection == SELL_ONLY) return false;
   if(GetCurrentSpread() > (double)Max_Spread_Points) return false;

   // H1 RSI confluence — buy side
   if(!IsH1RSIOk(1)) return false;

   // BB snap-back: bar[2] low touched lower band, bar[1] closed back above it (bullish)
   PrintFormat("BUY CHECK: BB_Lower[2]=%.5f low[2]=%.5f close[1]=%.5f open[1]=%.5f",
               g_BB_Lower[2], g_Low[2], g_Close[1], g_Open[1]);
   if(g_Low[2]   > g_BB_Lower[2])  return false;  // bar[2] must breach lower band
   if(g_Close[1] <= g_BB_Lower[1]) return false;  // bar[1] must close back inside
   if(g_Close[1] <= g_Open[1])     return false;  // bar[1] must be bullish

   // M5 RSI: must be oversold
   if(g_RSI[1] >= RSI_DownLevel) return false;

   return true;
}

//+------------------------------------------------------------------+
//| GetSellSignal                                                      |
//+------------------------------------------------------------------+
bool GetSellSignal()
{
   if(TradeDirection == BUY_ONLY) return false;
   if(GetCurrentSpread() > (double)Max_Spread_Points) return false;

   // H1 RSI confluence — sell side
   if(!IsH1RSIOk(-1)) return false;

   // BB snap-back: bar[2] high touched upper band, bar[1] closed back below it (bearish)
   PrintFormat("SELL CHECK: BB_Upper[2]=%.5f high[2]=%.5f close[1]=%.5f open[1]=%.5f",
               g_BB_Upper[2], g_High[2], g_Close[1], g_Open[1]);
   if(g_High[2]  < g_BB_Upper[2])  return false;  // bar[2] must breach upper band
   if(g_Close[1] >= g_BB_Upper[1]) return false;  // bar[1] must close back inside
   if(g_Close[1] >= g_Open[1])     return false;  // bar[1] must be bearish

   // M5 RSI: must be overbought
   if(g_RSI[1] <= RSI_UpLevel) return false;

   return true;
}

//+------------------------------------------------------------------+
//| CalculateLotSize                                                   |
//| slDistance — stop-loss distance in price (not points).            |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0.0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt    = balance * (Risk_Percent / 100.0);
   double tickVal    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickVal <= 0.0 || tickSz <= 0.0) return minLot;

   double riskPerLot = slDistance * (tickVal / tickSz);
   if(riskPerLot <= 0.0) return minLot;

   double lots = riskAmt / riskPerLot;
   if(lotStep > 0.0) lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, NormalizeDouble(lots, 2)));

   return lots;
}

//+------------------------------------------------------------------+
//| OpenBuy  — ATR-adaptive SL/TP                                     |
//+------------------------------------------------------------------+
bool OpenBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Use ATR-adaptive SL; fall back to 80-point fixed if ATR unavailable
   double slDist = (g_ATR_SL_Value > 0.0) ? g_ATR_SL_Value : 80.0 * _Point;
   double sl  = ask - slDist;
   double tp  = ask + slDist * TP_RR;
   double lots = CalculateLotSize(slDist);

   if(!trade.Buy(lots, _Symbol, ask, sl, tp, EA_Comment))
   {
      PrintFormat("BUY FAILED [%d]: %s", trade.ResultRetcode(), trade.ResultComment());
      return false;
   }
   PrintFormat("BUY opened: lots=%.2f SL=%.5f TP=%.5f ATR_SL=%.5f", lots, sl, tp, slDist);
   return true;
}

//+------------------------------------------------------------------+
//| OpenSell  — ATR-adaptive SL/TP                                    |
//+------------------------------------------------------------------+
bool OpenSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDist = (g_ATR_SL_Value > 0.0) ? g_ATR_SL_Value : 80.0 * _Point;
   double sl  = bid + slDist;
   double tp  = bid - slDist * TP_RR;
   double lots = CalculateLotSize(slDist);

   if(!trade.Sell(lots, _Symbol, bid, sl, tp, EA_Comment))
   {
      PrintFormat("SELL FAILED [%d]: %s", trade.ResultRetcode(), trade.ResultComment());
      return false;
   }
   PrintFormat("SELL opened: lots=%.2f SL=%.5f TP=%.5f ATR_SL=%.5f", lots, sl, tp, slDist);
   return true;
}

//+------------------------------------------------------------------+
//| Position helpers                                                   |
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
         positionInfo.Magic()        == MagicNumber &&
         positionInfo.Symbol()       == _Symbol     &&
         positionInfo.PositionType() == POSITION_TYPE_BUY)
         return true;
   return false;
}

bool HasOpenSell()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(positionInfo.SelectByIndex(i) &&
         positionInfo.Magic()        == MagicNumber &&
         positionInfo.Symbol()       == _Symbol     &&
         positionInfo.PositionType() == POSITION_TYPE_SELL)
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| IsBarGapOK                                                         |
//+------------------------------------------------------------------+
bool IsBarGapOK()
{
   if(LastTradeTime == 0) return true;
   int shift = iBarShift(_Symbol, PERIOD_M5, LastTradeTime, false);
   return (shift >= MinBarsBetweenTrades);
}

//+------------------------------------------------------------------+
//| IsWithinTradingSession                                             |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   if(!Use_Session_Filter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = (dt.hour + GMT_Offset + 48) % 24;

   bool london  = (hour >= London_Start_Hour  && hour < London_End_Hour);
   bool newyork = (hour >= NewYork_Start_Hour && hour < NewYork_End_Hour);

   return (london || newyork);
}

//+------------------------------------------------------------------+
//| IsNewsBlackout                                                     |
//| Returns TRUE when trading is allowed (no active blackout).        |
//+------------------------------------------------------------------+
bool IsNewsBlackout()
{
   if(!Use_News_Blackout) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMins = dt.hour * 60 + dt.min;

   int newsHours[] = { News_Hour_1,   News_Hour_2,   News_Hour_3   };
   int newsMins[]  = { News_Minute_1, News_Minute_2, News_Minute_3 };

   for(int i = 0; i < 3; i++)
   {
      if(newsHours[i] < 0) continue;
      int eventMins = newsHours[i] * 60 + newsMins[i];
      if(MathAbs(nowMins - eventMins) <= News_Blackout_Minutes)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| UpdateDayStartBalance                                              |
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
//+------------------------------------------------------------------+
double GetDailyDrawdownPercent()
{
   if(DayStartBalance <= 0.0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return ((DayStartBalance - equity) / DayStartBalance) * 100.0;
}

//+------------------------------------------------------------------+
//| GetTotalDrawdownPercent                                            |
//+------------------------------------------------------------------+
double GetTotalDrawdownPercent()
{
   if(InitialBalance <= 0.0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return ((InitialBalance - equity) / InitialBalance) * 100.0;
}

//+------------------------------------------------------------------+
//| CloseAllPositions                                                  |
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
                     ticket, EnumToString(positionInfo.PositionType()),
                     positionInfo.Volume(), positionInfo.Profit());
      else
         PrintFormat("  FAILED to close #%I64u: [%d] %s",
                     ticket, trade.ResultRetcode(), trade.ResultComment());
   }
}

//+------------------------------------------------------------------+
//| CheckDrawdownLimits                                                |
//+------------------------------------------------------------------+
bool CheckDrawdownLimits()
{
   if(TradingHalted) return false;

   double dailyDD = GetDailyDrawdownPercent();
   double totalDD = GetTotalDrawdownPercent();

   if(dailyDD >= Max_Daily_DD_Percent)
   {
      TradingHalted = true;
      CloseAllPositions();
      Alert("DAILY DRAWDOWN LIMIT REACHED - EA HALTED");
      PrintFormat("!!! HALTED: Daily DD %.2f%% >= limit %.2f%%", dailyDD, Max_Daily_DD_Percent);
      return false;
   }

   if(totalDD >= Max_Total_DD_Percent)
   {
      TradingHalted = true;
      CloseAllPositions();
      Alert("TOTAL DRAWDOWN LIMIT REACHED - EA HALTED");
      PrintFormat("!!! HALTED: Total DD %.2f%% >= limit %.2f%%", totalDD, Max_Total_DD_Percent);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| UpdateDashboard                                                    |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   string nl  = "\n";
   string div = "══════════════════════════════" + nl;

   double dailyDD   = GetDailyDrawdownPercent();
   double totalDD   = GetTotalDrawdownPercent();
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   bool   inSession = IsWithinTradingSession();
   bool   newsClear = IsNewsBlackout();

   string status    = TradingHalted ? "■ HALTED"      : "▶ ACTIVE";
   string sesStr    = inSession     ? "IN  session"   : "OUT session";
   string newsStr   = newsClear     ? "NO  blackout"  : "YES blackout";
   string volStr    = g_VolGateOpen ? "GREEN  (pass)" : "RED    (block)";
   string bbwStr    = g_BBWidthOK   ? "OK  (stable)"  : "BLOCK  (expanding)";
   string adxStr    = IsADXRanging()? "RANGING (pass)": "TREND   (block)";
   string h1rsiStr  = StringFormat("%.1f  (OB:%.0f OS:%.0f)", g_H1_RSI, H1_RSI_OB, H1_RSI_OS);
   string lastTrd   = (LastTradeTime > 0)
                      ? TimeToString(LastTradeTime, TIME_DATE | TIME_MINUTES)
                      : "N/A";
   string slStr     = StringFormat("%.5f  (ATR×%.1f)", g_ATR_SL_Value, SL_ATR_Mult);

   Comment(
      div +
      "  === VERTEX SCALP v2 ==="                                             + nl +
      "  " + _Symbol + "  " + EnumToString(Period())                         + nl +
      div +
      "  Status        :  " + status                                          + nl +
      "  Session       :  " + sesStr                                          + nl +
      "  News Blackout :  " + newsStr                                         + nl +
      div +
      "  ATR Gate      :  " + volStr                                          + nl +
      "  BB Width      :  " + bbwStr                                          + nl +
      "  ADX           :  " + adxStr                                          + nl +
      "  H1 RSI        :  " + h1rsiStr                                        + nl +
      div +
      "  ATR SL dist   :  " + slStr                                           + nl +
      "  Spread        :  " + DoubleToString(GetCurrentSpread(), 1) + " pts"  + nl +
      div +
      "  Day Start Bal :  " + DoubleToString(DayStartBalance, 2)             + nl +
      "  Equity        :  " + DoubleToString(equity, 2)                      + nl +
      "  Daily  DD     :  " + DoubleToString(dailyDD, 2) + "% / "
                            + DoubleToString(Max_Daily_DD_Percent, 2) + "%"  + nl +
      "  Total  DD     :  " + DoubleToString(totalDD, 2) + "% / "
                            + DoubleToString(Max_Total_DD_Percent, 2) + "%"  + nl +
      div +
      "  Last Signal   :  " + g_LastSignal                                    + nl +
      "  Last Trade    :  " + lastTrd                                         + nl +
      div
   );
}

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // ── STEP 1: Day rollover ─────────────────────────────────────────
   UpdateDayStartBalance();

   // ── STEP 2: Hard halt check ──────────────────────────────────────
   if(TradingHalted)
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 3: Drawdown check ───────────────────────────────────────
   if(!CheckDrawdownLimits())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 4: Session filter ───────────────────────────────────────
   if(!IsWithinTradingSession())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 5: News blackout ────────────────────────────────────────
   if(!IsNewsBlackout())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 6: ATR volatility gate (also caches ATR SL value) ───────
   if(!IsVolatilityOK())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 7: BB width expansion gate (NEW) ────────────────────────
   if(!IsBBWidthOK())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 8: ADX kill switch ──────────────────────────────────────
   if(!IsADXRanging())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 9: No pyramiding ────────────────────────────────────────
   if(HasOpenPosition())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 10: Minimum bar gap ─────────────────────────────────────
   if(!IsBarGapOK())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 11: Populate indicator buffers ──────────────────────────
   if(!RefreshIndicatorData())
   {
      UpdateDashboard();
      return;
   }

   // ── STEP 12: Signal evaluation (H1 RSI checked inside signals) ───
   bool buy  = GetBuySignal();
   bool sell = GetSellSignal();

   // Cache H1 RSI for dashboard regardless of signal result
   double h1buf[];
   ArraySetAsSeries(h1buf, true);
   if(CopyBuffer(h1_rsi_handle, 0, 0, 2, h1buf) >= 2) g_H1_RSI = h1buf[1];

   PrintFormat("BUY=%d SELL=%d Spread=%.1f H1_RSI=%.1f ATR_SL=%.5f",
               buy, sell, GetCurrentSpread(), g_H1_RSI, g_ATR_SL_Value);

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

   UpdateDashboard();
}
//+------------------------------------------------------------------+
