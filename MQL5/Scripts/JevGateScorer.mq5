//+------------------------------------------------------------------+
//|                                               JevGateScorer.mq5  |
//|  Scores snapshots recorded in the Strategy Tester so they can be |
//|  replayed in a backtest.                                          |
//|                                                                  |
//|  The tester cannot make web requests, so backtesting is:         |
//|   1. Run the backtest with JevGate in AUTO/RECORD mode           |
//|   2. Drag this script onto ANY live/demo chart, set the profile  |
//|   3. Run the backtest again: AUTO mode now replays the answers   |
//|                                                                  |
//|  Re-running resumes where it left off.                           |
//+------------------------------------------------------------------+
#property copyright   "JevGate contributors"
#property version     "2.00"
#property description "Scores JevGate RECORD snapshots via the TypeSafe API for REPLAY backtests"
#property script_show_inputs

#include <Generic\HashSet.mqh>
#include <JevGate\JevGate.mqh>

input string InpProfile    = "example_entry"; // Profile (same as the EA's)
input string InpApiKey     = "";              // API key (blank = <Common>\Files\JevGate\api_key.txt)
input string InpModel      = "";              // Model (blank = model recorded with the snapshots)
input int    InpTimeoutMs  = 10000;           // Request timeout (ms)
input int    InpMaxRetries = 4;               // Retries on rate limit / overload / network errors
input int    InpPauseMs    = 0;               // Pause between requests (ms)

//+------------------------------------------------------------------+
bool ReadLines(const string path,string &lines[])
  {
   ArrayResize(lines,0);
   int h = FileOpen(path,FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE)
      return false;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringReplace(line,"\r","");
      if(line == "")
         continue;
      int n = ArraySize(lines);
      ArrayResize(lines,n + 1,1024);
      lines[n] = line;
     }
   FileClose(h);
   return true;
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   CJevGate gate;
   if(InpApiKey != "")
      gate.SetApiKey(InpApiKey);
   if(InpModel != "")
      gate.SetModel(InpModel);
   if(!gate.InitScorer(InpProfile,InpTimeoutMs))
      return;

   string snapPath  = "JevGate\\snapshots_" + InpProfile + ".tsv";
   string scorePath = "JevGate\\scores_" + InpProfile + ".tsv";

   //--- what is already scored (resume)
   CHashSet<string> done;
   string existing[];
   if(ReadLines(scorePath,existing))
      for(int i = 0; i < ArraySize(existing); i++)
        {
         int tab = StringFind(existing[i],"\t");
         if(tab > 0 && StringFind(existing[i],"ref\t") != 0)
            done.Add(StringSubstr(existing[i],0,tab));
        }

   string rows[];
   if(!ReadLines(snapPath,rows))
     {
      PrintFormat("JevGateScorer: cannot open <Common>\\Files\\%s. Run a RECORD backtest first.",snapPath);
      return;
     }

   //--- open (or create) the scores file for appending
   int out = FileOpen(scorePath,FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(out == INVALID_HANDLE)
     {
      PrintFormat("JevGateScorer: cannot open %s (error %d)",scorePath,GetLastError());
      return;
     }
   if(FileSize(out) == 0)
      FileWriteString(out,"ref\tresponse\r\n");
   FileSeek(out,0,SEEK_END);

   int total = 0, ok = 0, failed = 0, skipped = 0;
   for(int i = 0; i < ArraySize(rows); i++)
      if(StringFind(rows[i],"ref\t") != 0)
         total++;
   PrintFormat("JevGateScorer: %d snapshots, %d already scored", total, done.Count());

   bool fatal = false;
   int  seen  = 0;
   for(int i = 0; i < ArraySize(rows) && !IsStopped() && !fatal; i++)
     {
      string c[];
      if(StringFind(rows[i],"ref\t") == 0 || StringSplit(rows[i],'\t',c) < 7)
         continue;
      seen++;
      string ref = c[0];
      if(done.Contains(ref))
        {
         skipped++;
         continue;
        }
      // columns: ref, profile, symbol, timeframe, bar_time, tag, features
      string flat = "";
      int    code = 0;
      for(int attempt = 0; attempt <= InpMaxRetries && !IsStopped(); attempt++)
        {
         code = gate.ScoreRecordedRow(c[2],c[3],c[5],c[6],flat);
         if(StringFind(flat,"ok=1") == 0)
            break;
         if(code == 401 || code == 422 || gate.Status() == JG_NOT_ALLOWED)
           {
            PrintFormat("JevGateScorer: stopping - %s",gate.LastError());
            fatal = true;
            break;
           }
         if(attempt < InpMaxRetries)
            Sleep((int)MathMin(30000,1000 * MathPow(2,attempt)));   // back off on 429/529/network errors
        }
      if(fatal)
         break;

      if(StringFind(flat,"ok=1") == 0)
        {
         FileWriteString(out,ref + "\t" + flat + "\r\n");
         done.Add(ref);
         ok++;
        }
      else
        {
         failed++;
         PrintFormat("JevGateScorer: failed %s - %s",ref,gate.LastError());
        }

      if((ok + failed) % 10 == 0)
        {
         FileFlush(out);
         Comment(StringFormat("JevGateScorer [%s]: %d / %d  (ok %d, failed %d)",InpProfile,seen,total,ok + skipped,failed));
        }
      if(InpPauseMs > 0)
         Sleep(InpPauseMs);
     }
   FileClose(out);
   Comment("");

   PrintFormat("JevGateScorer: scored %d, failed %d, already done %d. Output: <Common>\\Files\\%s",ok,failed,skipped,scorePath);
   if(failed > 0 || IsStopped() || fatal)
      Print("JevGateScorer: run the script again to retry what is missing");
   else
      Print("JevGateScorer: done. Rerun the backtest; AUTO mode will replay these answers.");
  }
//+------------------------------------------------------------------+
