//+------------------------------------------------------------------+
//|                                                     PropAlgo.mq5  |
//|        Regime-filtered short-term mean-reversion (fade) EA        |
//|                                                                  |
//|  HONEST STATUS — READ THIS:                                       |
//|   This EA is NOT validated. There is no out-of-sample, paper, or  |
//|   forward evidence shipped with it. The effect it trades —        |
//|   short-term price overextension reverting toward a rolling mean  |
//|   on liquid index/metal H1 — is thin, decays over time, and is    |
//|   highly sensitive to spread/commission. After YOUR real costs it |
//|   may have zero or negative expectancy. Treat every default as a  |
//|   starting guess, not a tuned value. Forward-test on a DEMO       |
//|   account for an extended period before risking real capital.     |
//|   Defaults are demo-safe (real-account trading is gated off).     |
//|                                                                  |
//|  WHAT IT DOES (transparent, no hidden "pattern mining"):          |
//|   - Per symbol, on each closed H1 bar, compute z = (close-mean)/  |
//|     std over a rolling window.                                    |
//|   - Trade ONLY in ranging regimes: Kaufman Efficiency Ratio(50)   |
//|     <= gate. (ER is used as a trend filter; do not fade trends.)  |
//|   - Fade the deviation: z >= +Zentry -> SHORT, z <= -Zentry ->    |
//|     LONG. Entry direction and exit are the SAME thesis.           |
//|   - Exit is reversion to the mean (dynamic TP), an ATR-based stop |
//|     (extension against = thesis wrong), and a time stop.          |
//|   - Costs measured LIVE: spread from the quote; risk/reward and   |
//|     position size computed via the broker's own OrderCalcProfit / |
//|     OrderCalcMargin (correct for indices & metals). A trade is    |
//|     skipped unless the reversion target clears both a risk        |
//|     multiple and a live-cost multiple.                            |
//|                                                                  |
//|  RISK (prop-firm style, enforced):                                |
//|   - One position per symbol; risk %/trade via broker P/L calc.    |
//|   - Correlated-cluster cap (equity indices share a budget).       |
//|   - Concurrent open-risk cap; weekly trade cap (lowest-ER first); |
//|     daily-loss cutoff; total-drawdown hard halt; time stops.      |
//|                                                                  |
//|  Basket (configurable): Gold, FTSE 100, S&P 500, Copper, DAX.     |
//|  Timeframe: H1.                                                   |
//+------------------------------------------------------------------+
#property copyright "PropAlgo"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

#define NSYM   5     // basket size

//==================================================================
//  INPUTS
//==================================================================
input group "=== Broker symbol map (edit to match your broker) ==="
input string  InpSym_XAU    = "XAUUSD_ECN";   // Gold
input string  InpSym_FTSE   = "UK100_ECN";    // FTSE 100
input string  InpSym_SP     = "US500_ECN";    // S&P 500
input string  InpSym_COPPER = "XCUUSD_ECN";   // Copper
input string  InpSym_DAX    = "GER40_ECN";    // DAX

input group "=== Signal (mean-reversion fade) ==="
input int     InpMeanPeriod   = 20;    // rolling mean/std window
input double  InpZEntry       = 2.0;   // |z| threshold to fade
input int     InpATRPeriod    = 14;    // ATR period (stop volatility floor)
input double  InpStopDevMult  = 1.5;   // stop = StopDevMult * reversion distance...
input double  InpStopFloorATR = 0.5;   // ...but at least StopFloorATR * ATR
input int     InpERPeriod     = 50;    // Kaufman Efficiency Ratio period
input double  InpERGate       = 0.45;  // trade only when entry-bar ER <= this
input int     InpTimeStop     = 24;    // time stop (bars) -> exit at market

input group "=== Cost / edge gates (LIVE-measured) ==="
input double  InpCommissionPerLot = 7.0;  // round-trip commission, acct ccy / 1.0 lot
input double  InpMinRR            = 0.5;   // reward-to-mean must be >= MinRR * risk
input double  InpMinCostMult      = 2.0;   // reward-to-mean must be >= MinCostMult * round-trip cost

