//+------------------------------------------------------------------+
//|                                            JevGateCalibrate.mq5  |
//|  Checks whether a JevGate answer is calibrated on YOUR data and  |
//|  shows what a veto at each threshold would have done.            |
//|                                                                  |
//|  Joins answers (replay scores or live decisions) with outcomes   |
//|  logged by jev.LogOutcome() on the snapshot ref, then reports:   |
//|   * Brier score, log loss, expected calibration error (ECE)      |
//|   * reliability table: predicted probability vs what happened    |
//|   * veto table: trades removed at each threshold and their value |
//|                                                                  |
//|  Output goes to the Experts log and to                           |
//|  <Common>\Files\JevGate\calibration_<profile>_<question>.txt     |
//+------------------------------------------------------------------+
#property copyright   "JevGate contributors"
#property version     "2.00"
#property description "Calibration and veto-threshold report for JevGate answers"
#property script_show_inputs

#include <Generic\HashMap.mqh>

enum ENUM_CAL_SOURCE
  {
   CAL_BACKTEST = 0,   // Backtest (scores + outcomes_tester files)
   CAL_LIVE,           // Live (decisions + outcomes for this chart's symbol/timeframe)
   CAL_CUSTOM          // Custom file names below
  };

input string          InpProfile   = "example_entry";  // Profile
input ENUM_CAL_SOURCE InpSource    = CAL_BACKTEST;     // Data source
input string          InpQuestion  = "trend_against";  // Answer key (e.g. trend_against, regime.trending, setup_quality)
input string          InpEvents    = "loss";           // Outcome results that count as the event (comma-separated)
input double          InpScale     = 1.0;              // Divide the answer by this (e.g. 3 for a 4-level score)
input bool            InpInvert    = false;            // Use 1 - answer (when a LOW answer predicts the event)
input int             InpBins      = 10;               // Reliability bins
input string          InpAnswersFile  = "";            // Custom: answers file in <Common>\Files\JevGate
input string          InpOutcomesFile = "";            // Custom: outcomes file in <Common>\Files\JevGate

string g_report[];

//+------------------------------------------------------------------+
void Out(const string line)
  {
   Print(line);
   int n = ArraySize(g_report);
   ArrayResize(g_report,n + 1,256);
   g_report[n] = line;
  }

string Safe(const string s)
  {
   string r = s;
   string bad[] = {"\\","/",":","*","?","\"","<",">","|"," "};
   for(int i = 0; i < ArraySize(bad); i++)
      StringReplace(r,bad[i],"_");
   return r;
  }

string TfName(void)
  {
   string s = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(s,"PERIOD_","");
   return s;
  }

bool LooksNumeric(const string s)
  {
   int n = StringLen(s);
   bool digit = false;
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s,i);
      if(c >= '0' && c <= '9')
         digit = true;
      else if(!(c == '.' || ((c == '-' || c == '+') && i == 0)))
         return false;
     }
   return digit;
  }

//--- read a tab-separated file with a header row; returns column index map via names[]
bool ReadTsv(const string path,string &header[],string &lines[])
  {
   ArrayResize(header,0);
   ArrayResize(lines,0);
   int h = FileOpen(path,FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return false;
   bool first = true;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringReplace(line,"\r","");
      if(line == "")
         continue;
      if(first)
        {
         StringSplit(line,'\t',header);
         first = false;
         continue;
        }
      int n = ArraySize(lines);
      ArrayResize(lines,n + 1,1024);
      lines[n] = line;
     }
   FileClose(h);
   return true;
  }

int Col(const string &header[],const string name)
  {
   for(int i = 0; i < ArraySize(header); i++)
      if(header[i] == name)
         return i;
   return -1;
  }

//--- value of `key` in "ok=1;model=x;key=value;...", or "" if missing / not ok
string ReplyValue(const string reply,const string key)
  {
   string parts[];
   int n = StringSplit(reply,';',parts);
   bool ok = false;
   string val = "";
   bool found = false;
   for(int i = 0; i < n; i++)
     {
      int eq = StringFind(parts[i],"=");
      if(eq <= 0)
         continue;
      string k = StringSubstr(parts[i],0,eq);
      string v = StringSubstr(parts[i],eq + 1);
      if(k == "ok")
         ok = (v == "1");
      else if(k == key)
        {
         val = v;
         found = true;
        }
     }
   return (ok && found) ? val : "";
  }

