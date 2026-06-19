//+------------------------------------------------------------------+
//|                                                     PropAlgo.mq5  |
//|         Regime-filtered, multi-instrument mean-reversion EA       |
//|                                                                  |
//|  Strategy (fixed, pre-validated):                                |
//|   - Learns recurring price shapes (matrix-profile motifs) from   |
//|     recent H1 history (unsupervised).                            |
//|   - Trades them ONLY in ranging conditions (Kaufman Efficiency   |
//|     Ratio gate).                                                 |
//|   - Fixed 1:1.5 bracket (SL = 2.0*ATR14, TP = 3.0*ATR14).        |
//|   - Anti-overfit gates: min occurrences, mean-R>0, split-half    |
//|     robustness, one-sided t-test + Benjamini-Hochberg FDR.       |
//|   - Walk-forward: train trailing 18 months, retrain monthly.     |
//|   - Prop-firm risk: 0.5%/trade, -2% daily cutoff, -10% halt,     |
//|     ~3% concurrent open risk cap, 6 trades/week (lowest ER).     |
//|                                                                  |
//|  Basket (LOCKED): XAUUSD, FTSE100, S&P500, Copper, DAX           |
//|  Timeframe      : H1 only (LOCKED)                               |
//|                                                                  |
//|  All logic (pattern matching, regime filter, sizing, risk) is    |
//|  computed natively inside this EA. No external signal file.      |
//+------------------------------------------------------------------+
#property copyright "PropAlgo"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//==================================================================
//  COMPILE-TIME CONSTANTS (strategy is locked)
//==================================================================
#define WLEN        20      // motif / pattern window length m (LOCKED)
#define NSYM         5      // basket size (LOCKED)

//==================================================================
//  INPUTS  (broker symbol map + risk + strategy parameters)
//==================================================================
input group "=== Broker symbol map (edit to match your broker) ==="
input string  InpSym_XAU    = "XAUUSD_ECN";   // Gold
input string  InpSym_FTSE   = "UK100_ECN";    // FTSE 100
input string  InpSym_SP     = "US500_ECN";    // S&P 500
input string  InpSym_COPPER = "XCUUSD_ECN";   // Copper
input string  InpSym_DAX    = "GER40_ECN";    // DAX

input group "=== Round-trip cost (fraction of price) - RE-MEASURE! ==="
input double  InpCost_XAU    = 0.0003;     // XAUUSD round-trip cost
input double  InpCost_FTSE   = 0.0003;     // FTSE round-trip cost
input double  InpCost_SP     = 0.0002;     // S&P round-trip cost
input double  InpCost_COPPER = 0.0007;     // Copper round-trip cost
input double  InpCost_DAX    = 0.0003;     // DAX round-trip cost

input group "=== Risk / prop-firm limits (HARD) ==="
input double  InpRiskPct          = 0.005; // risk per trade (0.5%)
input double  InpDailyLossCutoff  = 0.02;  // stop new trades after -2% on the day
input double  InpMaxTotalDD       = 0.10;  // hard-halt at -10% from start equity
input double  InpMaxConcurrentRisk= 0.03;  // cap concurrent open risk (~3%)
input int     InpWeeklyCap        = 6;     // max trades/week across basket (lowest ER)
input double  InpStartCapital     = 5000.0;// reference starting capital ($)

input group "=== Strategy parameters (LOCKED - do not change) ==="
input int     InpATRPeriod    = 14;        // ATR period
input int     InpERPeriod     = 50;        // Kaufman Efficiency Ratio period
input double  InpERGate       = 0.45;      // trade only when entry-bar ER <= this
input double  InpMatchTol     = 3.0;       // z-norm Euclidean match tolerance
input double  InpMotifCutoff  = 3.0;       // matrix-profile motif cutoff
input int     InpMaxMotifs    = 20;        // max motifs discovered per train
input int     InpDirHorizon   = 8;         // bars used to fix direction (training)
input double  InpSL_ATR       = 2.0;       // stop  = SL_ATR * ATR
input double  InpTP_ATR       = 3.0;       // target= TP_ATR * ATR (1:1.5)
input int     InpTimeStop     = 48;        // time stop in bars
input int     InpMinOcc       = 25;        // min occurrences to keep a template
input int     InpSplitMin     = 8;         // min trades in each split-half
input double  InpFDR_Q        = 0.10;      // Benjamini-Hochberg FDR q