input group "=== Risk / prop-firm limits (HARD) ==="
input double  InpRiskPct           = 0.005; // risk per trade (0.5%)
input double  InpDailyLossCutoff   = 0.02;  // stop new trades after -2% on the day
input double  InpMaxTotalDD        = 0.10;  // hard-halt at -10% from EA-init equity
input double  InpMaxConcurrentRisk = 0.03;  // cap concurrent open risk (~3%)
input int     InpWeeklyCap         = 6;     // max trades/week across basket (lowest ER)
input int     InpMaxPerClusterDir  = 1;     // max same-direction positions per correlated cluster

input group "=== Execution / safety ==="
input long    InpMagic     = 990515;   // EA magic number
input int     InpSlippage  = 20;       // max deviation (points)
input bool    InpAllowReal = false;    // allow trading on a REAL account (safety gate)
input bool    InpVerboseLog= true;     // verbose logging

//==================================================================
//  STATE
//==================================================================
struct SymState
{
   string    broker;     // broker symbol name
   int       cluster;    // correlation cluster id
   datetime  lastBar;    // last processed H1 bar open time
   bool      enabled;    // resolved & selectable
};

struct Signal
{
   bool   valid;
   int    dir;        // +1 long / -1 short
   double er;         // entry-bar efficiency ratio (lower = more ranging)
   double meanPrice;  // reversion target (rolling mean)
   double atr;        // ATR at signal bar
};

SymState g_sym[NSYM];
CTrade   g_trade;

double   g_startEquity = 0.0;   // equity at init (DD floor reference)
double   g_floorEquity = 0.0;
bool     g_halted      = false;

int      g_curDay         = -1;
double   g_dayStartEquity = 0.0;

long     g_curWeekKey  = -1;
int      g_weeklyCount = 0;

// --- diagnostic funnel counters (printed at end of test and daily) ---
long g_cEval=0, g_cErPass=0, g_cZSig=0;
long g_cRejReward=0, g_cRejRR=0, g_cRejCost=0, g_cRejLots=0, g_cRejMargin=0;
long g_cRejCluster=0, g_cRejConcurrent=0, g_cOpened=0;

void PrintFunnel(string tag)
{
   Log(tag + " FUNNEL: eval=" + IntegerToString(g_cEval) +
       " ER<=gate=" + IntegerToString(g_cErPass) +
       " |z|signals=" + IntegerToString(g_cZSig) +
       " | rejects: reward<=0=" + IntegerToString(g_cRejReward) +
       " RR=" + IntegerToString(g_cRejRR) +
       " cost=" + IntegerToString(g_cRejCost) +
       " lots=" + IntegerToString(g_cRejLots) +
       " margin=" + IntegerToString(g_cRejMargin) +
       " cluster=" + IntegerToString(g_cRejCluster) +
       " concurrent=" + IntegerToString(g_cRejConcurrent) +
       " | OPENED=" + IntegerToString(g_cOpened));
}

//==================================================================
//  LOGGING
//==================================================================
void Log (string m){ Print("[PropAlgo] ", m); }
void LogV(string m){ if(InpVerboseLog) Print("[PropAlgo] ", m); }

//==================================================================
//  FEATURES
//==================================================================
// ATR(14): TR = max(H-L, |H-prevC|, |L-prevC|); rolling mean, min_periods=1.
// Arrays chronological (index 0 = oldest).
void ComputeATR(const double &h[], const double &l[], const double &c[],
                int n, int period, double &atr[])
{
   ArrayResize(atr, n);
   if(n <= 0) return;
   double tr[];
   ArrayResize(tr, n);
   tr[0] = h[0] - l[0];
   for(int i = 1; i < n; i++)
   {
      double a = h[i] - l[i];
      double b = MathAbs(h[i] - c[i - 1]);
      double d = MathAbs(l[i] - c[i - 1]);
      tr[i] = MathMax(a, MathMax(b, d));
   }
   double run = 0.0;
   for(int i = 0; i < n; i++)
   {
      run += tr[i];
      if(i >= period) run -= tr[i - period];
      int cnt = (i + 1 < period) ? (i + 1) : period;
      atr[i] = run / cnt;
   }
}

