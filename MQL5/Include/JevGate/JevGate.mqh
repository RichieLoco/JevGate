//+------------------------------------------------------------------+
//|                                                     JevGate.mqh  |
//|  Generic judgment gate for MQL5 Expert Advisors, calling the     |
//|  TypeSafe System One API (Jev) directly. No proxy, no DLLs.      |
//|                                                                  |
//|  Your EA defines typed questions once, describes the market      |
//|  state as named features, and reads typed answers back to use    |
//|  in its own decision rules.                                      |
//|                                                                  |
//|  JevGate never places, modifies or closes orders.                |
//|                                                                  |
//|  MIT licence. See README.md for full documentation.              |
//+------------------------------------------------------------------+
#ifndef JEVGATE_MQH
#define JEVGATE_MQH

#include <Generic\HashMap.mqh>
#include "JevJson.mqh"

#define JEVGATE_VERSION    "2.0.0"
#define JEVGATE_DIR        "JevGate"
#define JEVGATE_ENDPOINT   "https://api.typesafe.ai/v1/systemone"
#define JEVGATE_MODEL      "jev-latest"
#define JEVGATE_KEYFILE    "JevGate\\api_key.txt"

//--- Operating mode
enum ENUM_JEVGATE_MODE
  {
   JEVGATE_AUTO = 0,   // Auto (Live on charts; Replay or Record in tester)
   JEVGATE_LIVE,       // Live (call the API via WebRequest)
   JEVGATE_RECORD,     // Record (log snapshots only, no answers)
   JEVGATE_REPLAY,     // Replay (read pre-scored answers from file)
   JEVGATE_OFF         // Off (never evaluate)
  };

//--- Result of the last Evaluate() call
enum ENUM_JEVGATE_STATUS
  {
   JG_NONE = 0,        // Nothing evaluated yet
   JG_OK,              // Answers available
   JG_OFF,             // Mode is Off
   JG_RECORDED,        // Snapshot recorded (Record mode), no answers
   JG_REPLAY_MISS,     // Replay file has no answer for this snapshot
   JG_BREAKER_OPEN,    // Too many recent failures, calls paused
   JG_NOT_ALLOWED,     // WebRequest URL not allow-listed in the terminal
   JG_HTTP_ERROR,      // Network failure or timeout
   JG_API_ERROR,       // API returned an error (401, 422, 429, 529...)
   JG_PARSE_ERROR,     // Response could not be parsed
   JG_BAD_USAGE        // Setup or call order is wrong (see LastError())
  };

//+------------------------------------------------------------------+
//| CJevGate                                                         |
//+------------------------------------------------------------------+
class CJevGate
  {
private:
   //--- configuration
   string            m_profile;
   string            m_endpoint;
   string            m_model;
   string            m_apiKey;
   bool              m_includeSymbol;
   string            m_ctxKeys[];
   string            m_ctxVals[];
   string            m_ctxJson;          // loaded from file in scorer mode
   ENUM_JEVGATE_MODE m_mode;
   int               m_timeoutMs;
   bool              m_inited;
   bool              m_tester;
   bool              m_optimizing;
   bool              m_verbose;

   //--- questions
   string            m_qKeys[];
   string            m_qBodies[];        // JSON body of each question
   string            m_qJson;            // loaded from file in scorer mode

   //--- circuit breaker
   int               m_breakerFails;
   int               m_breakerCoolSecs;
   int               m_consecFails;
   ulong             m_breakerUntilMs;
   bool              m_warnedNotAllowed;

   //--- current snapshot
   bool              m_begun;
   string            m_tag;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   datetime          m_barTime;
   string            m_fKeys[];
   string            m_fVals[];
   bool              m_fIsText[];

   //--- last result
   ENUM_JEVGATE_STATUS m_status;
   string            m_lastRef;
   string            m_aKeys[];
   string            m_aVals[];
   string            m_lastModel;
   string            m_error;
   int               m_latencyMs;
   int               m_httpCode;

   //--- live cache (one answer per ref)
   string            m_cacheRef;
   string            m_cacheResp;

   //--- replay data
   CHashMap<string,string> m_replay;

   //--- files
   int               m_hSnap;
   int               m_hDec;
   int               m_hOut;

   //--- stats
   int               m_nEval;
   int               m_nCalls;
   int               m_nOk;
   int               m_nFail;
   int               m_nMiss;
   int               m_nRecorded;
   int               m_nCached;
   int               m_nLiveOk;
   long              m_latSum;
   long              m_tokIn;
   long              m_tokOut;

   //--- helpers
   string            Path(const string kind) const { return JEVGATE_DIR + "\\" + kind + "_" + m_profile + ".tsv"; }
   string            QuestionsPath(void) const    { return JEVGATE_DIR + "\\questions_" + m_profile + ".txt"; }
   string            LivePath(const string kind) const;
   static bool       IsSafeToken(const string s);
   static string     Clean(const string s);
   static string     FormatNum(const double v);
   static string     TfToString(const ENUM_TIMEFRAMES tf);
   static string     ModeToString(const ENUM_JEVGATE_MODE m);
   static string     Trim(const string s);
   static bool       LooksNumeric(const string s);
   int               OpenAppend(const string path,const string header);
   int               OpenTruncate(const string path,const string header);
   void              WriteLine(const int h,const string line);
   bool              LoadApiKey(void);
   bool              LoadReplay(void);
   bool              WriteQuestionsFile(void);
   bool              LoadQuestionsFile(void);
   bool              AddQuestion(const string key,const string body);
   string            QuestionsJson(void) const;
   string            ContextJson(void) const;
   string            BuildRef(void) const;
   string            FeaturesTsv(void) const;
   string            StateJson(const string symbol,const string tfStr,const string tag,
                               const string &keys[],const string &vals[],const bool &isText[]) const;
   int               CallApi(const string stateJson,string &flat);
   bool              ResponseToFlat(const string body,string &flat);
   static string     ApiErrorText(const int code,const string body);
   void              ClearAnswers(void);
   bool              ApplyResponse(const string resp);
   bool              EvaluateLive(const string feats);
   void              RegisterFailure(void);
   void              LogDecision(const string feats,const string resp);
   int               FindFeature(const string key) const;

public:
                     CJevGate(void);
                    ~CJevGate(void) { Deinit(); }

   //--- configure (call before Init)
   void              SetApiKey(const string key)             { m_apiKey = Trim(key); }
   void              SetModel(const string model)            { m_model = Trim(model); }
   void              SetEndpoint(const string url)           { m_endpoint = url; }
   void              SetIncludeSymbol(const bool include)    { m_includeSymbol = include; }
   bool              SetContext(const string key,const string text);
   void              SetCircuitBreaker(const int maxConsecutiveFails,const int coolDownSecs)
                       { m_breakerFails = maxConsecutiveFails; m_breakerCoolSecs = coolDownSecs; }
   void              SetVerbose(const bool verbose)          { m_verbose = verbose; }

   //--- define questions (call before Init)
   bool              AddNoul(const string key,const string instructions,
                             const string whenTrue = "",const string whenFalse = "");
   bool              AddChoice(const string key,const string instructions,const string options);
   bool              AddScore(const string key,const string instructions,const string levels);
   int               QuestionCount(void) const               { return ArraySize(m_qKeys); }

   //--- start / stop
   bool              Init(const string profile,const ENUM_JEVGATE_MODE mode = JEVGATE_AUTO,
                          const int timeoutMs = 3000);
   void              Deinit(void);

   //--- build a snapshot
   void              Begin(const string tag = "",const datetime barTime = 0,
                           const string symbol = "",const ENUM_TIMEFRAMES tf = PERIOD_CURRENT);
   bool              Add(const string key,const double value);
   bool              AddText(const string key,const string value);

   //--- evaluate
   bool              Evaluate(void);

   //--- read results
   bool              Ok(void) const                           { return m_status == JG_OK; }
   ENUM_JEVGATE_STATUS Status(void) const                     { return m_status; }
   string            StatusText(void) const;
   bool              Has(const string key) const;
   double            Get(const string key,const double dflt = 0.0) const;
   string            GetLabel(const string key,const string dflt = "") const;
   string            Model(void) const                        { return m_lastModel; }
   string            LastError(void) const                    { return m_error; }
   int               LatencyMs(void) const                    { return m_latencyMs; }
   int               HttpCode(void) const                     { return m_httpCode; }
   string            LastRef(void) const                      { return m_lastRef; }
   ENUM_JEVGATE_MODE Mode(void) const                         { return m_mode; }
   string            Profile(void) const                      { return m_profile; }

   //--- calibration support
   void              LogOutcome(const string ref,const string result,const double value = 0.0);

   //--- diagnostics
   void              PrintStats(void) const;

   //--- used by the JevGateScorer script (scores recorded snapshots outside the tester)
   bool              InitScorer(const string profile,const int timeoutMs = 10000);
   int               ScoreRecordedRow(const string symbol,const string tfStr,const string tag,
                                      const string featuresTsv,string &flatReply);
  };

