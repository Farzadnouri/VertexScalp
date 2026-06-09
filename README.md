# VertexScalp — BB Mean-Reversion EA

**Vertex Algo | EURUSD M15 | MetaTrader 5**

A prop-firm-safe Bollinger Band mean-reversion Expert Advisor built and tested systematically over multiple backtesting iterations. This repository documents the full development lifecycle — including the decision to archive the strategy rather than deploy it live.

---

## Strategy Overview

VertexScalp is a mean-reversion scalper built around a Bollinger Band snap-back entry. The core logic: when price breaks outside a BB band and then closes back inside on the following bar, a counter-trend trade is opened targeting a return to the BB midline (SMA20).

**Instrument:** EURUSD  
**Timeframes tested:** M5, M15  
**Account type:** Prop firm demo ($100,000)  
**Broker tested on:** WMMarkets-Demo (MT5 Build 5836)

---

## Architecture

### Entry Logic (both versions)
- Bar[2] high/low must breach the upper/lower Bollinger Band
- Bar[1] must close back inside the band (snap-back confirmation)
- Bar[1] must be a rejection candle (bearish for sells, bullish for buys)
- M5 RSI must confirm overbought/oversold condition

### Risk Management
- ATR-adaptive stop loss: `SL = ATR(14) × multiplier` (v2)
- Risk-based lot sizing: fixed % of balance per trade
- Prop-firm drawdown protection: daily and total DD limits with auto-halt

### Filters (v2)
| Filter | Function |
|---|---|
| ADX Kill Switch | Blocks entries when ADX > threshold (trending market) |
| BB Width Expansion Gate | Blocks entries when bands are rapidly expanding |
| H1 RSI Confluence | Requires HTF overbought/oversold alignment |
| ATR Volatility Gate | Blocks entries in dead or spiking markets |
| Session Filter | Restricts trading to defined London/NY windows |
| News Blackout | Configurable blackout windows around news events |

---

## Versions

### v1 — Foundation
- Core BB snap-back signal engine
- Fixed pip stop loss
- ADX kill switch at threshold 30
- ATR volatility gate (Vertex ATR Filter v2.2)
- Session filter (London + NY)
- News blackout (3 configurable events)
- Prop-firm drawdown protection (daily + total)
- Chart dashboard via Comment()

### v2 — Extended Filters
- ADX threshold tightened to 22
- RSI thresholds tightened: UpLevel 70, DownLevel 30
- MACD and SMA trend filters removed
- **[NEW]** BB Width Expansion Gate (`IsBBWidthOK()`)
- **[NEW]** H1 RSI Confluence Filter (`IsH1RSIOk()`)
- **[NEW]** ATR-Adaptive Stop Loss replacing fixed pip SL
- Dashboard updated with new filter states


## Key Findings

### 1. The signal has no consistent edge in trending markets
In trending months (March, May 2025), the win rate collapsed to 29–39% and profit factor never exceeded 0.71 regardless of filter combination, timeframe, or RR ratio. Adding filters did not select better trades — it randomly reduced sample size while the loss rate remained constant.

### 2. Filter stacking causes sample bias, not quality improvement
When multiple filters were stacked (ADX + H1 RSI + BB Width + Session), the EA produced zero trades in some months. The filters were not discriminating between winning and losing setups — they were eliminating both equally.

### 3. Ranging months produce structurally different results
February 2025 (ranging month) with ADX=35 produced 22 trades, 45.5% win rate, 2.5% max drawdown, and a near-breakeven profit factor of 0.81. The LR Correlation dropped from -0.90 (strong downtrend in equity) to -0.12 (flat/oscillating). The strategy is structurally competitive in the correct market regime.

### 4. The BB snap-back entry requires regime pre-screening
The strategy cannot self-identify ranging vs trending conditions reliably on a bar-by-bar basis using standard indicators. Manual monthly regime confirmation (checking weekly ADX and price structure before enabling the EA) is required for it to be viable.

---

## Conclusion

VertexScalp is **archived, not deployed.**

The core signal and EA architecture are sound. The prop-firm safety layer (drawdown protection, ATR sizing, session/news filtering) works correctly. The strategy is not profitable as a set-and-forget automated system because it cannot reliably identify its own optimal market conditions.

**This is a valid learning outcome, not a failure.** The development process:
- Identified the exact failure mode (trending market exposure)
- Confirmed the strategy has structural edge in the correct regime
- Produced a reusable EA architecture for future bots

The next EA in the Vertex Algo portfolio will be a trend-following system for XAUUSD built on the v2 architecture, targeting the market conditions that caused VertexScalp to fail.

---

## Tech Stack

- **Language:** MQL5
- **Platform:** MetaTrader 5
- **Libraries:** `Trade.mqh`, `PositionInfo.mqh`, `AccountInfo.mqh`
- **Indicators used:** iBands, iRSI (M15 + H1), iATR, iADX

---

## Repository Structure

```
VertexScalp/
├── README.md
├── VertexScalp_v1.mq5
├── VertexScalp_v2.mq5
└── backtests/
    └── (HTML report files)
```

---

*Part of the Vertex Algo project — building a portfolio of automated prop-firm EAs.*