string Pct(const double v,const int count)
  {
   return count > 0 ? StringFormat("%14.3f",v) : StringFormat("%14s","-");
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   ArrayResize(g_report,0);
   string dir = "JevGate\\";
   string answersFile, outcomesFile;
   if(InpSource == CAL_BACKTEST)
     {
      answersFile  = "scores_" + InpProfile + ".tsv";
      outcomesFile = "outcomes_tester_" + InpProfile + ".tsv";
     }
   else if(InpSource == CAL_LIVE)
     {
      string suffix = InpProfile + "_" + Safe(_Symbol) + "_" + TfName() + ".tsv";
      answersFile  = "decisions_" + suffix;
      outcomesFile = "outcomes_" + suffix;
     }
   else
     {
      answersFile  = InpAnswersFile;
      outcomesFile = InpOutcomesFile;
     }
   if(InpScale <= 0 || InpBins < 2)
     {
      Print("JevGateCalibrate: Scale must be > 0 and Bins >= 2");
      return;
     }

   //--- events
   string evParts[];
   int nEv = StringSplit(InpEvents,',',evParts);
   for(int i = 0; i < nEv; i++)
     {
      StringTrimLeft(evParts[i]);
      StringTrimRight(evParts[i]);
     }

   //--- answers
   string hdr[], rows[];
   if(!ReadTsv(dir + answersFile,hdr,rows))
     {
      PrintFormat("JevGateCalibrate: cannot open <Common>\\Files\\%s%s",dir,answersFile);
      return;
     }
   int cRef = Col(hdr,"ref"), cResp = Col(hdr,"response");
   if(cRef < 0 || cResp < 0)
     {
      PrintFormat("JevGateCalibrate: %s has no ref/response columns",answersFile);
      return;
     }
   CHashMap<string,double> preds;
   for(int i = 0; i < ArraySize(rows); i++)
     {
      string c[];
      if(StringSplit(rows[i],'\t',c) <= MathMax(cRef,cResp))
         continue;
      string v = ReplyValue(c[cResp],InpQuestion);
      if(v == "")
         continue;
      if(!LooksNumeric(v))
        {
         PrintFormat("JevGateCalibrate: '%s' is a label (e.g. '%s'). Use an option key such as %s.<option>",InpQuestion,v,InpQuestion);
         return;
        }
      double p = StringToDouble(v) / InpScale;
      if(InpInvert)
         p = 1.0 - p;
      p = MathMax(0.0,MathMin(1.0,p));
      if(!preds.Add(c[cRef],p))
         preds.TrySetValue(c[cRef],p);
     }

   //--- outcomes
   string ohdr[], orows[];
   if(!ReadTsv(dir + outcomesFile,ohdr,orows))
     {
      PrintFormat("JevGateCalibrate: cannot open <Common>\\Files\\%s%s",dir,outcomesFile);
      return;
     }
   int oRef = Col(ohdr,"ref"), oRes = Col(ohdr,"result"), oVal = Col(ohdr,"value");
   if(oRef < 0 || oRes < 0)
     {
      PrintFormat("JevGateCalibrate: %s has no ref/result columns",outcomesFile);
      return;
     }
   CHashMap<string,int>    evMap;
   CHashMap<string,double> valMap;
   for(int i = 0; i < ArraySize(orows); i++)
     {
      string c[];
      int nc = StringSplit(orows[i],'\t',c);
      if(nc <= MathMax(oRef,oRes))
         continue;
      int y = 0;
      for(int e = 0; e < nEv; e++)
         if(evParts[e] != "" && c[oRes] == evParts[e])
            y = 1;
      double val = (oVal >= 0 && oVal < nc) ? StringToDouble(c[oVal]) : 0.0;
      if(!evMap.Add(c[oRef],y))
         evMap.TrySetValue(c[oRef],y);
      if(!valMap.Add(c[oRef],val))
         valMap.TrySetValue(c[oRef],val);
     }

   //--- join
   string keys[];
   double pv[];
   preds.CopyTo(keys,pv);
   double P[], V[];
   int    Y[];
   int n = 0;
   for(int i = 0; i < ArraySize(keys); i++)
     {
      int y;
      if(!evMap.TryGetValue(keys[i],y))
         continue;
      double val = 0;
      valMap.TryGetValue(keys[i],val);
      ArrayResize(P,n + 1,1024);
      ArrayResize(Y,n + 1,1024);
      ArrayResize(V,n + 1,1024);
      P[n] = pv[i];
      Y[n] = y;
      V[n] = val;
      n++;
     }
   if(n == 0)
     {
      PrintFormat("JevGateCalibrate: no overlap: %d answers, %d outcomes. Check both files come from the same run and profile.",
                  preds.Count(),evMap.Count());
      return;
     }

   //--- metrics
   double eps = 1e-6, sumY = 0, brier = 0, logloss = 0;
   for(int i = 0; i < n; i++)
     {
      sumY    += Y[i];
      brier   += (P[i] - Y[i]) * (P[i] - Y[i]);
      logloss -= Y[i] * MathLog(MathMax(P[i],eps)) + (1 - Y[i]) * MathLog(MathMax(1 - P[i],eps));
     }
   double base = sumY / n;
   brier   /= n;
   logloss /= n;
   double brierRef = base * (1 - base);

   int    bN[];
   double bP[], bY[], bV[];
   ArrayResize(bN,InpBins);
   ArrayResize(bP,InpBins);
   ArrayResize(bY,InpBins);
   ArrayResize(bV,InpBins);
   ArrayInitialize(bN,0);
   ArrayInitialize(bP,0);
   ArrayInitialize(bY,0);
   ArrayInitialize(bV,0);
   for(int i = 0; i < n; i++)
     {
      int b = MathMin((int)(P[i] * InpBins),InpBins - 1);
      bN[b]++;
      bP[b] += P[i];
      bY[b] += Y[i];
      bV[b] += V[i];
     }
   double ece = 0;
   for(int b = 0; b < InpBins; b++)
      if(bN[b] > 0)
         ece += (double)bN[b] / n * MathAbs(bP[b] / bN[b] - bY[b] / bN[b]);

   //--- report
   Out(StringFormat("JevGate calibration  profile=%s  question=%s%s  event=%s  source=%s",
                    InpProfile,InpQuestion,(InpInvert ? " (inverted)" : ""),InpEvents,EnumToString(InpSource)));
   Out(StringFormat("answers=%s  outcomes=%s  matched=%d (answers %d, outcomes %d)",
                    answersFile,outcomesFile,n,preds.Count(),evMap.Count()));
   Out(StringFormat("base rate      %.3f",base));
   Out(StringFormat("Brier          %.4f   (always-predict-base-rate: %.4f; lower is better)",brier,brierRef));
   Out(StringFormat("log loss       %.4f",logloss));
   Out(StringFormat("ECE            %.4f   (0 = perfectly calibrated)",ece));
   if(n < 200)
      Out("WARNING: fewer than 200 matched outcomes; treat everything below as noise.");

   Out("");
   Out("Reliability (does 'p=0.7' happen 70% of the time?)");
   Out(StringFormat("%11s %6s %8s %8s %11s","bin","n","mean p","actual","sum value"));
   for(int b = 0; b < InpBins; b++)
     {
      if(bN[b] == 0)
         continue;
      Out(StringFormat("%4.2f-%4.2f %6d %8.3f %8.3f %11.2f",
                       (double)b / InpBins,(double)(b + 1) / InpBins,bN[b],bP[b] / bN[b],bY[b] / bN[b],bV[b]));
     }

   Out("");
   Out("Veto table (veto when p > threshold)");
   Out(StringFormat("%6s %7s %14s %14s %13s %11s","thresh","vetoed","event% vetoed","event% kept","value vetoed","value kept"));
   for(int t20 = 6; t20 < 20; t20++)
     {
      double t = t20 / 20.0;
      int    nv = 0, nk = 0;
      double yv = 0, yk = 0, vv = 0, vk = 0;
      for(int i = 0; i < n; i++)
        {
         if(P[i] > t)
           { nv++; yv += Y[i]; vv += V[i]; }
         else
           { nk++; yk += Y[i]; vk += V[i]; }
        }
      Out(StringFormat("%6.2f %7d %s %s %13.2f %11.2f",t,nv,
                       Pct(nv > 0 ? yv / nv : 0,nv),Pct(nk > 0 ? yk / nk : 0,nk),vv,vk));
     }
   Out("");
   Out("A useful veto removes trades whose summed value is negative while keeping event% low in the kept set.");
   Out("Pick thresholds on one period and confirm them on a later, untouched period.");

   //--- save report
   string q = InpQuestion;
   StringReplace(q,".","_");
   string path = dir + "calibration_" + InpProfile + "_" + q + ".txt";
   int h = FileOpen(path,FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
     {
      for(int i = 0; i < ArraySize(g_report); i++)
         FileWriteString(h,g_report[i] + "\r\n");
      FileClose(h);
      PrintFormat("JevGateCalibrate: report saved to <Common>\\Files\\%s",path);
     }
  }
//+------------------------------------------------------------------+