//+------------------------------------------------------------------+
CJevGate::CJevGate(void) : m_profile(""), m_endpoint(JEVGATE_ENDPOINT), m_model(JEVGATE_MODEL),
   m_apiKey(""), m_includeSymbol(true), m_ctxJson(""),
   m_mode(JEVGATE_OFF), m_timeoutMs(3000), m_inited(false),
   m_tester(false), m_optimizing(false), m_verbose(false),
   m_qJson(""),
   m_breakerFails(3), m_breakerCoolSecs(300), m_consecFails(0),
   m_breakerUntilMs(0), m_warnedNotAllowed(false),
   m_begun(false), m_tag(""), m_symbol(""), m_tf(PERIOD_CURRENT), m_barTime(0),
   m_status(JG_NONE), m_lastRef(""), m_lastModel(""), m_error(""), m_latencyMs(0), m_httpCode(0),
   m_cacheRef(""), m_cacheResp(""),
   m_hSnap(INVALID_HANDLE), m_hDec(INVALID_HANDLE), m_hOut(INVALID_HANDLE),
   m_nEval(0), m_nCalls(0), m_nOk(0), m_nFail(0), m_nMiss(0),
   m_nRecorded(0), m_nCached(0), m_nLiveOk(0), m_latSum(0), m_tokIn(0), m_tokOut(0)
  {
  }

//+------------------------------------------------------------------+
//| Question definitions                                             |
//+------------------------------------------------------------------+
bool CJevGate::AddQuestion(const string key,const string body)
  {
   if(!IsSafeToken(key) || StringFind(key,".") >= 0)
     {
      PrintFormat("JevGate: invalid question key '%s' (letters, digits, _ -; no dots)",key);
      return false;
     }
   for(int i = 0; i < ArraySize(m_qKeys); i++)
      if(m_qKeys[i] == key)
        {
         m_qBodies[i] = body;   // redefine
         return true;
        }
   int n = ArraySize(m_qKeys);
   ArrayResize(m_qKeys,n + 1);
   ArrayResize(m_qBodies,n + 1);
   m_qKeys[n]   = key;
   m_qBodies[n] = body;
   return true;
  }

bool CJevGate::AddNoul(const string key,const string instructions,const string whenTrue,const string whenFalse)
  {
   string body = "{\"type\":\"noul\",\"instructions\":\"" + JevJsonEscape(instructions) + "\"";
   if(whenTrue != "" || whenFalse != "")
      body += ",\"criteria\":{\"true\":\"" + JevJsonEscape(whenTrue) + "\",\"false\":\"" + JevJsonEscape(whenFalse) + "\"}";
   body += "}";
   return AddQuestion(key,body);
  }

