//+------------------------------------------------------------------+
//| NEURON QUANT - Expert Advisor Demo for MetaTrader 5              |
//| Portfolio demonstration - educational purposes only              |
//| Copyright (c) 2026 Lucas Farias                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Lucas Farias"
#property version   "1.10"
#property strict
#property description "Moving average crossover EA with risk management."
#property description "Educational portfolio example; no profitability guarantee."

#include <Trade/Trade.mqh>

input group "Signal Settings"
input int               InpFastMAPeriod       = 10;
input int               InpSlowMAPeriod       = 30;
input ENUM_MA_METHOD    InpMAMethod           = MODE_EMA;
input ENUM_APPLIED_PRICE InpAppliedPrice      = PRICE_CLOSE;

input group "Optional Signal Filters"
input bool              InpUseRSIFilter        = false;
input int               InpRSIPeriod          = 14;
input double            InpRSIBuyMinimum      = 50.0;
input double            InpRSISellMaximum     = 50.0;
input bool              InpUseADXFilter        = false;
input int               InpADXPeriod          = 14;
input double            InpADXMinimum         = 20.0;

input group "Optional Weekly Filter (server time)"
input bool              InpUseWeeklyFilter    = false;
input bool              InpTradeMonday        = true;
input bool              InpTradeTuesday       = true;
input bool              InpTradeWednesday     = true;
input bool              InpTradeThursday      = true;
input bool              InpTradeFriday        = true;
input bool              InpTradeSaturday      = false;
input bool              InpTradeSunday        = false;

input group "Optional Trading Hours (server time, 0-23)"
input bool              InpUseHoursFilter     = false;
input int               InpStartHour          = 9;
input int               InpEndHour            = 18;

input group "Optional Economic News Filter (MT5 calendar)"
input bool              InpUseNewsFilter      = false;
input bool              InpNewsHigh           = true;
input bool              InpNewsModerate       = false;
input bool              InpNewsLow            = false;
input int               InpMinutesBeforeNews  = 30;
input int               InpMinutesAfterNews   = 15;
input bool              InpBlockIfNoCalendar  = true;

input group "Optional Equity Drawdown Protection"
input bool              InpUseDDFilter        = false;
input double            InpMaxDailyDDPercent  = 2.0;
input bool              InpCloseOnDDLimit     = false;

input group "Trade Settings"
input ulong             InpMagicNumber        = 20261019;
input bool              InpUseRiskPercent     = false;
input double            InpRiskPercent        = 2.0;
input double            InpFixedLot           = 0.01;
input int               InpStopLossPoints     = 500;
input int               InpTakeProfitPoints   = 1000;
input int               InpMaxSpreadPoints    = 50;
input int               InpDeviationPoints    = 20;

input group "Position Management"
input bool              InpUseBreakEven       = true;
input int               InpBreakEvenTrigger   = 400;
input int               InpBreakEvenOffset    = 20;
input bool              InpUseTrailingStop    = true;
input int               InpTrailingStart      = 600;
input int               InpTrailingDistance   = 350;
input int               InpTrailingStep       = 50;

CTrade trade;
int fastHandle = INVALID_HANDLE;
int slowHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;
int adxHandle = INVALID_HANDLE;
double dailyEquityPeak = 0.0;
int dailyKey = -1;
bool dailyBlocked = false;
datetime lastBarTime = 0;

// Volume must satisfy the broker's min/max/step restrictions.
double NormalizeVolume(const double requested)
{
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minVol <= 0.0 || maxVol < minVol || step <= 0.0) return 0.0;
   if(requested < minVol) return 0.0; // Never increase risk by forcing min lot.
   double capped = MathMin(requested, maxVol);
   double steps = MathFloor((capped - minVol) / step + 1e-8);
   double volume = minVol + steps * step;
   return NormalizeDouble(MathMax(minVol, MathMin(maxVol, volume)), 8);
}

// Risk is estimated using the symbol's tick size and tick value.
double CalculateVolume(const int stopPoints)
{
   if(!InpUseRiskPercent) return NormalizeVolume(InpFixedLot);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(balance <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0 || stopPoints <= 0)
      return 0.0;
   double riskMoney = balance * InpRiskPercent / 100.0;
   double lossPerLot = (stopPoints * _Point / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;
   return NormalizeVolume(riskMoney / lossPerLot);
}

// Avoid modifying other EAs' positions and avoid hedging duplicates.
bool HasAnySymbolPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
   }
   return false;
}

int MinimumStopPoints()
{
   int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return (int)MathMax(stops + 2, 1);
}