input group "=== Walk-forward / data ==="
input int     InpTrainMonths  = 18;        // trailing months used for training
input int     InpMaxTrainBars = 13000;     // safety cap on training bars (~18mo H1)

input group "=== Execution / safety ==="
input long    InpMagic         = 990515;   // EA magic number
input int     InpSlippage      = 20;       // max deviation (points)
input bool    InpAllowReal      = false;   // allow trading on a REAL account (safety)
input bool    InpVerboseLog     = true;    // verbose logging

//==================================================================
//  DATA STRUCTURES
//==================================================================
struct Template
{
   double z[WLEN];   // z-normalized template shape
   int    dir;       // trade direction (+1 long / -1 short), fixed from training
};

struct SymState
{
   string    broker;        // broker symbol name
   double    cost;          // round-trip cost (fraction of price)
   Template  tmpl[];        // active (surviving) templates
   datetime  lastBar;       // last processed H1 bar open time
   int       trainMonth;    // month of last retrain
   int       trainYear;     // year  of last retrain
   bool      trained;       // has ever trained
   bool      enabled;       // symbol resolved & selectable
};

SymState   g_sym[NSYM];
CTrade     g_trade;

double     g_startEquity   = 0.0;   // equity captured at init (for DD floor)
double     g_floorEquity   = 0.0;   // hard-halt floor
bool       g_halted        = false; // global drawdown halt latched

// daily tracking
int        g_curDay        = -1;
double     g_dayStartEquity= 0.0;

// weekly tracking
int        g_curWeekKey    = -1;
int        g_weeklyCount    = 0;

//==================================================================
//  UTILITY: logging
//==================================================================
void Log(string msg)
{
   Print("[PropAlgo] ", msg);
}
void LogV(string msg)
{
   if(InpVerboseLog) Print("[PropAlgo] ", msg);
}

//==================================================================
//  MATH: gammln, incomplete beta, Student-t one-sided p-value
//  (Numerical-Recipes style; used for the t-test inside FDR gate)
//==================================================================
double GammLn(double xx)
{
   double cof[6] = {76.18009172947146,-86.50532032941677,
                    24.01409824083091,-1.231739572450155,
                    0.1208650973866179e-2,-0.5395239384953e-5};
   double x = xx;
   double y = xx;
   double tmp = x + 5.5;
   tmp -= (x + 0.5) * MathLog(tmp);
   double ser = 1.000000000190015;
   for(int j = 0; j < 6; j++)
   {
      y += 1.0;
      ser += cof[j] / y;
   }
   return -tmp + MathLog(2.5066282746310005 * ser / x);
}

double BetaCF(double a, double b, double x)
{
   const int    MAXIT = 200;
   const double EPS   = 3.0e-12;
   const double FPMIN = 1.0e-300;

   double qab = a + b;
   double qap = a + 1.0;
   double qam = a - 1.0;
   double c = 1.0;
   double d = 1.0 - qab * x / qap;
   if(MathAbs(d) < FPMIN) d = FPMIN;
   d = 1.0 / d;
   double h = d;
   for(int m = 1; m <= MAXIT; m++)
   {
      int    m2 = 2 * m;
      double aa = m * (b - m) * x / ((qam + m2) * (a + m2));
      d = 1.0 + aa * d; if(MathAbs(d) < FPMIN) d = FPMIN;
      c = 1.0 + aa / c; if(MathAbs(c) < FPMIN) c = FPMIN;
      d = 1.0 / d;
      h *= d * c;
      aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
      d = 1.0 + aa * d; if(MathAbs(d) < FPMIN) d = FPMIN;
      c = 1.0 + aa / c; if(MathAbs(c) < FPMIN) c = FPMIN;
      d = 1.0 / d;
      double del = d * c;
      h *= del;
      if(MathAbs(del - 1.0) < EPS) break;
   }
   return h;
}

// Regularized incomplete beta I_x(a,b)
double BetaI(double a, double b, double x)
{
   if(x <= 0.0) return 0.0;
   if(x >= 1.0) return 1.0;
   double bt = MathExp(GammLn(a + b) - GammLn(a) - GammLn(b)
                       + a * MathLog(x) + b * MathLog(1.0 - x));
   if(x < (a + 1.0) / (a + b + 2.0))
      return bt * BetaCF(a, b, x) / a;
   else
      return 1.0 - bt * BetaCF(b, a, 1.0 - x) / b;
}

