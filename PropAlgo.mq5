//+------------------------------------------------------------------+
//|                                                     PropAlgo.mq5  |
//|                 Mean-reversion fade (z-score) with regime filter |
//|                                                                  |
//|  Built on the proven MetaQuotes single-symbol EA skeleton so it  |
//|  trades reliably in the Strategy Tester:                         |
//|    - single symbol (the chart), fixed lot, fixed SL/TP in points |
//|    - clean new-bar detection, close-by-time                      |
//|    - NO silent reject gates (no broker-P/L sizing, no cost gate) |
//|                                                                  |
//|  Signal (the strategy): on each closed H1 bar compute            |
//|    z = (close - mean) / std   over InpMeanPeriod bars.           |
//|  Trade only when the market is ranging (Kaufman Efficiency Ratio |
//|  <= InpERGate). Fade the extreme:                                |
//|    z >= +InpZEntry  -> SELL (fade the up-spike)                  |
//|    z <= -InpZEntry  -> BUY  (fade the down-spike)                |
//|  Exit on fixed SL/TP (points) or after InpDuration bars.         |
//|                                                                  |
//|  NOT validated. Forward-test on demo before risking capital.     |
//+------------------------------------------------------------------+
#property copyright "PropAlgo"
#property version   "3.00"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

#define SIGNAL_BUY    1             // Buy signal
#define SIGNAL_NOT    0             // no trading signal
#define SIGNAL_SELL  -1             // Sell signal

//--- signal parameters
input int    InpMeanPeriod = 20;    // rolling mean/std window (bars)
input double InpZEntry     = 1.5;   // |z| threshold to fade
input int    InpERPeriod   = 50;    // Kaufman Efficiency Ratio period
input double InpERGate     = 0.45;  // trade only when ER <= this (1.0 = filter off)

//--- trade parameters
input uint   InpDuration = 24;      // position holding time in bars (0 = off)
input uint   InpSL       = 1000;    // Stop Loss in points (0 = none)
input uint   InpTP       = 1500;    // Take Profit in points (0 = none)
input uint   InpSlippage = 20;      // slippage in points

//--- money management
input double InpLot = 0.10;         // fixed lot

//--- Expert ID
input long   InpMagicNumber = 990515; // Magic Number

//--- global variables
int    ExtSignalOpen   = 0;         // Buy/Sell signal
string ExtDirection    = "";        // position opening direction
bool   ExtCloseByTime  = true;      // requires closing by time
bool   ExtCheckPassed  = true;      // status checking error

//--- service objects
CTrade      ExtTrade;
CSymbolInfo ExtSymbolInfo;
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   ExtTrade.SetDeviationInPoints(InpSlippage);
   ExtTrade.SetExpertMagicNumber(InpMagicNumber);
   ExtTrade.LogLevel(LOG_LEVEL_ERRORS);

   if(!ExtSymbolInfo.Name(_Symbol))
     {
      Print("Failed to set symbol ", _Symbol);
      return(INIT_FAILED);
     }

   PrintFormat("PropAlgo init on %s %s | meanPeriod=%d zEntry=%.2f ERperiod=%d ERgate=%.2f | SL=%d TP=%d holdBars=%d lot=%.2f",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
               InpMeanPeriod, InpZEntry, InpERPeriod, InpERGate,
               InpSL, InpTP, InpDuration, InpLot);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- all checks at bar opening only
   static datetime next_bar_open = 0;

//--- Phase 1 - on a new bar, recompute the signal
   if(TimeCurrent() >= next_bar_open)
     {
      if(CheckState())
        {
         next_bar_open  = TimeCurrent();
         next_bar_open -= next_bar_open % PeriodSeconds(_Period);
         next_bar_open += PeriodSeconds(_Period);
        }
      else
         return;   // could not read data this tick; retry next tick
     }