// Kaufman Efficiency Ratio at index t over <period> bars.
// ER = |c[t]-c[t-period]| / sum|c[i]-c[i-1]|. Undefined -> 1.0 (treat as trending).
double EfficiencyRatio(const double &c[], int t, int period)
{
   if(t < period) return 1.0;
   double net = MathAbs(c[t] - c[t - period]);
   double vol = 0.0;
   for(int i = t - period + 1; i <= t; i++)
      vol += MathAbs(c[i] - c[i - 1]);
   if(vol < 1e-12) return 1.0;
   return net / vol;
}

//==================================================================
//  SIGNAL: evaluate the last completed H1 bar for symbol s.
//==================================================================
Signal EvaluateSignal(int s)
{
   Signal sig;
   sig.valid = false; sig.dir = 0; sig.er = 1.0; sig.meanPrice = 0.0; sig.atr = 0.0;

   string sym = g_sym[s].broker;

   int need = MathMax(MathMax(InpMeanPeriod, InpERPeriod + 2), InpATRPeriod) + 5;
   double c[], h[], l[];
   ArraySetAsSeries(c, false);
   ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false);
   // skip the currently-forming bar (start_pos = 1) -> only closed bars
   if(CopyClose(sym, PERIOD_H1, 1, need, c) < need) return sig;
   if(CopyHigh (sym, PERIOD_H1, 1, need, h) < need) return sig;
   if(CopyLow  (sym, PERIOD_H1, 1, need, l) < need) return sig;
   int n = ArraySize(c);
   int last = n - 1;
   g_cEval++;

   // regime filter (entry-bar ER)
   double er = EfficiencyRatio(c, last, InpERPeriod);
   if(er > InpERGate) return sig;
   g_cErPass++;

   // rolling mean / std over the last InpMeanPeriod closed bars
   double mean = 0.0;
   for(int k = 0; k < InpMeanPeriod; k++) mean += c[last - k];
   mean /= InpMeanPeriod;
   double var = 0.0;
   for(int k = 0; k < InpMeanPeriod; k++)
   {
      double dd = c[last - k] - mean;
      var += dd * dd;
   }
   double sd = MathSqrt(var / InpMeanPeriod);
   if(sd < 1e-12) return sig;

   double z = (c[last] - mean) / sd;

   int dir = 0;
   if(z >= InpZEntry)  dir = -1;   // overextended up  -> fade short
   if(z <= -InpZEntry) dir = +1;   // overextended down-> fade long
   if(dir == 0) return sig;

   // ATR for stop sizing
   double atr[];
   ComputeATR(h, l, c, n, InpATRPeriod, atr);
   double atrNow = atr[last];
   if(atrNow <= 0.0) return sig;
   g_cZSig++;

   sig.valid     = true;
   sig.dir       = dir;
   sig.er        = er;
   sig.meanPrice = mean;     // reversion target
   sig.atr       = atrNow;
   return sig;
}

//==================================================================
//  POSITION / CLUSTER helpers
//==================================================================
int SymIndexOfBroker(string sym)
{
   for(int s = 0; s < NSYM; s++)
      if(g_sym[s].broker == sym) return s;
   return -1;
}

bool HasOpenPosition(string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

int CountEAPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   }
   return n;
}

// same-direction open EA positions within a correlation cluster
int CountClusterDir(int cluster, int dir)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      int si = SymIndexOfBroker(PositionGetString(POSITION_SYMBOL));
      if(si < 0) continue;
      if(g_sym[si].cluster != cluster) continue;
      long pt = PositionGetInteger(POSITION_TYPE);
      int pdir = (pt == POSITION_TYPE_BUY) ? +1 : -1;
      if(pdir == dir) n++;
   }
   return n;
}