// One-sided p-value for H0: mean<=0 vs H1: mean>0, given t and df.
// p = P(T >= t)
double StudentTOneSidedP(double t, double df)
{
   if(df <= 0.0) return 1.0;
   double x  = df / (df + t * t);
   double ib = BetaI(0.5 * df, 0.5, x);   // = 2*P(T>=|t|)/1 ... handled below
   double tail = 0.5 * ib;                // P(T >= |t|)
   if(t >= 0.0) return tail;              // upper tail
   return 1.0 - tail;                     // t<0 -> most mass above
}

//==================================================================
//  FEATURES: ATR(14), z-window, Efficiency Ratio
//==================================================================
// True Range based ATR, rolling mean over period, min_periods=1.
// Arrays are chronological (index 0 = oldest).
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
   // rolling mean over <period> bars, min_periods=1
   double run = 0.0;
   for(int i = 0; i < n; i++)
   {
      run += tr[i];
      if(i >= period) run -= tr[i - period];
      int cnt = (i + 1 < period) ? (i + 1) : period;
      atr[i] = run / cnt;
   }
}

// z-normalize window c[start .. start+WLEN-1] into zout[WLEN].
// std<1e-8 -> zeros.
void ZWindow(const double &c[], int start, double &zout[])
{
   double mean = 0.0;
   for(int k = 0; k < WLEN; k++) mean += c[start + k];
   mean /= WLEN;
   double var = 0.0;
   for(int k = 0; k < WLEN; k++)
   {
      double dd = c[start + k] - mean;
      var += dd * dd;
   }
   double sd = MathSqrt(var / WLEN);
   if(sd < 1e-8)
   {
      for(int k = 0; k < WLEN; k++) zout[k] = 0.0;
      return;
   }
   double inv = 1.0 / sd;
   for(int k = 0; k < WLEN; k++) zout[k] = (c[start + k] - mean) * inv;
}

// Kaufman Efficiency Ratio at index t over <period> bars.
// ER[t] = |c[t]-c[t-period]| / sum_{i=t-period+1..t}|c[i]-c[i-1]|.
// Returns 1.0 (treated as trending) when undefined.
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

// Euclidean distance between two equal-length z arrays.
double ZDist(const double &a[], const double &b[])
{
   double s = 0.0;
   for(int k = 0; k < WLEN; k++)
   {
      double d = a[k] - b[k];
      s += d * d;
   }
   return MathSqrt(s);
}

//==================================================================
//  TRADE SIMULATION (training): bracket walk-forward up to TimeStop
//  Returns R-multiple (pnl / sl_distance), cost-adjusted.
//  entry index = ei (window-end close). Requires ei+TimeStop < n.
//==================================================================
double SimulateTradeR(const double &h[], const double &l[], const double &c[],
                      const double &atr[], int n, int ei, int dir, double cost)
{
   double entry   = c[ei];
   double slDist  = InpSL_ATR * atr[ei];
   double tpDist  = InpTP_ATR * atr[ei];
   if(slDist <= 0.0) return 0.0;

   double stopPx  = (dir > 0) ? entry - slDist : entry + slDist;
   double targPx  = (dir > 0) ? entry + tpDist : entry - tpDist;

   double pnl = 0.0;     // in price terms, signed
   bool   closed = false;

   int last = ei + InpTimeStop;
   if(last >= n) last = n - 1;

   for(int k = ei + 1; k <= last; k++)
   {
      if(dir > 0)
      {
         // conservative: if a bar touches both, stop first -> loss
         if(l[k] <= stopPx) { pnl = -slDist; closed = true; break; }
         if(h[k] >= targPx) { pnl =  tpDist; closed = true; break; }
      }
      else
      {
         if(h[k] >= stopPx) { pnl = -slDist; closed = true; break; }
         if(l[k] <= targPx) { pnl =  tpDist; closed = true; break; }
      }
   }
   if(!closed)
   {
      // exit at time-stop close
      pnl = (c[last] - entry) * dir;
   }

   // subtract round-trip cost (fraction of price -> price units)
   double costPx = cost * entry;
   pnl -= costPx;

   return pnl / slDist;   // R-multiple
}

//==================================================================
//  STATISTICS HELPERS
//==================================================================
double MeanArr(const double &x[], int from, int to)
{
   int n = to - from;
   if(n <= 0) return 0.0;
   double s = 0.0;
   for(int i = from; i < to; i++) s += x[i];
   return s / n;
}