// All time filters use trade-server time. End hour is exclusive.
bool TimeFiltersAllow()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpUseWeeklyFilter)
   {
      bool days[7];
      days[0]=InpTradeSunday; days[1]=InpTradeMonday;
      days[2]=InpTradeTuesday; days[3]=InpTradeWednesday;
      days[4]=InpTradeThursday; days[5]=InpTradeFriday;
      days[6]=InpTradeSaturday;
      if(!days[dt.day_of_week]) return false;
   }
   if(InpUseHoursFilter)
   {
      if(InpStartHour == InpEndHour) return true; // 24-hour window
      if(InpStartHour < InpEndHour)
      {
         if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
      }
      else if(dt.hour < InpStartHour && dt.hour >= InpEndHour) return false;
   }
   return true;
}

// MT5 economic calendar uses trade-server time. If data is unavailable,
// optionally fail closed instead of silently disabling news protection.
bool NewsAllows()
{
   if(!InpUseNewsFilter) return true;
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   MqlCalendarValue values[];
   ResetLastError();
   int count = CalendarValueHistory(values, now - InpMinutesAfterNews*60,
                                    now + InpMinutesBeforeNews*60);
   if(count < 0)
   {
      PrintFormat("Economic calendar unavailable (error %d)", GetLastError());
      return !InpBlockIfNoCalendar;
   }
   string base = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   for(int i=0; i<count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event))
         return !InpBlockIfNoCalendar;
      bool selected = (event.importance == CALENDAR_IMPORTANCE_HIGH && InpNewsHigh) ||
                      (event.importance == CALENDAR_IMPORTANCE_MODERATE && InpNewsModerate) ||
                      (event.importance == CALENDAR_IMPORTANCE_LOW && InpNewsLow);
      if(!selected) continue;
      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country))
         return !InpBlockIfNoCalendar;
      if(country.currency != base && country.currency != quote) continue;
      if(values[i].time >= now - InpMinutesAfterNews*60 &&
         values[i].time <= now + InpMinutesBeforeNews*60) return false;
   }
   return true;
}

void CloseOwnPositions()
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      if(!trade.PositionClose(ticket))
         PrintFormat("DD close failed: %u %s", trade.ResultRetcode(),trade.ResultRetcodeDescription());
   }
}