bool ConcurrentRiskOK()
{
   int open = CountEAPositions();
   double projected = (double)(open + 1) * InpRiskPct;
   return (projected <= InpMaxConcurrentRisk + 1e-9);
}

//==================================================================
//  OPEN a bracketed market order using the signal.
//  Sizing & cost/RR gates routed through broker P/L calc (accurate
//  for indices & metals; uses LIVE spread, not typed constants).
//==================================================================
bool OpenTrade(int s, Signal &sig)
{
   string sym    = g_sym[s].broker;
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return false;

   ENUM_ORDER_TYPE ot;
   double entry;
   if(sig.dir > 0) { ot = ORDER_TYPE_BUY;  entry = ask; }
   else            { ot = ORDER_TYPE_SELL; entry = bid; }

   // Bracket in REVERSION units (coherent with the signal):
   //  TP = the mean; stop = a multiple of the distance we are fading,
   //  floored at a fraction of ATR so it is never inside the noise.
   double devDist = MathAbs(sig.meanPrice - entry);              // reward distance
   double slDist  = MathMax(InpStopDevMult * devDist, InpStopFloorATR * sig.atr);
   if(slDist <= 0.0) return false;

   double sl = (sig.dir > 0) ? entry - slDist : entry + slDist;
   double tp = sig.meanPrice;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // --- broker-accurate money figures per 1.0 lot ---
   double lossPerLot = 0.0, rewardPerLot = 0.0, spreadCostPerLot = 0.0;
   if(!OrderCalcProfit(ot, sym, 1.0, entry, sl, lossPerLot))   return false;
   if(!OrderCalcProfit(ot, sym, 1.0, entry, tp, rewardPerLot)) return false;
   // immediate round-trip spread cost: open at entry, close at the opposite side.
   // Must succeed - a silent failure would understate cost and bypass the gate.
   double oppClose = (sig.dir > 0) ? bid : ask;
   if(!OrderCalcProfit(ot, sym, 1.0, entry, oppClose, spreadCostPerLot))
   {
      LogV(sym + ": OrderCalcProfit(spread) failed - cannot price cost, skip.");
      return false;
   }

   lossPerLot       = MathAbs(lossPerLot);
   spreadCostPerLot = MathAbs(spreadCostPerLot);
   double costPerLot = spreadCostPerLot + MathAbs(InpCommissionPerLot);

   if(lossPerLot <= 0.0) return false;

   // --- edge gates (live cost aware) ---
   if(rewardPerLot <= 0.0)
   {
      g_cRejReward++;
      LogV(sym + ": reversion target not profitable after spread - skip.");
      return false;
   }
   if(rewardPerLot < InpMinRR * lossPerLot)
   {
      g_cRejRR++;
      LogV(sym + ": reward/risk too low (" +
           DoubleToString(rewardPerLot / lossPerLot, 2) + ") - skip.");
      return false;
   }
   if(rewardPerLot < InpMinCostMult * costPerLot)
   {
      g_cRejCost++;
      LogV(sym + ": reward eaten by cost (reward=" + DoubleToString(rewardPerLot, 2) +
           " cost=" + DoubleToString(costPerLot, 2) + ") - skip.");
      return false;
   }

   // --- size from risk % using the broker's own loss figure ---
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPct;
   double lots      = riskMoney / lossPerLot;

   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   if(lots < minL)
   {
      g_cRejLots++;
      LogV(sym + ": risk-sized lots below broker minimum - skip.");
      return false;
   }
   if(lots > maxL) lots = maxL;

   // --- margin check ---
   double margin = 0.0;
   if(OrderCalcMargin(ot, sym, lots, entry, margin))
   {
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      {
         g_cRejMargin++;
         LogV(sym + ": insufficient free margin - skip.");
         return false;
      }
   }

   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(sym);

   bool ok = (sig.dir > 0)
             ? g_trade.Buy (lots, sym, 0.0, sl, tp, "PropAlgo")
             : g_trade.Sell(lots, sym, 0.0, sl, tp, "PropAlgo");

   // only treat as a taken trade if a deal actually executed
   bool filled = ok && g_trade.ResultRetcode() == TRADE_RETCODE_DONE
                 && g_trade.ResultDeal() > 0;

   if(filled)
   {
      g_cOpened++;
      Log(sym + ": OPEN " + (sig.dir > 0 ? "BUY" : "SELL") +
          " lots=" + DoubleToString(lots, 2) +
          " entry~" + DoubleToString(entry, digits) +
          " SL=" + DoubleToString(sl, digits) +
          " TP(mean)=" + DoubleToString(tp, digits) +
          " R/R=" + DoubleToString(rewardPerLot / lossPerLot, 2) +
          " cost=" + DoubleToString(costPerLot, 2));
   }
   else
   {
      Log(sym + ": order not filled ret=" + IntegerToString(g_trade.ResultRetcode()) +
          " (" + g_trade.ResultRetcodeDescription() + ")");
   }
   return filled;
}