double StdArr(const double &x[], int from, int to, double mean)
{
   int n = to - from;
   if(n < 2) return 0.0;
   double s = 0.0;
   for(int i = from; i < to; i++)
   {
      double d = x[i] - mean;
      s += d * d;
   }
   return MathSqrt(s / (n - 1));   // sample std
}

//==================================================================
//  TRAINING for one symbol:
//   - copy trailing 18mo H1 data
//   - precompute z-windows + ATR
//   - matrix-profile motif discovery (brute force, exclusion zone)
//   - per template: matches, direction, trade sim, anti-overfit gates
//   - Benjamini-Hochberg FDR across survivors -> store active templates
//==================================================================
void TrainSymbol(int s)
{
   string sym = g_sym[s].broker;
   double cost = g_sym[s].cost;

   // ---- 1. copy data (chronological) ----
   int want = InpMaxTrainBars;
   double c[], h[], l[];
   ArraySetAsSeries(c, false);
   ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false);

   // skip the currently-forming bar (start_pos = 1)
   int nc = CopyClose(sym, PERIOD_H1, 1, want, c);
   int nh = CopyHigh (sym, PERIOD_H1, 1, want, h);
   int nl = CopyLow  (sym, PERIOD_H1, 1, want, l);
   int n  = MathMin(nc, MathMin(nh, nl));
   if(n < 400)
   {
      Log(sym + ": insufficient history (" + IntegerToString(n) + " bars) - cannot train.");
      ArrayResize(g_sym[s].tmpl, 0);
      g_sym[s].trained = true;
      return;
   }
   if(n < nc) { ArrayResize(c, n); ArrayResize(h, n); ArrayResize(l, n); }

   // ---- 2. ATR + z-windows ----
   double atr[];
   ComputeATR(h, l, c, n, InpATRPeriod, atr);

   int M = n - WLEN + 1;           // number of windows
   if(M < 50) { ArrayResize(g_sym[s].tmpl, 0); g_sym[s].trained = true; return; }

   double zwin[];                   // flattened M x WLEN z-windows
   ArrayResize(zwin, M * WLEN);
   double tmpz[WLEN];
   for(int i = 0; i < M; i++)
   {
      ZWindow(c, i, tmpz);
      int base = i * WLEN;
      for(int k = 0; k < WLEN; k++) zwin[base + k] = tmpz[k];
   }

   int excl = WLEN / 2;             // exclusion zone

   // ---- 3. matrix profile (nearest-neighbour distance per window) ----
   //  Brute force O(M^2 * WLEN) with early abandon. Runs once / month.
   double mp[];
   ArrayResize(mp, M);
   for(int i = 0; i < M; i++) mp[i] = DBL_MAX;

   for(int i = 0; i < M; i++)
   {
      int bi = i * WLEN;
      double best = mp[i];          // best (smallest) squared dist so far
      for(int j = 0; j < M; j++)
      {
         if(MathAbs(i - j) < excl) continue;
         int bj = j * WLEN;
         double d2 = 0.0;
         for(int k = 0; k < WLEN; k++)
         {
            double df = zwin[bi + k] - zwin[bj + k];
            d2 += df * df;
            if(d2 >= best) break;    // early abandon
         }
         if(d2 < best) best = d2;
      }
      mp[i] = best;                  // squared nearest-neighbour distance
   }

   // ---- 4. extract up to InpMaxMotifs anchors (greedy, low MP first) ----
   //  candidate anchors: MP <= cutoff^2 ; skip overlapping (exclusion).
   double cutoff2 = InpMotifCutoff * InpMotifCutoff;
   // greedy selection of smallest-MP anchors (full sort is unnecessary;
   //  partial selection of up to InpMaxMotifs anchors is enough)
   bool   usedAnchor[];
   ArrayResize(usedAnchor, M);
   for(int i = 0; i < M; i++) usedAnchor[i] = false;

   int    anchors[];
   ArrayResize(anchors, 0);
   int    nAnchors = 0;

   while(nAnchors < InpMaxMotifs)
   {
      // find global min MP among unused, valid candidates
      double bestVal = DBL_MAX;
      int    bestIdx = -1;
      for(int i = 0; i < M; i++)
      {
         if(usedAnchor[i]) continue;
         if(mp[i] > cutoff2) continue;
         if(mp[i] < bestVal) { bestVal = mp[i]; bestIdx = i; }
      }
      if(bestIdx < 0) break;        // no more motifs under cutoff

      // accept anchor, block exclusion neighbourhood
      ArrayResize(anchors, nAnchors + 1);
      anchors[nAnchors] = bestIdx;
      nAnchors++;
      int lo = bestIdx - excl; if(lo < 0) lo = 0;
      int hi = bestIdx + excl; if(hi > M - 1) hi = M - 1;
      for(int q = lo; q <= hi; q++) usedAnchor[q] = true;
   }

   // ---- 5. per anchor: matches, direction, simulation, gates ----
   Template cand[];     // surviving-before-FDR candidate templates
   double   candP[];    // their one-sided p-values
   ArrayResize(cand, 0);
   ArrayResize(candP, 0);
   int nCand = 0;

   for(int a = 0; a < nAnchors; a++)
   {
      int ai = anchors[a];
      double tz[WLEN];
      for(int k = 0; k < WLEN; k++) tz[k] = zwin[ai * WLEN + k];

      // gather match entry indices (window-end close), exclusion applied
      int    entries[];
      ArrayResize(entries, 0);
      int    nEnt = 0;
      int    lastAccepted = -100000;
      double tol2 = InpMatchTol * InpMatchTol;

      for(int j = 0; j < M; j++)
      {
         if(j - lastAccepted < excl) continue;   // exclusion between matches
         int bj = j * WLEN;
         double d2 = 0.0;
         bool   ok = true;
         for(int k = 0; k < WLEN; k++)
         {
            double df = tz[k] - zwin[bj + k];
            d2 += df * df;
            if(d2 > tol2) { ok = false; break; }
         }
         if(!ok) continue;
         int ei = j + WLEN - 1;                   // window-end index = entry
         // need room for direction horizon AND time stop
         if(ei + InpTimeStop >= n) continue;
         if(ei + InpDirHorizon >= n) continue;
         ArrayResize(entries, nEnt + 1);
         entries[nEnt] = ei;
         nEnt++;
         lastAccepted = j;
      }

      if(nEnt < InpMinOcc) continue;               // occurrence gate

      // direction: mean of forward DirHorizon-bar return (training, no look-ahead bias)
      double rsum = 0.0;
      for(int e = 0; e < nEnt; e++)
      {
         int ei = entries[e];
         rsum += (c[ei + InpDirHorizon] - c[ei]) / c[ei];
      }
      int dir = (rsum / nEnt >= 0.0) ? +1 : -1;

      // simulate bracket trades -> R-multiples (ordered by entry time)
      double R[];
      ArrayResize(R, nEnt);
      for(int e = 0; e < nEnt; e++)
         R[e] = SimulateTradeR(h, l, c, atr, n, entries[e], dir, cost);

      double meanR = MeanArr(R, 0, nEnt);
      if(meanR <= 0.0) continue;                   // mean-R gate

      // split-half robustness (split by median entry time = median index here,
      // entries already ordered ascending by time)
      int half = nEnt / 2;
      int nEarly = half;
      int nLate  = nEnt - half;
      if(nEarly < InpSplitMin || nLate < InpSplitMin) continue;
      double meanEarly = MeanArr(R, 0, half);
      double meanLate  = MeanArr(R, half, nEnt);
      if(meanEarly <= 0.0 || meanLate <= 0.0) continue;

      // one-sided t-test (H1: mean R > 0)
      double sd = StdArr(R, 0, nEnt, meanR);
      double pval;
      if(sd < 1e-12)
         pval = (meanR > 0.0) ? 0.0 : 1.0;
      else
      {
         double tstat = meanR / (sd / MathSqrt((double)nEnt));
         pval = StudentTOneSidedP(tstat, (double)(nEnt - 1));
      }

      // record candidate
      ArrayResize(cand, nCand + 1);
      ArrayResize(candP, nCand + 1);
      for(int k = 0; k < WLEN; k++) cand[nCand].z[k] = tz[k];
      cand[nCand].dir = dir;
      candP[nCand] = pval;
      nCand++;

      LogV(sym + ": candidate motif occ=" + IntegerToString(nEnt) +
           " dir=" + IntegerToString(dir) +
           " meanR=" + DoubleToString(meanR, 3) +
           " p=" + DoubleToString(pval, 4));
   }

   // ---- 6. Benjamini-Hochberg FDR at q across candidates ----
   ArrayResize(g_sym[s].tmpl, 0);
   if(nCand > 0)
   {
      // sort candidate indices by p ascending (simple insertion sort)
      int idx[];
      ArrayResize(idx, nCand);
      for(int i = 0; i < nCand; i++) idx[i] = i;
      for(int i = 1; i < nCand; i++)
      {
         int key = idx[i];
         double kp = candP[key];
         int j = i - 1;
         while(j >= 0 && candP[idx[j]] > kp)
         {
            idx[j + 1] = idx[j];
            j--;
         }
         idx[j + 1] = key;
      }
      // largest rank k (1-based) with p_(k) <= (k/m)*q
      int kMax = 0;
      for(int r = 1; r <= nCand; r++)
      {
         double thresh = ((double)r / (double)nCand) * InpFDR_Q;
         if(candP[idx[r - 1]] <= thresh) kMax = r;
      }
      // keep the kMax smallest-p candidates
      int kept = 0;
      for(int r = 0; r < kMax; r++)
      {
         int ci = idx[r];
         ArrayResize(g_sym[s].tmpl, kept + 1);
         for(int k = 0; k < WLEN; k++) g_sym[s].tmpl[kept].z[k] = cand[ci].z[k];
         g_sym[s].tmpl[kept].dir = cand[ci].dir;
         kept++;
      }
      Log(sym + ": trained. candidates=" + IntegerToString(nCand) +
          " kept(FDR q=" + DoubleToString(InpFDR_Q, 2) + ")=" + IntegerToString(kept));
   }
   else
   {
      Log(sym + ": trained. no candidate motifs passed gates.");
   }

   g_sym[s].trained = true;
}