//--- options: "trending|ranging|chaotic" or "trending: Persistent move|ranging: Oscillating"
bool CJevGate::AddChoice(const string key,const string instructions,const string options)
  {
   string opts[];
   int n = StringSplit(options,'|',opts);
   if(n < 2 || n > 255)
     {
      PrintFormat("JevGate: choice '%s' needs 2-255 options separated by |",key);
      return false;
     }
   string crit = "";
   for(int i = 0; i < n; i++)
     {
      string name = Trim(opts[i]);
      string desc = name;
      int colon = StringFind(name,":");
      if(colon > 0)
        {
         desc = Trim(StringSubstr(name,colon + 1));
         name = Trim(StringSubstr(name,0,colon));
        }
      if(!IsSafeToken(name) || StringFind(name,".") >= 0)
        {
         PrintFormat("JevGate: choice '%s' option '%s' must use letters, digits, _ - only",key,name);
         return false;
        }
      if(i > 0)
         crit += ",";
      crit += "\"" + name + "\":\"" + JevJsonEscape(desc) + "\"";
     }
   return AddQuestion(key,"{\"type\":\"choice\",\"instructions\":\"" + JevJsonEscape(instructions) +
                      "\",\"criteria\":{" + crit + "}}");
  }

//--- levels, lowest first: "Poor|Marginal|Reasonable|Strong" -> score 0..3
bool CJevGate::AddScore(const string key,const string instructions,const string levels)
  {
   string lv[];
   int n = StringSplit(levels,'|',lv);
   if(n < 2 || n > 10)
     {
      PrintFormat("JevGate: score '%s' needs 2-10 levels separated by |",key);
      return false;
     }
   string crit = "";
   for(int i = 0; i < n; i++)
     {
      if(i > 0)
         crit += ",";
      crit += "\"" + JevJsonEscape(Trim(lv[i])) + "\"";
     }
   return AddQuestion(key,"{\"type\":\"score\",\"instructions\":\"" + JevJsonEscape(instructions) +
                      "\",\"criteria\":[" + crit + "]}");
  }

bool CJevGate::SetContext(const string key,const string text)
  {
   if(!IsSafeToken(key))
      return false;
   for(int i = 0; i < ArraySize(m_ctxKeys); i++)
      if(m_ctxKeys[i] == key)
        {
         m_ctxVals[i] = text;
         return true;
        }
   int n = ArraySize(m_ctxKeys);
   ArrayResize(m_ctxKeys,n + 1);
   ArrayResize(m_ctxVals,n + 1);
   m_ctxKeys[n] = key;
   m_ctxVals[n] = text;
   return true;
  }

string CJevGate::QuestionsJson(void) const
  {
   if(m_qJson != "")
      return m_qJson;
   string s = "{";
   for(int i = 0; i < ArraySize(m_qKeys); i++)
     {
      if(i > 0)
         s += ",";
      s += "\"" + m_qKeys[i] + "\":" + m_qBodies[i];
     }
   return s + "}";
  }

string CJevGate::ContextJson(void) const
  {
   if(m_ctxJson != "")
      return m_ctxJson;
   if(ArraySize(m_ctxKeys) == 0)
      return "";
   string s = "{";
   for(int i = 0; i < ArraySize(m_ctxKeys); i++)
     {
      if(i > 0)
         s += ",";
      s += "\"" + m_ctxKeys[i] + "\":\"" + JevJsonEscape(m_ctxVals[i]) + "\"";
     }
   return s + "}";
  }

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
bool CJevGate::Init(const string profile,const ENUM_JEVGATE_MODE mode,const int timeoutMs)
  {
   Deinit();
   if(!IsSafeToken(profile))
     {
      PrintFormat("JevGate: invalid profile name '%s' (use letters, digits, _ . -)",profile);
      return false;
     }
   m_profile    = profile;
   m_timeoutMs  = MathMax(100,timeoutMs);
   m_tester     = (MQLInfoInteger(MQL_TESTER) != 0);
   m_optimizing = (MQLInfoInteger(MQL_OPTIMIZATION) != 0);

   FolderCreate(JEVGATE_DIR,FILE_COMMON);

   //--- resolve mode
   m_mode = mode;
   if(m_mode == JEVGATE_AUTO)
     {
      if(!m_tester)
         m_mode = JEVGATE_LIVE;
      else
         m_mode = FileIsExist(Path("scores"),FILE_COMMON) ? JEVGATE_REPLAY : JEVGATE_RECORD;
     }
   if(m_tester && m_mode == JEVGATE_LIVE)
     {
      Print("JevGate: WebRequest is not available in the Strategy Tester; switching to RECORD mode");
      m_mode = JEVGATE_RECORD;
     }
   if(m_optimizing && m_mode == JEVGATE_RECORD)
     {
      Print("JevGate: recording is disabled during optimisation; switching to OFF");
      m_mode = JEVGATE_OFF;
     }

   //--- validate setup
   if((m_mode == JEVGATE_LIVE || m_mode == JEVGATE_RECORD) && ArraySize(m_qKeys) == 0)
     {
      Print("JevGate: no questions defined. Call AddNoul/AddChoice/AddScore before Init()");
      return false;
     }
   if(m_mode == JEVGATE_LIVE && !LoadApiKey())
      return false;

   //--- prepare files
   if(m_mode == JEVGATE_REPLAY && !LoadReplay())
      return false;
   if(m_mode == JEVGATE_RECORD)
     {
      if(!WriteQuestionsFile())
         return false;
      m_hSnap = OpenTruncate(Path("snapshots"),"ref\tprofile\tsymbol\ttimeframe\tbar_time\ttag\tfeatures");
     }
   if(m_mode == JEVGATE_LIVE)
      m_hDec = OpenAppend(LivePath("decisions"),"time\tref\tmode\tstatus\tlatency_ms\tfeatures\tresponse");
   if(m_mode != JEVGATE_OFF && !m_optimizing)
     {
      string outPath = m_tester ? Path("outcomes_tester") : LivePath("outcomes");
      m_hOut = m_tester ? OpenTruncate(outPath,"time\tref\tresult\tvalue")
                        : OpenAppend(outPath,"time\tref\tresult\tvalue");
     }

   m_inited = true;
   PrintFormat("JevGate %s: profile=%s mode=%s questions=%d%s",JEVGATE_VERSION,m_profile,
               ModeToString(m_mode),ArraySize(m_qKeys),
               (m_mode == JEVGATE_LIVE ? " model=" + m_model : ""));
   return true;
  }

