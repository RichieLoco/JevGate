//+------------------------------------------------------------------+
//|                                              JevGateExample.mq5  |
//|  Minimal example of wiring JevGate into an EA.                   |
//|                                                                  |
//|  Base strategy: a plain moving-average crossover. It is here     |
//|  only to show the integration pattern, NOT as a strategy to      |
//|  trade. JevGate can only veto entries the base strategy wants.   |
//+------------------------------------------------------------------+
#property copyright "JevGate contributors"
#property version   "2.00"
#property description "Example: MA crossover with an optional JevGate entry veto"

#include <Trade\Trade.mqh>
#include <JevGate\JevGate.mqh>

//--- base strategy
input group "Base strategy"
input int    InpFastMA        = 20;          // Fast MA period
input int    InpSlowMA        = 50;          // Slow MA period
input double InpLots          = 0.10;        // Lot size
input int    InpStopAtrMult   = 2;           // Stop loss (x ATR)
input int    InpTakeAtrMult   = 3;           // Take profit (x ATR)
input long   InpMagic         = 26100201;    // Magic number

//--- JevGate
input group "JevGate"
input bool              InpUseJudgment  = false;                            // Use JevGate veto (false = base strategy only)
input string            InpProfile      = "example_entry";                  // Profile name (names the log/replay files)
input ENUM_JEVGATE_MODE InpJevMode      = JEVGATE_AUTO;                     // Mode
input string            InpModel        = "jev-latest";                     // Model (pin a version once calibrated)
input int               InpTimeoutMs    = 3000;                             // Request timeout (ms)
input double            InpMaxTrendAgainst = 0.65;                          // Veto if P(trend continues against entry) above
input double            InpMinSetupScore   = 1.0;                           // Veto if setup quality score below (0-3)

CTrade   trade;
CJevGate jev;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hAtr = INVALID_HANDLE, hRsi = INVALID_HANDLE;
datetime g_lastBar  = 0;
ulong    g_posId    = 0;   // position we opened
string   g_openRef  = "";  // JevGate ref of the snapshot behind that entry

//+------------------------------------------------------------------+
int OnInit()
  {
   hFast = iMA(_Symbol,_Period,InpFastMA,0,MODE_EMA,PRICE_CLOSE);
   hSlow = iMA(_Symbol,_Period,InpSlowMA,0,MODE_EMA,PRICE_CLOSE);
   hAtr  = iATR(_Symbol,_Period,14);
   hRsi  = iRSI(_Symbol,_Period,14,PRICE_CLOSE);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);

   if(InpUseJudgment)
     {
      //--- configure: API key is read from <Common>\Files\JevGate\api_key.txt
      jev.SetModel(InpModel);
      jev.SetCircuitBreaker(3,300);   // 3 failures in a row -> pause calls for 5 minutes
      jev.SetContext("strategy","Moving-average crossover entry on forex. Features are in ATR units unless stated.");

      //--- define the questions once (atomic, specific)
      jev.AddNoul("trend_against",
                  "Will price trend against the entry direction (dir: 1=long, -1=short) over the next 20 bars?",
                  "Price moves meaningfully against the entry before any pullback",
                  "Price moves with the entry or ranges");
      jev.AddChoice("regime","Which market regime best describes this state?",
                    "trending: Persistent directional move|mean_reverting: Oscillating around a mean|chaotic: High volatility, no clear direction");
      jev.AddScore("setup_quality","How favourable is this state for the entry direction?",
                   "Poor|Marginal|Reasonable|Strong");

      if(!jev.Init(InpProfile,InpJevMode,InpTimeoutMs))
         return INIT_FAILED;
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(InpUseJudgment)
     {
      jev.PrintStats();
      jev.Deinit();
     }
   IndicatorRelease(hFast);
   IndicatorRelease(hSlow);
   IndicatorRelease(hAtr);
   IndicatorRelease(hRsi);
  }