//==================================================================
//  SIGNAL: evaluate the last completed bar's window for symbol s.
//  Returns true and fills (dir, er) if a valid signal exists.
//==================================================================
bool EvaluateSignal(int s, int &dirOut, double &erOut)
{
   if(!g_sym[s].trained) return false;
   if(ArraySize(g_sym[s].tmpl) == 0) return false;

   string sym = g_sym[s].broker;

   // need WLEN closes ending at last completed bar, plus ER lookback
   int need = MathMax(WLEN, InpERPeriod + 2) + 2;
   double c[];
   ArraySetAsSeries(c, false);
   int got = CopyClose(sym, PERIOD_H1, 1, need, c);   // skip forming bar
   if(got < need) return false;

   int last = got - 1;                  // index of last completed bar
   int wstart = last - WLEN + 1;
   if(wstart < 0) return false;

   // z-normalize the candidate window
   double zw[WLEN];
   ZWindow(c, wstart, zw);

   // regime gate (entry-bar ER)
   double er = EfficiencyRatio(c, last, InpERPeriod);
   if(er > InpERGate) return false;

   // match against active templates -> nearest within tolerance
   double bestD = DBL_MAX;
   int    bestDir = 0;
   int    nt = ArraySize(g_sym[s].tmpl);
   for(int t = 0; t < nt; t++)
   {
      double d = ZDist(zw, g_sym[s].tmpl[t].z);
      if(d <= InpMatchTol && d < bestD)
      {
         bestD = d;
         bestDir = g_sym[s].tmpl[t].dir;
      }
   }
   if(bestDir == 0) return false;

   dirOut = bestDir;
   erOut  = er;
   return true;
}