void CJevGate::Deinit(void)
  {
   if(m_hSnap != INVALID_HANDLE) { FileClose(m_hSnap); m_hSnap = INVALID_HANDLE; }
   if(m_hDec  != INVALID_HANDLE) { FileClose(m_hDec);  m_hDec  = INVALID_HANDLE; }
   if(m_hOut  != INVALID_HANDLE) { FileClose(m_hOut);  m_hOut  = INVALID_HANDLE; }
   m_replay.Clear();
   m_inited = false;
  }

bool CJevGate::LoadApiKey(void)
  {
   if(m_apiKey != "")
      return true;
   int h = FileOpen(JEVGATE_KEYFILE,FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h != INVALID_HANDLE)
     {
      m_apiKey = Trim(FileReadString(h));
      FileClose(h);
     }
   if(m_apiKey == "")
     {
      PrintFormat("JevGate: no API key. Put it in <Common>\\Files\\%s (one line) or call SetApiKey() before Init()",JEVGATE_KEYFILE);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Snapshot building                                                |
//+------------------------------------------------------------------+
void CJevGate::Begin(const string tag,const datetime barTime,const string symbol,const ENUM_TIMEFRAMES tf)
  {
   m_tag     = Clean(tag);
   m_symbol  = (symbol == "") ? _Symbol : symbol;
   m_tf      = (tf == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : tf;
   m_barTime = (barTime != 0) ? barTime : iTime(m_symbol,m_tf,0);
   ArrayResize(m_fKeys,0);
   ArrayResize(m_fVals,0);
   ArrayResize(m_fIsText,0);
   m_begun = true;
  }

int CJevGate::FindFeature(const string key) const
  {
   for(int i = 0; i < ArraySize(m_fKeys); i++)
      if(m_fKeys[i] == key)
         return i;
   return -1;
  }

bool CJevGate::Add(const string key,const double value)
  {
   if(!m_begun || !IsSafeToken(key))
     {
      PrintFormat("JevGate: Add('%s') ignored (call Begin() first; keys use letters, digits, _ . -)",key);
      return false;
     }
   int i = FindFeature(key);
   if(i < 0)
     {
      i = ArraySize(m_fKeys);
      ArrayResize(m_fKeys,i + 1);
      ArrayResize(m_fVals,i + 1);
      ArrayResize(m_fIsText,i + 1);
      m_fKeys[i] = key;
     }
   m_fVals[i]   = MathIsValidNumber(value) ? FormatNum(value) : "nan";
   m_fIsText[i] = false;
   return true;
  }

bool CJevGate::AddText(const string key,const string value)
  {
   if(!m_begun || !IsSafeToken(key))
     {
      PrintFormat("JevGate: AddText('%s') ignored (call Begin() first; keys use letters, digits, _ . -)",key);
      return false;
     }
   int i = FindFeature(key);
   if(i < 0)
     {
      i = ArraySize(m_fKeys);
      ArrayResize(m_fKeys,i + 1);
      ArrayResize(m_fVals,i + 1);
      ArrayResize(m_fIsText,i + 1);
      m_fKeys[i] = key;
     }
   m_fVals[i]   = Clean(value);
   m_fIsText[i] = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Evaluate                                                         |
//+------------------------------------------------------------------+
bool CJevGate::Evaluate(void)
  {
   ClearAnswers();
   if(!m_inited || !m_begun)
     {
      m_status = JG_BAD_USAGE;
      m_error  = "call Init() and Begin() before Evaluate()";
      return false;
     }
   m_nEval++;
   m_lastRef = BuildRef();
   string feats = FeaturesTsv();

   switch(m_mode)
     {
      case JEVGATE_OFF:
         m_status = JG_OFF;
         return false;

      case JEVGATE_RECORD:
         if(m_lastRef != m_cacheRef)
           {
            WriteLine(m_hSnap,m_lastRef + "\t" + m_profile + "\t" + m_symbol + "\t" + TfToString(m_tf) + "\t" +
                      IntegerToString((long)m_barTime) + "\t" + m_tag + "\t" + feats);
            m_cacheRef = m_lastRef;
            m_nRecorded++;
           }
         m_status = JG_RECORDED;
         return false;

      case JEVGATE_REPLAY:
        {
         string resp;
         if(!m_replay.TryGetValue(m_lastRef,resp))
           {
            m_nMiss++;
            m_status = JG_REPLAY_MISS;
            return false;
           }
         return ApplyResponse(resp);
        }

      case JEVGATE_LIVE:
         return EvaluateLive(feats);

      default:
         break;
     }
   m_status = JG_BAD_USAGE;
   return false;
  }

bool CJevGate::EvaluateLive(const string feats)
  {
   //--- same snapshot evaluated again on this bar: reuse the answer
   if(m_lastRef == m_cacheRef && m_cacheResp != "")
     {
      m_nCached++;
      return ApplyResponse(m_cacheResp);
     }

   ulong now = GetTickCount64();
   if(m_breakerUntilMs > now)
     {
      m_status = JG_BREAKER_OPEN;
      m_error  = StringFormat("circuit breaker open for %d more s",(int)((m_breakerUntilMs - now) / 1000));
      return false;
     }

   string state = StateJson(m_symbol,TfToString(m_tf),m_tag,m_fKeys,m_fVals,m_fIsText);
   string flat;
   int code = CallApi(state,flat);

   if(code == -1)
     {
      RegisterFailure();
      LogDecision(feats,flat);
      return false;
     }

   bool ok = ApplyResponse(flat);
   if(code != 200 && ok)   // defensive: never accept answers from an error response
      ok = false;
   if(ok)
     {
      m_consecFails = 0;
      m_cacheRef    = m_lastRef;
      m_cacheResp   = flat;
      m_latSum     += m_latencyMs;
      m_nLiveOk++;
     }
   else
     {
      if(m_status == JG_OK || m_status == JG_NONE)
         m_status = JG_API_ERROR;
      RegisterFailure();
     }
   LogDecision(feats,flat);
   return ok;
  }

//+------------------------------------------------------------------+
//| HTTP call to the System One API.                                 |
//| Returns the HTTP status (-1 = WebRequest failed). Always fills   |
//| `flat` with "ok=1;..." answers or "ok=0;error=...".              |
//+------------------------------------------------------------------+
int CJevGate::CallApi(const string stateJson,string &flat)
  {
   string body = "{\"model\":\"" + JevJsonEscape(m_model) + "\",\"state\":" + stateJson +
                 ",\"questions\":" + QuestionsJson() + "}";
   char data[];
   int n = StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);
   if(n > 0)
      ArrayResize(data,n - 1);   // drop trailing NUL

   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + m_apiKey + "\r\n";
   char   result[];
   string resultHeaders;
   ResetLastError();
   ulong t0 = GetTickCount64();
   int code = WebRequest("POST",m_endpoint,headers,m_timeoutMs,data,result,resultHeaders);
   m_latencyMs = (int)(GetTickCount64() - t0);
   m_httpCode  = code;
   m_nCalls++;

   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
        {
         m_status = JG_NOT_ALLOWED;
         if(!m_warnedNotAllowed)
           {
            Print("JevGate: WebRequest blocked. Add https://api.typesafe.ai to Tools > Options > Expert Advisors > 'Allow WebRequest for listed URL'");
            m_warnedNotAllowed = true;
           }
        }
      else
         m_status = JG_HTTP_ERROR;
      m_error = StringFormat("WebRequest failed, error %d",err);
      flat    = "ok=0;error=" + Clean(m_error);
      return -1;
     }

   string resp = CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   if(code != 200)
     {
      m_status = JG_API_ERROR;
      m_error  = ApiErrorText(code,resp);
      flat     = "ok=0;error=" + Clean(m_error);
      return code;
     }
   if(!ResponseToFlat(resp,flat))
      m_status = JG_PARSE_ERROR;
   return code;
  }

//--- Convert a System One JSON response into the flat key=value form
bool CJevGate::ResponseToFlat(const string body,string &flat)
  {
   CJevJsonParser parser;
   CJevJson *root = parser.Parse(body);
   if(root == NULL)
     {
      flat = "ok=0;error=" + Clean("bad JSON: " + parser.Error());
      return false;
     }
   CJevJson *answers = root.Get("answers");
   if(answers == NULL || !answers.IsObject())
     {
      delete root;
      flat = "ok=0;error=response has no answers";
      return false;
     }

   string out = "ok=1";
   CJevJson *m = root.Get("model");
   if(m != NULL)
      out += ";model=" + Clean(m.AsString());

   for(int i = 0; i < answers.Size(); i++)
     {
      string key = Clean(answers.KeyAt(i));
      CJevJson *a = answers.At(i);
      if(a == NULL || !a.IsObject())
         continue;
      CJevJson *t    = a.Get("type");
      string    kind = (t != NULL) ? t.AsString() : "";
      CJevJson *conf = a.Get("confidence");
      CJevJson *prob = a.Get("probabilities");

      if(kind == "noul" || (kind == "" && a.Get("noul") != NULL))
        {
         CJevJson *v = a.Get("noul");
         if(v != NULL && v.IsNumber())
            out += ";" + key + "=" + FormatNum(v.num);
        }
      else if(kind == "score" || (kind == "" && a.Get("score") != NULL))
        {
         CJevJson *v = a.Get("score");
         if(v != NULL && v.IsNumber())
            out += ";" + key + "=" + FormatNum(v.num);
         if(prob != NULL && prob.IsObject())
            for(int j = 0; j < prob.Size(); j++)
               out += ";" + key + "." + Clean(prob.KeyAt(j)) + "=" + FormatNum(prob.At(j).AsNumber());
        }
      else if(kind == "choice" || (kind == "" && a.Get("choice") != NULL))
        {
         CJevJson *v = a.Get("choice");
         string label = (v != NULL) ? Clean(v.AsString()) : "";
         out += ";" + key + "=" + label;
         if(prob != NULL && prob.IsObject())
           {
            CJevJson *top = prob.Get(label);
            if(top != NULL)
               out += ";" + key + ".p=" + FormatNum(top.AsNumber());
            for(int j = 0; j < prob.Size(); j++)
               out += ";" + key + "." + Clean(prob.KeyAt(j)) + "=" + FormatNum(prob.At(j).AsNumber());
           }
        }
      else
         continue;

      if(conf != NULL && conf.IsNumber())
         out += ";" + key + ".conf=" + FormatNum(conf.num);
     }

   CJevJson *usage = root.Get("usage");
   if(usage != NULL && usage.IsObject())
     {
      CJevJson *ti = usage.Get("input_tokens");
      CJevJson *to = usage.Get("output_tokens");
      if(ti != NULL) out += ";tokens_in=" + IntegerToString((long)ti.AsNumber());
      if(to != NULL) out += ";tokens_out=" + IntegerToString((long)to.AsNumber());
     }
   delete root;
   flat = out;
   return true;
  }

//--- Best-effort human-readable error from an API error body
string CJevGate::ApiErrorText(const int code,const string body)
  {
   string label = "HTTP " + IntegerToString(code);
   if(code == 401) label += " unauthorized (check API key)";
   if(code == 422) label += " invalid request (check questions/state)";
   if(code == 429) label += " rate limited";
   if(code == 529) label += " API overloaded";
   string detail = "";
   CJevJsonParser parser;
   CJevJson *root = parser.Parse(body);
   if(root != NULL)
     {
      CJevJson *d = root.Get("detail");
      if(d == NULL) d = root.Get("message");
      if(d == NULL)
        {
         CJevJson *e = root.Get("error");
         if(e != NULL)
            d = e.IsObject() ? e.Get("message") : e;
        }
      if(d != NULL)
        {
         if(d.IsString())
            detail = d.str;
         else if(d.Size() > 0 && d.At(0) != NULL && d.At(0).IsObject() && d.At(0).Get("msg") != NULL)
            detail = d.At(0).Get("msg").AsString();
        }
      delete root;
     }
   if(detail == "")
      detail = StringSubstr(body,0,160);
   return label + ": " + detail;
  }

void CJevGate::RegisterFailure(void)
  {
   m_nFail++;
   m_consecFails++;
   if(m_breakerFails > 0 && m_consecFails >= m_breakerFails)
     {
      m_breakerUntilMs = GetTickCount64() + (ulong)MathMax(0,m_breakerCoolSecs) * 1000;
      m_consecFails    = 0;
      PrintFormat("JevGate: %d consecutive failures (%s); pausing calls for %d s",
                  m_breakerFails,m_error,m_breakerCoolSecs);
     }
   if(m_verbose)
      PrintFormat("JevGate: %s - %s",StatusText(),m_error);
  }

//+------------------------------------------------------------------+
//| Flat answers: ok=1;model=x;key=value;key.sub=value               |
//+------------------------------------------------------------------+
void CJevGate::ClearAnswers(void)
  {
   ArrayResize(m_aKeys,0);
   ArrayResize(m_aVals,0);
   m_lastModel = "";
   m_error     = "";
   m_latencyMs = 0;
   m_httpCode  = 0;
   m_status    = JG_NONE;
  }

bool CJevGate::ApplyResponse(const string resp)
  {
   string parts[];
   int n = StringSplit(Trim(resp),';',parts);
   string okVal = "";
   string err   = "";
   ArrayResize(m_aKeys,0);
   ArrayResize(m_aVals,0);
   for(int i = 0; i < n; i++)
     {
      int eq = StringFind(parts[i],"=");
      if(eq <= 0)
         continue;
      string k = Trim(StringSubstr(parts[i],0,eq));
      string v = StringSubstr(parts[i],eq + 1);
      if(k == "ok")         { okVal = v; continue; }
      if(k == "model")      { m_lastModel = v; continue; }
      if(k == "error")      { err = v; continue; }
      if(k == "tokens_in")  { m_tokIn  += StringToInteger(v); continue; }
      if(k == "tokens_out") { m_tokOut += StringToInteger(v); continue; }
      int j = ArraySize(m_aKeys);
      ArrayResize(m_aKeys,j + 1);
      ArrayResize(m_aVals,j + 1);
      m_aKeys[j] = k;
      m_aVals[j] = v;
     }
   if(okVal != "1")
     {
      if(m_status == JG_NONE || m_status == JG_OK)
         m_status = (okVal == "") ? JG_PARSE_ERROR : JG_API_ERROR;
      if(m_error == "")
         m_error = (err != "") ? err : "unparseable answer: " + StringSubstr(resp,0,120);
      ArrayResize(m_aKeys,0);
      ArrayResize(m_aVals,0);
      return false;
     }
   m_status = JG_OK;
   m_nOk++;
   return true;
  }

bool CJevGate::Has(const string key) const
  {
   for(int i = 0; i < ArraySize(m_aKeys); i++)
      if(m_aKeys[i] == key)
         return true;
   return false;
  }

double CJevGate::Get(const string key,const double dflt) const
  {
   for(int i = 0; i < ArraySize(m_aKeys); i++)
      if(m_aKeys[i] == key)
         return StringToDouble(m_aVals[i]);
   return dflt;
  }

string CJevGate::GetLabel(const string key,const string dflt) const
  {
   for(int i = 0; i < ArraySize(m_aKeys); i++)
      if(m_aKeys[i] == key)
         return m_aVals[i];
   return dflt;
  }

//+------------------------------------------------------------------+
//| State JSON (identical for live calls and the scorer script)      |
//+------------------------------------------------------------------+
string CJevGate::StateJson(const string symbol,const string tfStr,const string tag,
                           const string &keys[],const string &vals[],const bool &isText[]) const
  {
   string s = "{";
   if(m_includeSymbol)
      s += "\"symbol\":\"" + JevJsonEscape(symbol) + "\",";
   s += "\"timeframe\":\"" + tfStr + "\"";
   if(tag != "")
      s += ",\"tag\":\"" + JevJsonEscape(tag) + "\"";
   s += ",\"features\":{";
   for(int i = 0; i < ArraySize(keys); i++)
     {
      if(i > 0)
         s += ",";
      s += "\"" + keys[i] + "\":";
      if(isText[i])
         s += "\"" + JevJsonEscape(vals[i]) + "\"";
      else
         s += (vals[i] == "nan" ? "null" : vals[i]);
     }
   s += "}";
   string ctx = ContextJson();
   if(ctx != "")
      s += ",\"context\":" + ctx;
   return s + "}";
  }

//+------------------------------------------------------------------+
//| Record / replay support                                          |
//+------------------------------------------------------------------+
bool CJevGate::WriteQuestionsFile(void)
  {
   int h = FileOpen(QuestionsPath(),FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("JevGate: cannot write %s (error %d)",QuestionsPath(),GetLastError());
      return false;
     }
   FileWriteString(h,"version\t" + JEVGATE_VERSION + "\r\n");
   FileWriteString(h,"model\t" + m_model + "\r\n");
   FileWriteString(h,"include_symbol\t" + (m_includeSymbol ? "1" : "0") + "\r\n");
   FileWriteString(h,"context\t" + ContextJson() + "\r\n");
   FileWriteString(h,"questions\t" + QuestionsJson() + "\r\n");
   FileClose(h);
   return true;
  }

bool CJevGate::LoadQuestionsFile(void)
  {
   int h = FileOpen(QuestionsPath(),FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("JevGate: cannot open <Common>\\Files\\%s. Run a RECORD backtest first.",QuestionsPath());
      return false;
     }
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringReplace(line,"\r","");
      int tab = StringFind(line,"\t");
      if(tab <= 0)
         continue;
      string k = StringSubstr(line,0,tab);
      string v = StringSubstr(line,tab + 1);
      if(k == "model" && m_model == JEVGATE_MODEL) m_model = v;   // SetModel() overrides the file
      if(k == "include_symbol")                    m_includeSymbol = (v == "1");
      if(k == "context")                           m_ctxJson = v;
      if(k == "questions")                         m_qJson = v;
     }
   FileClose(h);
   if(m_qJson == "" || m_qJson == "{}")
     {
      Print("JevGate: questions file has no questions");
      return false;
     }
   return true;
  }

bool CJevGate::LoadReplay(void)
  {
   string path = Path("scores");
   int h = FileOpen(path,FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("JevGate: cannot open replay file <Common>\\Files\\%s (error %d)",path,GetLastError());
      return false;
     }
   int loaded = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringReplace(line,"\r","");
      if(line == "" || StringFind(line,"ref\t") == 0)
         continue;
      int tab = StringFind(line,"\t");
      if(tab <= 0)
         continue;
      string ref  = StringSubstr(line,0,tab);
      string resp = StringSubstr(line,tab + 1);
      if(!m_replay.Add(ref,resp))
         m_replay.TrySetValue(ref,resp);
      loaded++;
     }
   FileClose(h);
   PrintFormat("JevGate: loaded %d scored snapshots from %s",loaded,path);
   return true;
  }