//+------------------------------------------------------------------+
//| Your policy: JevGate answers, the EA decides.                    |
//| Returns true if the base strategy's entry may go ahead.          |
//+------------------------------------------------------------------+
bool AllowEntry(const int dir,const double atr)
  {
   if(!InpUseJudgment)
      return true;

   //--- 1. describe the state (all numbers your EA already computes)
   double fast[], slow[], rsi[], atrHist[];
   if(CopyBuffer(hFast,0,1,1,fast) != 1 || CopyBuffer(hSlow,0,1,11,slow) != 11 ||
      CopyBuffer(hRsi,0,1,1,rsi) != 1 || CopyBuffer(hAtr,0,1,100,atrHist) != 100)
      return true;   // cannot build the snapshot: behave like the base strategy

   double atrAvg = 0;
   for(int i = 0; i < 100; i++)
      atrAvg += atrHist[i];
   atrAvg /= 100.0;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(),t);

   jev.Begin(dir > 0 ? "buy" : "sell");
   jev.Add("dir",dir);
   jev.Add("ma_gap_atr",(fast[0] - slow[10]) / atr);           // slow[] is oldest-first: [10] = bar 1
   jev.Add("slow_slope_atr",(slow[10] - slow[0]) / atr);        // 10-bar slope of slow MA
   jev.Add("rsi",rsi[0]);
   jev.Add("atr_ratio",atr / atrAvg);
   jev.Add("hour",t.hour);

   //--- 2. ask
   if(!jev.Evaluate())
      return true;   // FALLBACK: no answer (record mode, replay miss, outage) -> base strategy

   //--- 3. decide, with thresholds you own
   double against = jev.Get("trend_against",0.0);
   double setup   = jev.Get("setup_quality",3.0);
   string regime  = jev.GetLabel("regime","");

   if(against > InpMaxTrendAgainst)
      return false;
   if(setup < InpMinSetupScore)
      return false;
   if(regime == "chaotic" && jev.Get("regime.p",0.0) > 0.6)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime bar = iTime(_Symbol,_Period,0);
   if(bar == g_lastBar)
      return;
   g_lastBar = bar;

   if(PositionSelectByTicket(g_posId))
      return;   // one position at a time

   double fast[], slow[], atr[];
   if(CopyBuffer(hFast,0,1,2,fast) != 2 || CopyBuffer(hSlow,0,1,2,slow) != 2 || CopyBuffer(hAtr,0,1,1,atr) != 1)
      return;

   int dir = 0;
   if(fast[0] <= slow[0] && fast[1] > slow[1]) dir = 1;    // crossed up on bar 1
   if(fast[0] >= slow[0] && fast[1] < slow[1]) dir = -1;   // crossed down on bar 1
   if(dir == 0)
      return;

   if(!AllowEntry(dir,atr[0]))
     {
      PrintFormat("JevGate veto: %s %s (ref %s)",dir > 0 ? "buy" : "sell",_Symbol,jev.LastRef());
      return;
     }

   double price = (dir > 0) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl = price - dir * InpStopAtrMult * atr[0];
   double tp = price + dir * InpTakeAtrMult * atr[0];
   bool sent = (dir > 0) ? trade.Buy(InpLots,_Symbol,price,sl,tp) : trade.Sell(InpLots,_Symbol,price,sl,tp);
   if(sent && trade.ResultRetcode() == TRADE_RETCODE_DONE)
     {
      g_posId   = trade.ResultOrder();   // position id = opening order ticket
      g_openRef = InpUseJudgment ? jev.LastRef() : "";
     }
  }

//+------------------------------------------------------------------+
//| Outcome logging: links each entry snapshot to how it ended,      |
//| giving you labelled data to calibrate thresholds later.          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || g_openRef == "")
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if((ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID) != g_posId)
      return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;
   double pnl = HistoryDealGetDouble(trans.deal,DEAL_PROFIT) +
                HistoryDealGetDouble(trans.deal,DEAL_SWAP) +
                HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   jev.LogOutcome(g_openRef,pnl > 0 ? "win" : "loss",pnl);
   g_openRef = "";
  }
//+------------------------------------------------------------------+