//==================================================================
//  POSITION / RISK helpers
//==================================================================
bool HasOpenPosition(string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
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
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   }
   return n;
}

// position size from risk formula, rounded to lot step & clamped.
double ComputeLots(string sym, double slDistPrice)
{
   if(slDistPrice <= 0.0) return 0.0;
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney= equity * InpRiskPct;

   double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickVal <= 0.0) return 0.0;

   double valuePerPricePerLot = tickVal / tickSize;   // money per 1.0 price move / lot
   double lots = riskMoney / (slDistPrice * valuePerPricePerLot);

   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;

   lots = MathFloor(lots / step) * step;
   if(lots < minL) return 0.0;          // cannot risk-size down to min -> skip
   if(lots > maxL) lots = maxL;
   return lots;
}

//==================================================================
//  OPEN a bracketed market order for symbol s in direction dir.
//==================================================================
bool OpenTrade(int s, int dir)
{
   string sym = g_sym[s].broker;

   // current ATR for bracket sizing (use last completed bar ATR)
   int need = InpATRPeriod + 5;
   double c[], h[], l[];
   ArraySetAsSeries(c, false);
   ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false);
   if(CopyClose(sym, PERIOD_H1, 1, need, c) < need) return false;
   if(CopyHigh (sym, PERIOD_H1, 1, need, h) < need) return false;
   if(CopyLow  (sym, PERIOD_H1, 1, need, l) < need) return false;
   int nn = ArraySize(c);
   double atr[];
   ComputeATR(h, l, c, nn, InpATRPeriod, atr);
   double atrNow = atr[nn - 1];
   if(atrNow <= 0.0) return false;

   double slDist = InpSL_ATR * atrNow;
   double tpDist = InpTP_ATR * atrNow;

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double entry, sl, tp;
   if(dir > 0) { entry = ask; sl = entry - slDist; tp = entry + tpDist; }
   else        { entry = bid; sl = entry + slDist; tp = entry - tpDist; }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lots = ComputeLots(sym, slDist);
   if(lots <= 0.0)
   {
      LogV(sym + ": lot size resolved to 0 - skipping.");
      return false;
   }

   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetExpertMagicNumber(InpMagic);

   bool ok;
   if(dir > 0)
      ok = g_trade.Buy(lots, sym, 0.0, sl, tp, "PropAlgo");
   else
      ok = g_trade.Sell(lots, sym, 0.0, sl, tp, "PropAlgo");

   if(ok)
   {
      Log(sym + ": OPEN " + (dir > 0 ? "BUY" : "SELL") +
          " lots=" + DoubleToString(lots, 2) +
          " entry~" + DoubleToString(entry, digits) +
          " SL=" + DoubleToString(sl, digits) +
          " TP=" + DoubleToString(tp, digits) +
          " (ATR=" + DoubleToString(atrNow, digits) + ")");
   }
   else
   {
      Log(sym + ": order FAILED ret=" + IntegerToString(g_trade.ResultRetcode()) +
          " (" + g_trade.ResultRetcodeDescription() + ")");
   }
   return ok;
}