//--- scorer: run from a script on a live chart, where WebRequest is allowed
bool CJevGate::InitScorer(const string profile,const int timeoutMs)
  {
   Deinit();
   if(!IsSafeToken(profile))
     {
      PrintFormat("JevGate: invalid profile name '%s'",profile);
      return false;
     }
   if(MQLInfoInteger(MQL_TESTER) != 0)
     {
      Print("JevGate: the scorer cannot run in the Strategy Tester");
      return false;
     }
   m_profile   = profile;
   m_timeoutMs = MathMax(100,timeoutMs);
   m_mode      = JEVGATE_LIVE;
   if(!LoadQuestionsFile() || !LoadApiKey())
      return false;
   m_inited = true;
   return true;
  }

int CJevGate::ScoreRecordedRow(const string symbol,const string tfStr,const string tag,
                               const string featuresTsv,string &flatReply)
  {
   if(!m_inited)
     {
      flatReply = "ok=0;error=scorer not initialised";
      return -1;
     }
   string keys[], vals[], parts[];
   bool   isText[];
   int n = StringSplit(featuresTsv,';',parts);
   for(int i = 0; i < n; i++)
     {
      int eq = StringFind(parts[i],"=");
      if(eq <= 0)
         continue;
      int j = ArraySize(keys);
      ArrayResize(keys,j + 1);
      ArrayResize(vals,j + 1);
      ArrayResize(isText,j + 1);
      keys[j]   = StringSubstr(parts[i],0,eq);
      vals[j]   = StringSubstr(parts[i],eq + 1);
      isText[j] = !(vals[j] == "nan" || LooksNumeric(vals[j]));
     }
   ClearAnswers();
   return CallApi(StateJson(symbol,tfStr,tag,keys,vals,isText),flatReply);
  }

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void CJevGate::LogDecision(const string feats,const string resp)
  {
   if(m_hDec == INVALID_HANDLE)
      return;
   string r = resp;
   StringReplace(r,"\t"," ");
   StringReplace(r,"\r"," ");
   StringReplace(r,"\n"," ");
   WriteLine(m_hDec,TimeToString(TimeCurrent(),TIME_DATE | TIME_SECONDS) + "\t" + m_lastRef + "\t" +
             ModeToString(m_mode) + "\t" + StatusText() + "\t" + IntegerToString(m_latencyMs) + "\t" +
             feats + "\t" + r);
  }