//==================================================================
//  TIME-STOP management
//==================================================================
void ManageTimeStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      int shift = iBarShift(sym, PERIOD_H1, opened, false);
      if(shift >= InpTimeStop)
      {
         g_trade.SetDeviationInPoints(InpSlippage);
         g_trade.SetExpertMagicNumber(InpMagic);
         if(g_trade.PositionClose(tk))
            Log(sym + ": TIME-STOP close after " + IntegerToString(shift) + " bars.");
      }
   }
}

//==================================================================
//  RISK STATE (daily / weekly / global)
//==================================================================
void UpdateRiskState()
{
   datetime now = TimeCurrent();
   MqlDateTime st;
   TimeToStruct(now, st);

   if(st.day != g_curDay)
   {
      if(g_curDay != -1) PrintFunnel("daily");   // show the funnel each new day
      g_curDay = st.day;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      LogV("New trading day. Day-start equity=" + DoubleToString(g_dayStartEquity, 2));
   }

   // monotonic 7-day bucket (no year-boundary desync)
   long wk = (long)now / (7 * 86400);
   if(wk != g_curWeekKey)
   {
      g_curWeekKey  = wk;
      g_weeklyCount = 0;
      LogV("New trading week. Weekly trade counter reset.");
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!g_halted && equity <= g_floorEquity)
   {
      g_halted = true;
      Log("!!! MAX TOTAL DRAWDOWN HIT. Equity=" + DoubleToString(equity, 2) +
          " <= floor=" + DoubleToString(g_floorEquity, 2) + ". TRADING HALTED.");
   }
}

bool DailyLockout()
{
   if(g_dayStartEquity <= 0.0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPnLpct = (equity - g_dayStartEquity) / g_dayStartEquity;
   if(dayPnLpct <= -InpDailyLossCutoff)
   {
      LogV("Daily loss cutoff active (day P/L=" + DoubleToString(dayPnLpct * 100.0, 2) + "%).");
      return true;
   }
   return false;
}

//==================================================================
//  INIT
//==================================================================
int OnInit()
{
   string brokers[NSYM]  = {InpSym_XAU, InpSym_FTSE, InpSym_SP, InpSym_COPPER, InpSym_DAX};
   // correlation clusters: gold=0, equity indices(FTSE,S&P,DAX)=1, copper=2
   int    clusters[NSYM] = {0, 1, 1, 2, 1};

   for(int s = 0; s < NSYM; s++)
   {
      g_sym[s].broker  = brokers[s];
      g_sym[s].cluster = clusters[s];
      g_sym[s].lastBar = 0;

      bool ok = SymbolSelect(brokers[s], true);
      g_sym[s].enabled = ok;
      if(!ok)
         Log("ERROR: symbol '" + brokers[s] + "' not found / not selectable. "
             "This instrument will be SKIPPED. Fix the symbol map.");
      else
         LogV("Symbol mapped: " + brokers[s] + " (cluster " + IntegerToString(clusters[s]) + ")");
   }

   g_startEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_startEquity <= 0.0) g_startEquity = 5000.0;
   g_floorEquity = g_startEquity * (1.0 - InpMaxTotalDD);

   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetExpertMagicNumber(InpMagic);

   bool isReal = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
   if(isReal && !InpAllowReal)
      Log("SAFETY: REAL account detected and InpAllowReal=false. EA will MONITOR but NOT trade.");

   Log("Initialized (v2 mean-reversion fade). NOT validated - forward-test on demo. "
       "Start equity=" + DoubleToString(g_startEquity, 2) +
       " DD floor=" + DoubleToString(g_floorEquity, 2) +
       " risk/trade=" + DoubleToString(InpRiskPct * 100.0, 2) + "%");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintFunnel("FINAL");
   Log("Deinitialized (reason " + IntegerToString(reason) + ").");
}

