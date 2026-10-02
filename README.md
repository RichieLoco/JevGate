# JevGate

**A drop-in judgment gate for MetaTrader 5 Expert Advisors, in pure MQL5.**

JevGate lets any MQL5 EA ask [TypeSafe Jev](https://typesafe.ai) narrow, typed questions about the current market state. Examples: *"Will price trend against this entry?"*, *"Which regime is this?"*, *"How good is this setup, 0 to 3?"*. You get typed answers back (probabilities, labels and scores) and use them in your own rules.

It calls the TypeSafe System One API directly with `WebRequest` and parses the JSON response in MQL5. There's no proxy, no DLL and no Python: everything, including backtesting and calibration, runs inside MetaTrader 5.

> **JevGate never trades.** It doesn't place, modify or close orders. It answers questions, and your EA decides what to do with the answers. The recommended use is as a **veto**: it can only *remove* trades your strategy already wanted to take.

> Not affiliated with TypeSafe or MetaQuotes. Nothing here is financial advice. A judgment model cannot turn a losing strategy into a winning one.

---

## Contents

- [How it works](#how-it-works)
- [What JevGate provides vs. what you provide](#what-jevgate-provides-vs-what-you-provide)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Using JevGate in your EA](#using-jevgate-in-your-ea)
- [Defining questions](#defining-questions)
- [Answer keys](#answer-keys)
- [Modes and backtesting](#modes-and-backtesting)
- [Calibration](#calibration)
- [Failure handling](#failure-handling)
- [Files JevGate uses](#files-jevgate-uses)
- [Security](#security)
- [Limitations and FAQ](#limitations-and-faq)

---

## How it works

```
 Your EA (MQL5)                                           TypeSafe API
┌───────────────────────────────────────────┐          ┌──────────────────────┐
│ OnInit: AddNoul / AddChoice / AddScore    │          │ POST /v1/systemone   │
│                                           │  HTTPS   │                      │
│ Signal: jev.Begin / Add(features)         │ ───────▶ │ Jev evaluates every  │
│         jev.Evaluate()  ── JSON request   │          │ question in parallel │
│         jev.Get(...)    ◀─ JSON parsed ── │ ◀─────── │                      │
│         YOUR rule decides                 │          └──────────────────────┘
└───────────────────────────────────────────┘
```

**Your code computes the state. Jev judges it. Your code applies the policy. Your EA executes.**

---

## What JevGate provides vs. what you provide

### JevGate provides

| Component | What it does |
|---|---|
| `JevGate.mqh` | The `CJevGate` class. It defines questions, collects named features, builds the API request, calls `https://api.typesafe.ai/v1/systemone`, parses the JSON answers, and exposes them through `Get()` / `GetLabel()` |
| `JevJson.mqh` | A small, dependency-free JSON parser written in MQL5 (used internally, also reusable) |
| Modes | **LIVE** (API calls), **RECORD** and **REPLAY** (so you can backtest in the Strategy Tester, which can't make web requests), **OFF**, and **AUTO** to pick one for you |
| Safety | Request timeout, a circuit breaker (pauses calls after repeated failures), one call per bar per snapshot (cached), and status codes for every failure. API errors (401, 422, 429, 529) come back as readable messages |
| Logging | A decisions log (live), a snapshots log (record), an outcomes log (`LogOutcome`) for calibration, and token-usage totals |
| `JevGateScorer.mq5` | A script that scores recorded backtest snapshots through the API so they can be replayed. It retries with back-off and picks up where it left off if re-run |
| `JevGateExample.mq5` | A complete worked example EA |
| `JevGateCalibrate.mq5` | A script that checks how well the answers match your logged outcomes, and shows what a veto at each threshold would have removed |

### You provide

| You supply | Where | Notes |
|---|---|---|
| **A TypeSafe API key** | `<Common>/Files/JevGate/api_key.txt` (one line), or `SetApiKey()` | Kept out of EA inputs and `.set` files by default |
| **Terminal permission** | MT5 → Tools → Options → Expert Advisors | Tick *Allow WebRequest for listed URL* and add `https://api.typesafe.ai` |
| **The questions** | Your EA's `OnInit`: `AddNoul` / `AddChoice` / `AddScore` | Atomic and specific. Ask "Will price keep trending against a short over the next 20 bars?", not "Should I sell?" |
| **The features** | Your EA: `jev.Add("name", value)` | Numbers your EA already computes: indicator values, distances in ATR units, slopes, volatility ratios, exposure. Keep them compact (you pay per input token) and **only use closed-bar data** |
| **The decision rule and thresholds** | Your EA | For example `if(jev.Get("trend_against") > 0.65) skip;`. Thresholds are yours, tuned per action to what being wrong costs |
| **A fallback** | Your EA | What to do with no answer (outage, timeout, replay miss). Usually: behave exactly as the EA would without JevGate |
| **Where to gate** | Your EA | Usually only the *start* of a position or sequence. Never risk exits, stops or (for DCA/grid EAs) additions to an open sequence |
| **Outcome labels** | Your EA: `jev.LogOutcome(ref, "loss", pnl)` | How each gated decision turned out. You need these to calibrate thresholds |
| **Validation** | You | Out-of-sample and forward testing. Vendor accuracy numbers say nothing about your strategy |

---

## Repository layout

```
JevGate/
├── mql5/
│   ├── Include/JevGate/
│   │   ├── JevGate.mqh          # the module
│   │   └── JevJson.mqh          # JSON parser used by the module
│   ├── Experts/JevGateExample.mq5
│   └── Scripts/
│       ├── JevGateScorer.mq5    # scores recorded snapshots for backtest replay
│       └── JevGateCalibrate.mq5 # calibration + veto-threshold report
├── LICENSE
└── README.md
```

---

## Quick start

1. **Copy the files** into your MT5 data folder (File → Open Data Folder):
   - `mql5/Include/JevGate/` → `MQL5/Include/JevGate/`
   - `mql5/Experts/JevGateExample.mq5` → `MQL5/Experts/`
   - `mql5/Scripts/JevGateScorer.mq5` and `JevGateCalibrate.mq5` → `MQL5/Scripts/`
2. **Add your API key.** Create `api_key.txt` containing only the key, saved as plain text (ANSI or UTF-8, *not* "Unicode"), in the **common** data folder: `%APPDATA%\MetaQuotes\Terminal\Common\Files\JevGate\api_key.txt`.
3. **Allow the URL.** Tools → Options → Expert Advisors → tick *Allow WebRequest for listed URL* → add `https://api.typesafe.ai`.
4. **Compile** `JevGateExample.mq5`, `JevGateScorer.mq5` and `JevGateCalibrate.mq5` in MetaEditor.
5. **Attach** the example EA to a demo chart with `InpUseJudgment = true`. The Experts tab should show:
   ```
   JevGate 2.0.0: profile=example_entry mode=LIVE questions=3 model=jev-latest
   ```
   When the EA evaluates a signal, a line appears in `Common/Files/JevGate/decisions_example_entry_<symbol>_<tf>.tsv` containing the answers or the error.

---

## Using JevGate in your EA

Set up once in `OnInit`. Then, whenever your own entry rules say "yes": **describe → ask → decide**.

```cpp
#include <JevGate\JevGate.mqh>

input bool              InpUseJudgment = false;          // off = EA behaves exactly as before
input ENUM_JEVGATE_MODE InpJevMode     = JEVGATE_AUTO;
input string            InpModel       = "jev-latest";   // pin a version once you've calibrated

CJevGate jev;

int OnInit()
  {
   if(InpUseJudgment)
     {
      jev.SetModel(InpModel);
      jev.SetContext("strategy","Mean-reversion DCA from band extremes.");

      jev.AddNoul  ("trend_persists_against",
                    "Will price keep trending against the entry direction (dir) for the next 20 bars without a meaningful pullback?");
      jev.AddChoice("regime","Which regime is this market in?",
                    "ranging: Oscillating around a stable mean|trending: Persistent directional move|"
                    "breakout: Leaving a range with momentum|high_vol: Volatility well above normal");
      jev.AddScore ("reversion_quality","How likely is mean reversion from this extreme within 20 bars?",
                    "Unlikely|Weak|Reasonable|Strong");

      if(!jev.Init("dca_start",InpJevMode,3000))
         return INIT_FAILED;
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { if(InpUseJudgment) jev.PrintStats(); }

// Called only after your own entry rules have said "yes"
bool AllowNewSequence(const int dir)
  {
   if(!InpUseJudgment) return true;

   // 1. describe: closed-bar numbers your EA already has
   jev.Begin(dir > 0 ? "buy" : "sell");
   jev.Add("dir",          dir);
   jev.Add("qqe",          qqeValue);
   jev.Add("bb_dist_atr",  bbDistance / atr);
   jev.Add("h4_slope_atr", h4Slope / atr);
   jev.Add("atr_ratio",    atr / atrAverage);

   // 2. ask
   if(!jev.Evaluate())
      return true;                                   // fallback: no answer -> unchanged behaviour

   // 3. decide: thresholds are yours
   if(jev.Get("trend_persists_against") > 0.65)  return false;
   if(jev.GetLabel("regime") == "breakout" && jev.Get("regime.p") > 0.6) return false;
   if(jev.Get("reversion_quality") < 1.0)        return false;
   return true;
  }
```

To log outcomes for calibration, store `jev.LastRef()` when you open the position or sequence, and report back when it ends:

```cpp
string ref = jev.LastRef();                         // at entry
...
jev.LogOutcome(ref, pnl > 0 ? "win" : "loss", pnl); // at exit (any result labels you like)
```

### API reference

**Configure (before `Init`)**

| Method | Description |
|---|---|
| `SetApiKey(key)` | Use this key instead of reading `api_key.txt` |
| `SetModel(model)` | Default `jev-latest`. Pin a version (as reported by `Model()`) once your thresholds are calibrated |
| `SetContext(key, text)` | Static facts added to every state, e.g. a one-line strategy description. Keep it short |
| `SetIncludeSymbol(bool)` | Send the symbol name to the model (default true) |
| `SetCircuitBreaker(maxFails=3, coolDownSecs=300)` | After N consecutive failures, skip calls for M seconds. `maxFails=0` disables it |
| `SetEndpoint(url)` | Override the API URL (default `https://api.typesafe.ai/v1/systemone`) |
| `SetVerbose(bool)` | Print every failure to the Experts log |

**Questions (before `Init`)**

| Method | Description |
|---|---|
| `AddNoul(key, instructions, whenTrue="", whenFalse="")` | Yes/no probability 0..1. The optional texts define what counts as yes and no |
| `AddChoice(key, instructions, "a: description\|b: description\|...")` | One label from 2–255 options, with a probability per option. Descriptions are optional (`"a\|b\|c"`) but improve answers |
| `AddScore(key, instructions, "lowest\|...\|highest")` | 2–10 ordered levels, lowest first. Returns a probability-weighted score from 0 to levels−1 |

**Run**

| Method | Description |
|---|---|
| `bool Init(profile, mode=JEVGATE_AUTO, timeoutMs=3000)` | `profile` names the log and replay files. Returns false on bad setup (no questions, no API key, missing replay file) |
| `Begin(tag="", barTime=0, symbol="", tf=PERIOD_CURRENT)` | Start a snapshot. `tag` tells snapshots on the same bar apart (e.g. `"buy"`) |
| `Add(key, double)` / `AddText(key, string)` | Add a feature. Keys: letters, digits, `_ . -`, max 64 characters |
| `bool Evaluate()` | Returns **true only when answers are available**. Never blocks longer than the timeout |
| `Get(key, dflt=0)` / `GetLabel(key, dflt="")` / `Has(key)` | Read answers |
| `Ok()` / `Status()` / `StatusText()` / `LastError()` / `HttpCode()` | Result of the last `Evaluate()` |
| `Model()` / `LatencyMs()` / `LastRef()` | Model version that answered, round-trip time, and snapshot ID (`profile\|symbol\|tf\|bar_time\|tag`) |
| `LogOutcome(ref, result, value=0)` | Record how a gated decision turned out |
| `PrintStats()` | Calls, failures, cache hits, replay misses, average latency and token totals |

### Integration rules of thumb

- **Gate entries, not exits.** Stops, take-profits, equity limits and kill switches must never depend on a model answer.
- **DCA and grid EAs: gate only the start of a sequence.** Blocking additions to an open sequence breaks the averaging maths.
- **Keep a parity switch.** With `InpUseJudgment = false` your EA must behave exactly as it did before JevGate was added.
- **Evaluate only when a signal fires**, on closed bars. `WebRequest` is synchronous, so the EA waits up to `timeoutMs` for each call.
- **One question per idea.** Combine answers in code with your own weights. When priorities change, you change a coefficient, not a prompt.

---

## Defining questions

Questions follow TypeSafe's three primitives. JevGate builds this request body for you:

```json
{
  "model": "jev-latest",
  "state": {
    "symbol": "AUDUSD", "timeframe": "H4", "tag": "sell",
    "features": {"dir": -1, "qqe": 71.2, "bb_dist_atr": 0.6, "h4_slope_atr": 1.4},
    "context": {"strategy": "Mean-reversion DCA from band extremes."}
  },
  "questions": {
    "trend_persists_against": {"type": "noul",   "instructions": "..."},
    "regime":                 {"type": "choice", "instructions": "...", "criteria": {"ranging": "...", "trending": "..."}},
    "reversion_quality":      {"type": "score",  "instructions": "...", "criteria": ["Unlikely", "Weak", "Reasonable", "Strong"]}
  }
}
```

Tips:

- Write choice descriptions and score levels as concrete situations, not vague words.
- Ask several questions in one EA. They're all answered in **one** API call, at about the same latency as a single question.
- Changing questions changes what the answers mean, so recalibrate thresholds afterwards. In backtests, record again (see below).

---

## Answer keys

| Question type | Keys | Read with |
|---|---|---|
| Noul | `key` (0..1) | `Get("key")` |
| Score | `key` (0..levels−1), `key.conf`, `key.0` … `key.N` (probability of each level) | `Get("key")`, `Get("key.2")` |
| Choice | `key` (label), `key.p` (probability of that label), `key.<option>` (each option's probability), `key.conf` | `GetLabel("key")`, `Get("key.p")`, `Get("key.trending")` |

`.conf` is TypeSafe's confidence (0–1, how concentrated the distribution is). Noul has no separate confidence: the probability is the whole answer.

---

## Modes and backtesting

| Mode | Where | What happens |
|---|---|---|
| `JEVGATE_LIVE` | Live/demo charts | Calls the API. Answers are cached per snapshot, so repeated calls on one bar are free |
| `JEVGATE_RECORD` | Strategy Tester | Writes every snapshot (and the question set) to files and returns no answers, so the EA uses its fallback (baseline behaviour) |
| `JEVGATE_REPLAY` | Strategy Tester | Reads pre-scored answers from a file. Your gate logic runs as it would live |
| `JEVGATE_OFF` | Anywhere | `Evaluate()` always returns false |
| `JEVGATE_AUTO` (default) | Anywhere | LIVE on charts. In the tester: REPLAY if a scores file exists, otherwise RECORD. Becomes OFF during optimisation if it would have recorded |

The MT5 Strategy Tester doesn't allow `WebRequest`, so backtests take three steps, all inside MT5:

```text
1. Backtest #1 (AUTO -> RECORD)   writes snapshots_<profile>.tsv and questions_<profile>.txt
2. Run the JevGateScorer script on any live/demo chart, with the same profile
                                   writes scores_<profile>.tsv   (re-run it to retry or resume)
3. Backtest #2 (AUTO -> REPLAY)   the gate is active, using the stored answers
```

The scorer uses the questions and model saved by the recording run, so the answers match exactly what that backtest asked. To record again from scratch (for example after changing questions), delete or rename `scores_<profile>.tsv`.

**Caveats you need to understand:**

- **Replay misses.** When the gate vetoes a trade in run #2, your EA may produce *new* signals that didn't exist in run #1 (for example, a slot that would have been in use is now free). Those have no stored answer. They return `replay_miss` and use your fallback, and `PrintStats()` reports how many.
- **Path-dependent features.** Features such as open-trade count or basket drawdown differ between the baseline and the gated run. Prefer features that depend only on market data if you want a faithful replay.
- **Look-ahead.** Jev may have been trained on data from the period you're backtesting. JevGate never sends the bar time, but price features alone can still be recognisable. Only trust results from periods after the model's training cut-off, or from forward testing.
- **Optimisation.** Replay works during optimisation (read-only). Recording doesn't. Use local test agents only, because cloud agents can't see your Common folder.
- **Cost.** The scorer makes one API call per recorded snapshot. Record over the period you actually need.

---

## Calibration

A probability is only useful if "0.7" happens about 70% of the time **on your strategy and your broker's data**.

Drag the **JevGateCalibrate** script onto any chart. It joins the answers with the outcomes you logged with `LogOutcome()`, using the snapshot ref:

| Input | Example | Meaning |
|---|---|---|
| Profile | `dca_start` | Same profile name as the EA |
| Data source | Backtest | **Backtest** reads `scores_<profile>.tsv` + `outcomes_tester_<profile>.tsv`. **Live** reads the decisions and outcomes files for the chart's symbol and timeframe. **Custom** uses the two file names you enter |
| Answer key | `trend_persists_against` | Any numeric answer key: a noul, a score, or one choice option such as `regime.trending` |
| Events | `deep,stopout` | Outcome results that count as the thing the question predicts |
| Scale / Invert | `3` / true | For a 4-level score where *low* means bad: divide by 3, then use 1 − value |

It prints the report to the Experts log and saves an aligned copy to `<Common>/Files/JevGate/calibration_<profile>_<key>.txt`. The report contains:

- **Brier score** (compared with always predicting the base rate), **log loss** and **ECE** (expected calibration error).
- **Reliability table:** does "p = 0.7" happen about 70% of the time?
- **Veto table:** for each threshold from 0.30 to 0.95, how many trades a veto would have removed, the event rate among removed and kept trades, and the summed value (e.g. P&L) of each group.

Good practice:

1. Choose thresholds on one period, then confirm them on a later period you haven't looked at.
2. Pin the model version (`SetModel`) once you've calibrated. A silent model upgrade invalidates your thresholds.
3. Compare against your baseline. If the gate doesn't improve profit factor or drawdown out of sample, switch it off.

---

## Failure handling

| Situation | Status | Recommended EA behaviour |
|---|---|---|
| Network error or timeout | `http_error` | Fallback (usually: allow the trade, as without JevGate) |
| URL not allow-listed | `not_allowed` | Fix terminal options. Printed once to the Experts log |
| Bad key (401), invalid request (422) | `api_error` | Fallback. Fix the setup (`LastError()` shows the API's message) |
| Rate limited (429), overloaded (529) | `api_error` | Fallback. The circuit breaker backs off after repeated failures |
| N consecutive failures | `breaker_open` | Fallback. Calls resume after the cool-down |
| Unreadable response | `parse_error` | Fallback |
| Tester without scores | `recorded` | Fallback (baseline run) |
| No stored answer in replay | `replay_miss` | Fallback |

"Fail open" (fall back to baseline behaviour) suits a veto-only gate, because an outage just means you trade as you did before. If you'd rather "fail closed" (no new entries without an answer), make that an explicit decision in your EA. Never let an outage block exits.

---

## Files JevGate uses

All files live in `<Common>/Files/JevGate/` (`%APPDATA%\MetaQuotes\Terminal\Common\Files\JevGate`), as tab-separated ANSI text:

| File | Written by | Contents |
|---|---|---|
| `api_key.txt` | you | Your TypeSafe API key, one line |
| `questions_<profile>.txt` | RECORD | Model, context and question set used by the recording run |
| `snapshots_<profile>.tsv` | RECORD (overwritten each run) | `ref, profile, symbol, timeframe, bar_time, tag, features` |
| `scores_<profile>.tsv` | JevGateScorer | `ref, response` |
| `decisions_<profile>_<symbol>_<tf>.tsv` | LIVE (appended, one file per chart) | `time, ref, mode, status, latency_ms, features, response` |
| `outcomes_<profile>_<symbol>_<tf>.tsv` | LIVE (appended, one file per chart) | `time, ref, result, value` |
| `outcomes_tester_<profile>.tsv` | tester (overwritten each run) | `time, ref, result, value` |
| `calibration_<profile>_<key>.txt` | JevGateCalibrate | The latest calibration report |

`features` is encoded as `key=value;key=value`. `response` holds the parsed answers in JevGate's flat form (`ok=1;model=jev-…;key=value;…`).

---

## Security

- The API key is read from the Common folder rather than an EA input, so it never ends up in `.set` files, screenshots or shared reports. `SetApiKey()` exists if you prefer to manage it yourself.
- The key is sent only to the configured endpoint, over HTTPS.
- `*.tsv` and `api_key.txt` are git-ignored. Your logs describe your strategy's features.

---

## Limitations and FAQ

**Is this high-frequency?** No. A round trip takes about 70–500 ms plus network time. It's meant for decisions on closed bars (M1 and up), not tick scalping.

**Can it run inside an indicator?** No. MQL5 doesn't allow `WebRequest` in indicators. Use an EA or a script.

**Does it work in MT4?** Not as written. It uses MQL5 features (`CHashMap`, tester flags).

**Several question sets in one EA?** Yes. Create one `CJevGate` object per profile. Each makes its own single API call per evaluation.

**Several EAs and charts?** Yes. Live logs are written per profile, symbol and timeframe, so charts don't share a file. Two EAs on the same symbol and timeframe should use different profile names. Tester files are per profile.

**What if TypeSafe changes its response format?** All response handling is in `CJevGate::ResponseToFlat` and follows the documented format (`answers.<key>.noul`, `.choice`, `.score`, `.probabilities`, `.confidence`). Check `decisions_*.tsv` or `LastError()` if answers stop appearing.

**Does it improve my strategy?** Only if your own calibration and out-of-sample tests show it does. Expect the honest answer to be "no" for many questions, and keep the parity switch so you can always turn it off.

---

## Licence

MIT. See [LICENSE](LICENSE).