void CJevGate::LogOutcome(const string ref,const string result,const double value)
  {
   if(m_hOut == INVALID_HANDLE || ref == "")
      return;
   WriteLine(m_hOut,TimeToString(TimeCurrent(),TIME_DATE | TIME_SECONDS) + "\t" + ref + "\t" +
             Clean(result) + "\t" + FormatNum(value));
  }

void CJevGate::PrintStats(void) const
  {
   double avgLat = (m_nLiveOk > 0) ? (double)m_latSum / m_nLiveOk : 0.0;
   PrintFormat("JevGate stats [%s/%s]: evaluations=%d ok=%d failures=%d api_calls=%d cached=%d recorded=%d replay_misses=%d avg_latency=%.0f ms tokens_in=%I64d tokens_out=%I64d",
               m_profile,ModeToString(m_mode),m_nEval,m_nOk,m_nFail,m_nCalls,m_nCached,m_nRecorded,m_nMiss,
               avgLat,m_tokIn,m_tokOut);
   if(m_mode == JEVGATE_RECORD && m_nRecorded > 0)
      PrintFormat("JevGate: %d snapshots written to <Common>\\Files\\%s. Run the JevGateScorer script (profile=%s) on any chart, then rerun the test.",
                  m_nRecorded,Path("snapshots"),m_profile);
   if(m_mode == JEVGATE_REPLAY && m_nMiss > 0)
      PrintFormat("JevGate: %d snapshots had no stored answer (usually new signals caused by the gate itself). Those used your fallback rule.",m_nMiss);
  }