//--- Phase 2 - open if there is a signal and no position in that direction
   if(ExtSignalOpen != SIGNAL_NOT && !PositionExist(ExtSignalOpen))
     {
      Print("Signal to open position ", ExtDirection);
      PositionOpen();
      if(PositionExist(ExtSignalOpen))
         ExtSignalOpen = SIGNAL_NOT;
     }

//--- Phase 3 - close upon expiration (holding time in bars)
   if(InpDuration > 0 && ExtCloseByTime && PositionExpiredByTimeExist())
     {
      CloseByTime();
      ExtCloseByTime = PositionExpiredByTimeExist();
     }
  }
//+------------------------------------------------------------------+
//| Get current environment and compute the signal                   |
//+------------------------------------------------------------------+
bool CheckState()
  {
   ExtCheckPassed   = true;
   ExtSignalOpen    = SIGNAL_NOT;
   ExtDirection     = "";

//--- need enough closed bars for mean/std and ER
   int needBars = MathMax(InpMeanPeriod, InpERPeriod + 1) + 2;
   if(Bars(_Symbol, _Period) < needBars)
      return(true);   // not enough history yet; no signal, not an error

//--- rolling mean / std over the last InpMeanPeriod CLOSED bars (index 1..N)
   double mean = 0.0;
   for(int i = 1; i <= InpMeanPeriod; i++)
      mean += Close(i);
   mean /= InpMeanPeriod;

   double var = 0.0;
   for(int i = 1; i <= InpMeanPeriod; i++)
     {
      double d = Close(i) - mean;
      var += d * d;
     }
   double sd = MathSqrt(var / InpMeanPeriod);

//--- if any price read failed, report the error
   if(!ExtCheckPassed)
      return(false);
   if(sd < 1e-12)
      return(true);   // flat window, no signal

//--- z-score of the last closed bar
   double z = (Close(1) - mean) / sd;

//--- regime filter: Kaufman Efficiency Ratio
   double er = EfficiencyRatio();
   if(!ExtCheckPassed)
      return(false);

   string info = StringFormat("z=%.2f ER=%.2f", z, er);

   if(er <= InpERGate)
     {
      if(z >= InpZEntry)
        {
         ExtSignalOpen = SIGNAL_SELL;   // fade the up-spike
         ExtDirection  = "Sell";
         Print("FADE SHORT: ", info);
        }
      else if(z <= -InpZEntry)
        {
         ExtSignalOpen = SIGNAL_BUY;    // fade the down-spike
         ExtDirection  = "Buy";
         Print("FADE LONG: ", info);
        }
     }

//--- live status on the chart
   Comment("PropAlgo ", _Symbol,
           " | ", info,
           " | gate(ER<=", DoubleToString(InpERGate, 2), ")=", (er <= InpERGate ? "Y" : "N"),
           " | signal=", ExtDirection == "" ? "none" : ExtDirection);

   return(true);
  }
//+------------------------------------------------------------------+
//| Open a position in the direction of the signal (fixed lot)       |
//+------------------------------------------------------------------+
bool PositionOpen()
  {
   ExtSymbolInfo.Refresh();
   ExtSymbolInfo.RefreshRates();

   int    digits = ExtSymbolInfo.Digits();
   double point  = ExtSymbolInfo.Point();
   double spread = ExtSymbolInfo.Ask() - ExtSymbolInfo.Bid();

   double price, stoploss = 0.0, takeprofit = 0.0;

//--- BUY
   if(ExtSignalOpen == SIGNAL_BUY)
     {
      price = NormalizeDouble(ExtSymbolInfo.Ask(), digits);
      if(InpSL > 0)
        {
         double sld = (spread >= InpSL * point) ? spread : InpSL * point;
         stoploss = NormalizeDouble(price - sld, digits);
        }
      if(InpTP > 0)
        {
         double tpd = (spread >= InpTP * point) ? spread : InpTP * point;
         takeprofit = NormalizeDouble(price + tpd, digits);
        }
      if(!ExtTrade.Buy(InpLot, _Symbol, price, stoploss, takeprofit))
        {
         PrintFormat("Buy failed: %s %.2f at %G (sl=%G tp=%G) err=%d",
                     _Symbol, InpLot, price, stoploss, takeprofit, GetLastError());
         return(false);
        }
     }

//--- SELL
   if(ExtSignalOpen == SIGNAL_SELL)
     {
      price = NormalizeDouble(ExtSymbolInfo.Bid(), digits);
      if(InpSL > 0)
        {
         double sld = (spread >= InpSL * point) ? spread : InpSL * point;
         stoploss = NormalizeDouble(price + sld, digits);
        }
      if(InpTP > 0)
        {
         double tpd = (spread >= InpTP * point) ? spread : InpTP * point;
         takeprofit = NormalizeDouble(price - tpd, digits);
        }
      if(!ExtTrade.Sell(InpLot, _Symbol, price, stoploss, takeprofit))
        {
         PrintFormat("Sell failed: %s %.2f at %G (sl=%G tp=%G) err=%d",
                     _Symbol, InpLot, price, stoploss, takeprofit, GetLastError());
         return(false);
        }
     }

   return(true);
  }