//==================================================================
//  MAIN LOOP (light: no batch jobs on the tick thread)
//==================================================================
void OnTick()
{
   UpdateRiskState();
   ManageTimeStops();          // flatten stale EA positions (risk-reducing)

   if(g_halted) return;

   bool isReal = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
   bool tradingAllowed = (!isReal || InpAllowReal) && !DailyLockout()
                         && (g_weeklyCount < InpWeeklyCap);

   // gather this-cycle candidate signals (symbols that just closed a new H1 bar)
   int    candSym[NSYM];
   double candER[NSYM];
   Signal candSig[NSYM];
   int    nCand = 0;

   for(int s = 0; s < NSYM; s++)
   {
      // re-resolve a previously missing symbol if it has come back
      if(!g_sym[s].enabled)
      {
         if(SymbolSelect(g_sym[s].broker, true))
         {
            g_sym[s].enabled = true;
            Log("Symbol recovered: " + g_sym[s].broker);
         }
         else continue;
      }

      datetime bt = iTime(g_sym[s].broker, PERIOD_H1, 0);
      if(bt == 0 || bt == g_sym[s].lastBar) continue;   // no new bar
      g_sym[s].lastBar = bt;

      if(!tradingAllowed) continue;
      if(HasOpenPosition(g_sym[s].broker)) continue;     // one position per symbol

      Signal sig = EvaluateSignal(s);
      if(!sig.valid) continue;

      candSym[nCand] = s;
      candER[nCand]  = sig.er;
      candSig[nCand] = sig;
      nCand++;
   }

   if(nCand == 0) return;

   // lowest ER first (most ranging = highest conviction)
   for(int i = 1; i < nCand; i++)
   {
      int    ks = candSym[i];
      double ke = candER[i];
      Signal kg = candSig[i];
      int j = i - 1;
      while(j >= 0 && candER[j] > ke)
      {
         candSym[j + 1] = candSym[j];
         candER[j + 1]  = candER[j];
         candSig[j + 1] = candSig[j];
         j--;
      }
      candSym[j + 1] = ks;
      candER[j + 1]  = ke;
      candSig[j + 1] = kg;
   }

   for(int i = 0; i < nCand; i++)
   {
      if(g_weeklyCount >= InpWeeklyCap) break;
      int s = candSym[i];
      if(HasOpenPosition(g_sym[s].broker)) continue;
      if(!ConcurrentRiskOK())
      {
         g_cRejConcurrent++;
         LogV("Concurrent risk cap reached - holding remaining signals.");
         break;
      }
      // correlated-cluster cap: don't stack same-direction correlated bets
      if(CountClusterDir(g_sym[s].cluster, candSig[i].dir) >= InpMaxPerClusterDir)
      {
         g_cRejCluster++;
         LogV(g_sym[s].broker + ": cluster " + IntegerToString(g_sym[s].cluster) +
              " same-direction cap reached - skip.");
         continue;
      }
      if(OpenTrade(s, candSig[i]))
      {
         g_weeklyCount++;
         Log(g_sym[s].broker + ": trade taken (ER=" + DoubleToString(candER[i], 3) +
             ", weekly " + IntegerToString(g_weeklyCount) + "/" +
             IntegerToString(InpWeeklyCap) + ").");
      }
   }
}
//+------------------------------------------------------------------+