string CJevGate::StatusText(void) const
  {
   switch(m_status)
     {
      case JG_NONE:         return "none";
      case JG_OK:           return "ok";
      case JG_OFF:          return "off";
      case JG_RECORDED:     return "recorded";
      case JG_REPLAY_MISS:  return "replay_miss";
      case JG_BREAKER_OPEN: return "breaker_open";
      case JG_NOT_ALLOWED:  return "not_allowed";
      case JG_HTTP_ERROR:   return "http_error";
      case JG_API_ERROR:    return "api_error";
      case JG_PARSE_ERROR:  return "parse_error";
      case JG_BAD_USAGE:    return "bad_usage";
     }
   return "unknown";
  }

//+------------------------------------------------------------------+
//| Formatting helpers                                               |
//+------------------------------------------------------------------+
//--- live logs are per chart (profile + symbol + timeframe)
string CJevGate::LivePath(const string kind) const
  {
   string sym = _Symbol;
   string bad[] = {"\\","/",":","*","?","\"","<",">","|"," "};
   for(int i = 0; i < ArraySize(bad); i++)
      StringReplace(sym,bad[i],"_");
   return JEVGATE_DIR + "\\" + kind + "_" + m_profile + "_" + sym + "_" + TfToString((ENUM_TIMEFRAMES)_Period) + ".tsv";
  }