bool DDAllows()
{
   if(!InpUseDDFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int key=dt.year*1000+dt.day_of_year;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(key!=dailyKey)
   {
      dailyKey=key;
      dailyEquityPeak=equity;
      dailyBlocked=false;
   }
   if(equity>dailyEquityPeak) dailyEquityPeak=equity;
   if(dailyEquityPeak>0 &&
      100.0*(dailyEquityPeak-equity)/dailyEquityPeak>=InpMaxDailyDDPercent)
      dailyBlocked=true;
   if(dailyBlocked && InpCloseOnDDLimit) CloseOwnPositions();
   return !dailyBlocked;
}

bool SignalFiltersAllow(const bool buy)
{
   double buffer[1];
   if(InpUseRSIFilter)
   {
      if(CopyBuffer(rsiHandle,0,1,1,buffer)!=1) return false;
      if(buy && buffer[0]<InpRSIBuyMinimum) return false;
      if(!buy && buffer[0]>InpRSISellMaximum) return false;
   }
   if(InpUseADXFilter)
   {
      if(CopyBuffer(adxHandle,0,1,1,buffer)!=1 || buffer[0]<InpADXMinimum)
         return false;
   }
   return true;
}

void ManagePositions()
{
   if(!InpUseBreakEven && !InpUseTrailingStop) return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0 || tick.ask <= 0) return;
   int minimum = (int)MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                               SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) + 2;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      bool buy = (type == POSITION_TYPE_BUY);
      double marketPrice = buy ? tick.bid : tick.ask;
      double profitPoints = (buy ? marketPrice - openPrice : openPrice - marketPrice) / _Point;
      double desiredSL = oldSL;
      bool change = false;
      if(InpUseBreakEven && profitPoints >= InpBreakEvenTrigger)
      {
         double candidate = openPrice + (buy ? 1 : -1) * InpBreakEvenOffset * _Point;
         if((buy && (oldSL == 0 || candidate > desiredSL + _Point * 0.5)) ||
            (!buy && (oldSL == 0 || candidate < desiredSL - _Point * 0.5)))
         { desiredSL = candidate; change = true; }
      }
      if(InpUseTrailingStop && profitPoints >= InpTrailingStart)
      {
         double candidate = marketPrice + (buy ? -1 : 1) * InpTrailingDistance * _Point;
         if((buy && (desiredSL == 0 || candidate > desiredSL + InpTrailingStep * _Point)) ||
            (!buy && (desiredSL == 0 || candidate < desiredSL - InpTrailingStep * _Point)))
         { desiredSL = candidate; change = true; }
      }
      if(!change) continue;
      desiredSL = NormalizeDouble(desiredSL, _Digits);
      if(buy && marketPrice - desiredSL < minimum * _Point) continue;
      if(!buy && desiredSL - marketPrice < minimum * _Point) continue;
      if(!trade.PositionModify(ticket, desiredSL, tp))
         PrintFormat("PositionModify failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

int OnInit()
{
   if(InpFastMAPeriod < 1 || InpSlowMAPeriod <= InpFastMAPeriod ||
      InpFixedLot <= 0 || InpRiskPercent <= 0 || InpRiskPercent > 100 ||
      InpStopLossPoints <= 0 || InpTakeProfitPoints <= 0 ||
      InpMaxSpreadPoints < 0 || InpDeviationPoints < 0 ||
      InpBreakEvenTrigger < 1 || InpBreakEvenOffset < 0 ||
      InpTrailingStart < 1 || InpTrailingDistance < 1 || InpTrailingStep < 1 ||
      InpRSIPeriod < 2 || InpADXPeriod < 2 ||
      InpRSIBuyMinimum < 0 || InpRSIBuyMinimum > 100 ||
      InpRSISellMaximum < 0 || InpRSISellMaximum > 100 ||
      InpADXMinimum < 0 || InpStartHour < 0 || InpStartHour > 23 ||
      InpEndHour < 0 || InpEndHour > 23 ||
      InpMinutesBeforeNews < 0 || InpMinutesAfterNews < 0 ||
      InpMaxDailyDDPercent <= 0 || InpMaxDailyDDPercent > 100)
   { Print("Invalid input parameters."); return INIT_PARAMETERS_INCORRECT; }

   fastHandle = iMA(_Symbol, PERIOD_CURRENT, InpFastMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   slowHandle = iMA(_Symbol, PERIOD_CURRENT, InpSlowMAPeriod, 0, InpMAMethod, InpAppliedPrice);
   if(InpUseRSIFilter)
      rsiHandle=iRSI(_Symbol,PERIOD_CURRENT,InpRSIPeriod,InpAppliedPrice);
   if(InpUseADXFilter)
      adxHandle=iADX(_Symbol,PERIOD_CURRENT,InpADXPeriod);
   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE ||
      (InpUseRSIFilter && rsiHandle == INVALID_HANDLE) ||
      (InpUseADXFilter && adxHandle == INVALID_HANDLE))
   { Print("Failed to create MA handles."); return INIT_FAILED; }
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE) IndicatorRelease(fastHandle);
   if(slowHandle != INVALID_HANDLE) IndicatorRelease(slowHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
}

void OnTick()
{
   bool ddOK=DDAllows();
   ManagePositions();
   if(!ddOK) return;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == 0 || currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   if(BarsCalculated(fastHandle) < InpSlowMAPeriod + 3 ||
      BarsCalculated(slowHandle) < InpSlowMAPeriod + 3) return;
   if(HasAnySymbolPosition()) return;
   if(!TimeFiltersAllow() || !NewsAllows()) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0) return;
   if((tick.ask - tick.bid) / _Point > InpMaxSpreadPoints) return;

   double fast[2], slow[2];
   // CopyBuffer positions: [0] = older closed candle (shift 2), [1] = last closed (shift 1).
   if(CopyBuffer(fastHandle, 0, 1, 2, fast) != 2 ||
      CopyBuffer(slowHandle, 0, 1, 2, slow) != 2) return;
   bool buySignal  = fast[0] <= slow[0] && fast[1] > slow[1];
   bool sellSignal = fast[0] >= slow[0] && fast[1] < slow[1];
   if(!buySignal && !sellSignal) return;
   if(!SignalFiltersAllow(buySignal)) return;

   int stopPoints = (int)MathMax(InpStopLossPoints, MinimumStopPoints());
   int takePoints = (int)MathMax(InpTakeProfitPoints, MinimumStopPoints());
   double volume = CalculateVolume(stopPoints);
   if(volume <= 0) { Print("Trade skipped: volume below broker minimum or unavailable."); return; }

   double price = buySignal ? tick.ask : tick.bid;
   double sl = NormalizeDouble(price + (buySignal ? -1 : 1) * stopPoints * _Point, _Digits);
   double tp = NormalizeDouble(price + (buySignal ? 1 : -1) * takePoints * _Point, _Digits);
   bool sent = buySignal ? trade.Buy(volume, _Symbol, 0.0, sl, tp, "NEURON DEMO BUY")
                         : trade.Sell(volume, _Symbol, 0.0, sl, tp, "NEURON DEMO SELL");
   if(!sent || (trade.ResultRetcode() != TRADE_RETCODE_DONE &&
                trade.ResultRetcode() != TRADE_RETCODE_DONE_PARTIAL))
      PrintFormat("Trade not executed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