//==================================================================
//  TIME-STOP management: close EA positions older than InpTimeStop bars
//==================================================================
void ManageTimeStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
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
//  DAILY / WEEKLY / GLOBAL risk-state maintenance
//==================================================================
int WeekKey(datetime t)
{
   MqlDateTime st;
   TimeToStruct(t, st);
   // ISO-ish week bucket: year*100 + day_of_year/7
   return st.year * 100 + (st.day_of_year / 7);
}

void UpdateRiskState()
{
   datetime now = TimeCurrent();
   MqlDateTime st;
   TimeToStruct(now, st);

   // ---- daily reset ----
   if(st.day != g_curDay)
   {
      g_curDay = st.day;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      LogV("New trading day. Day-start equity=" + DoubleToString(g_dayStartEquity, 2));
   }

   // ---- weekly reset ----
   int wk = WeekKey(now);
   if(wk != g_curWeekKey)
   {
      g_curWeekKey = wk;
      g_weeklyCount = 0;
      LogV("New trading week. Weekly trade counter reset.");
   }

   // ---- global drawdown halt ----
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
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEquity <= 0.0) return false;
   double dayPnLpct = (equity - g_dayStartEquity) / g_dayStartEquity;
   if(dayPnLpct <= -InpDailyLossCutoff)
   {
      LogV("Daily loss cutoff active (day P/L=" + DoubleToString(dayPnLpct * 100.0, 2) + "%).");
      return true;
   }
   return false;
}

// concurrent open risk cap: each open EA position ~ InpRiskPct of equity.
bool ConcurrentRiskOK()
{
   int open = CountEAPositions();
   double projected = (double)(open + 1) * InpRiskPct;
   return (projected <= InpMaxConcurrentRisk + 1e-9);
}

//==================================================================
//  RETRAIN scheduling (monthly) + new-bar detection
//==================================================================
bool NeedRetrain(int s)
{
   if(!g_sym[s].trained) return true;
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   if(st.year != g_sym[s].trainYear || st.mon != g_sym[s].trainMonth)
      return true;
   return false;
}

void MarkTrained(int s)
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   g_sym[s].trainYear  = st.year;
   g_sym[s].trainMonth = st.mon;
}