//+------------------------------------------------------------------+
//| Close positions upon holding time expiration in bars             |
//+------------------------------------------------------------------+
void CloseByTime()
  {
   int positions = PositionsTotal();
   for(int i = positions - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
         if(BarsHold(open_time) >= (int)InpDuration)
           {
            Print("Time to close position #", ticket);
            ExtTrade.PositionClose(ticket, InpSlippage);
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Returns true if there is an open position in the given direction |
//+------------------------------------------------------------------+
bool PositionExist(int signal_direction)
  {
   ENUM_POSITION_TYPE search_type = WRONG_VALUE;
   if(signal_direction == SIGNAL_BUY)  search_type = POSITION_TYPE_BUY;
   if(signal_direction == SIGNAL_SELL) search_type = POSITION_TYPE_SELL;

   int positions = PositionsTotal();
   for(int i = 0; i < positions; i++)
     {
      if(PositionGetTicket(i) == 0) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(signal_direction != SIGNAL_NOT && type != search_type) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| Returns true if any of our positions has exceeded the hold time  |
//+------------------------------------------------------------------+
bool PositionExpiredByTimeExist()
  {
   int positions = PositionsTotal();
   for(int i = 0; i < positions; i++)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
         int check = BarsHold(open_time);
         if(check == -1 || check >= (int)InpDuration)
            return(true);
        }
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| Number of bars a position has been held                          |
//+------------------------------------------------------------------+
int BarsHold(datetime open_time)
  {
   if(TimeCurrent() - open_time < PeriodSeconds(_Period))
      return(0);
   MqlRates bars[];
   if(CopyRates(_Symbol, _Period, open_time, TimeCurrent(), bars) == -1)
     {
      Print("Error. CopyRates() failed, error = ", GetLastError());
      return(-1);
     }
   return(ArraySize(bars));
  }
//+------------------------------------------------------------------+
//| Kaufman Efficiency Ratio over InpERPeriod CLOSED bars            |
//|  ER = |C[1]-C[1+P]| / sum_{i=1..P} |C[i]-C[i+1]|                 |
//+------------------------------------------------------------------+
double EfficiencyRatio()
  {
   double net = MathAbs(Close(1) - Close(1 + InpERPeriod));
   double vol = 0.0;
   for(int i = 1; i <= InpERPeriod; i++)
      vol += MathAbs(Close(i) - Close(i + 1));
   if(vol < 1e-12)
      return(1.0);   // treat as fully trending -> filtered out
   return(net / vol);
  }
//+------------------------------------------------------------------+
//| Close price accessor (index 1 = last CLOSED bar). Flags errors.  |
//+------------------------------------------------------------------+
double Close(int index)
  {
   double val = iClose(_Symbol, _Period, index);
   if(ExtCheckPassed && val == 0) ExtCheckPassed = false;
   return(val);
  }
//+------------------------------------------------------------------+