string CJevGate::BuildRef(void) const
  {
   return m_profile + "|" + m_symbol + "|" + TfToString(m_tf) + "|" +
          IntegerToString((long)m_barTime) + "|" + m_tag;
  }

string CJevGate::FeaturesTsv(void) const
  {
   string s = "";
   for(int i = 0; i < ArraySize(m_fKeys); i++)
     {
      if(i > 0)
         s += ";";
      s += m_fKeys[i] + "=" + m_fVals[i];
     }
   return s;
  }

bool CJevGate::IsSafeToken(const string s)
  {
   int n = StringLen(s);
   if(n == 0 || n > 64)
      return false;
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s,i);
      bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                c == '_' || c == '.' || c == '-';
      if(!ok)
         return false;
     }
   return true;
  }

bool CJevGate::LooksNumeric(const string s)
  {
   int n = StringLen(s);
   if(n == 0)
      return false;
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

//--- strip characters that would break the flat or file formats
string CJevGate::Clean(const string s)
  {
   string r = s;
   StringReplace(r,";","_");
   StringReplace(r,"=","_");
   StringReplace(r,"|","_");
   StringReplace(r,"\t","_");
   StringReplace(r,"\r","_");
   StringReplace(r,"\n","_");
   StringReplace(r,"\"","_");
   StringReplace(r,"\\","_");
   return r;
  }

string CJevGate::Trim(const string s)
  {
   string r = s;
   if(StringLen(r) > 0 && StringGetCharacter(r,0) == 0xFEFF)          // BOM read as Unicode
      r = StringSubstr(r,1);
   if(StringLen(r) >= 3 && StringGetCharacter(r,0) == 0xEF &&
      StringGetCharacter(r,1) == 0xBB && StringGetCharacter(r,2) == 0xBF)  // UTF-8 BOM read as ANSI
      r = StringSubstr(r,3);
   StringTrimLeft(r);
   StringTrimRight(r);
   return r;
  }

//--- compact number: fewer tokens sent to the model
string CJevGate::FormatNum(const double v)
  {
   string s = DoubleToString(v,8);
   if(StringFind(s,".") >= 0)
     {
      int n = StringLen(s);
      while(n > 0 && StringGetCharacter(s,n - 1) == '0')
         n--;
      if(n > 0 && StringGetCharacter(s,n - 1) == '.')
         n--;
      s = StringSubstr(s,0,n);
     }
   if(s == "-0" || s == "")
      s = "0";
   return s;
  }

string CJevGate::TfToString(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   StringReplace(s,"PERIOD_","");
   return s;
  }

string CJevGate::ModeToString(const ENUM_JEVGATE_MODE m)
  {
   switch(m)
     {
      case JEVGATE_AUTO:   return "AUTO";
      case JEVGATE_LIVE:   return "LIVE";
      case JEVGATE_RECORD: return "RECORD";
      case JEVGATE_REPLAY: return "REPLAY";
      case JEVGATE_OFF:    return "OFF";
     }
   return "?";
  }

//+------------------------------------------------------------------+
//| File helpers (ANSI text in the terminals' Common\Files folder)   |
//+------------------------------------------------------------------+
int CJevGate::OpenAppend(const string path,const string header)
  {
   int h = FileOpen(path,FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("JevGate: cannot open %s (error %d)",path,GetLastError());
      return INVALID_HANDLE;
     }
   if(FileSize(h) == 0)
      FileWriteString(h,header + "\r\n");
   FileSeek(h,0,SEEK_END);
   return h;
  }

int CJevGate::OpenTruncate(const string path,const string header)
  {
   int h = FileOpen(path,FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("JevGate: cannot create %s (error %d)",path,GetLastError());
      return INVALID_HANDLE;
     }
   FileWriteString(h,header + "\r\n");
   return h;
  }

void CJevGate::WriteLine(const int h,const string line)
  {
   if(h == INVALID_HANDLE)
      return;
   FileWriteString(h,line + "\r\n");
   FileFlush(h);
  }

#endif // JEVGATE_MQH
//+------------------------------------------------------------------+