//==================================================================
//  INIT
//==================================================================
int OnInit()
{
   // map symbols + costs
   string brokers[NSYM] = {InpSym_XAU, InpSym_FTSE, InpSym_SP, InpSym_COPPER, InpSym_DAX};
   double costs[NSYM]   = {InpCost_XAU, InpCost_FTSE, InpCost_SP, InpCost_COPPER, InpCost_DAX};

   for(int s = 0; s < NSYM; s++)
   {
      g_sym[s].broker     = brokers[s];
      g_sym[s].cost       = costs[s];
      g_sym[s].lastBar    = 0;
      g_sym[s].trained    = false;
      g_sym[s].trainMonth = -1;
      g_sym[s].trainYear  = -1;
      ArrayResize(g_sym[s].tmpl, 0);

      bool ok = SymbolSelect(brokers[s], true);
      g_sym[s].enabled = ok;
      if(!ok)
         Log("WARNING: symbol '" + brokers[s] + "' not found / not selectable. Disabled.");
      else
         LogV("Symbol mapped: " + brokers[s] + " cost=" + DoubleToString(costs[s], 5));
   }

   // risk anchors
   g_startEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_startEquity <= 0.0) g_startEquity = InpStartCapital;
   g_floorEquity = g_startEquity * (1.0 - InpMaxTotalDD);

   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetExpertMagicNumber(InpMagic);

   // real-account safety
   bool isReal = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
   if(isReal && !InpAllowReal)
      Log("SAFETY: REAL account detected and InpAllowReal=false. EA will analyze/log but NOT trade.");

   Log("Initialized. Start equity=" + DoubleToString(g_startEquity, 2) +
       " DD floor=" + DoubleToString(g_floorEquity, 2) +
       " risk/trade=" + DoubleToString(InpRiskPct * 100.0, 2) + "%");

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Log("Deinitialized (reason " + IntegerToString(reason) + ").");
}

//==================================================================
//  MAIN LOOP
//==================================================================
void OnTick()
{
   UpdateRiskState();

   // time-stop management runs regardless of halt (to flatten stale trades)
   ManageTimeStops();

   if(g_halted) return;                 // global drawdown halt -> no new trades

   // can we open trades right now?
   bool isReal = (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
   bool tradingAllowed = (!isReal || InpAllowReal) && !DailyLockout()
                         && (g_weeklyCount < InpWeeklyCap);

   // collect this-tick candidate signals (symbols that just closed a new H1 bar)
   int    candSym[NSYM];
   int    candDir[NSYM];
   double candER[NSYM];
   int    nCand = 0;

   for(int s = 0; s < NSYM; s++)
   {
      if(!g_sym[s].enabled) continue;

      datetime bt = iTime(g_sym[s].broker, PERIOD_H1, 0);
      if(bt == 0) continue;
      if(bt == g_sym[s].lastBar) continue;     // no new bar for this symbol
      g_sym[s].lastBar = bt;

      // monthly retrain (also first-time train)
      if(NeedRetrain(s))
      {
         LogV(g_sym[s].broker + ": (re)training on trailing " +
              IntegerToString(InpTrainMonths) + " months ...");
         TrainSymbol(s);
         MarkTrained(s);
      }

      if(!tradingAllowed) continue;
      if(HasOpenPosition(g_sym[s].broker)) continue;   // one position per symbol

      int    dir;
      double er;
      if(EvaluateSignal(s, dir, er))
      {
         candSym[nCand] = s;
         candDir[nCand] = dir;
         candER[nCand]  = er;
         nCand++;
      }
   }

   if(nCand == 0) return;

   // sort candidates by ER ascending (lowest ER = most ranging = highest conviction)
   for(int i = 1; i < nCand; i++)
   {
      int    ks = candSym[i], kd = candDir[i];
      double ke = candER[i];
      int j = i - 1;
      while(j >= 0 && candER[j] > ke)
      {
         candSym[j + 1] = candSym[j];
         candDir[j + 1] = candDir[j];
         candER[j + 1]  = candER[j];
         j--;
      }
      candSym[j + 1] = ks;
      candDir[j + 1] = kd;
      candER[j + 1]  = ke;
   }

   // open trades respecting weekly cap & concurrent risk cap
   for(int i = 0; i < nCand; i++)
   {
      if(g_weeklyCount >= InpWeeklyCap) break;
      int s = candSym[i];
      if(HasOpenPosition(g_sym[s].broker)) continue;
      if(!ConcurrentRiskOK())
      {
         LogV("Concurrent risk cap reached - holding remaining signals.");
         break;
      }
      if(OpenTrade(s, candDir[i]))
      {
         g_weeklyCount++;
         Log(g_sym[s].broker + ": trade taken (ER=" + DoubleToString(candER[i], 3) +
             ", weekly " + IntegerToString(g_weeklyCount) + "/" +
             IntegerToString(InpWeeklyCap) + ").");
      }
   }
}
//+------------------------------------------------------------------+
