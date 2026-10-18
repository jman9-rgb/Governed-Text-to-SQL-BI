# GenBI Phase 12 - Power BI Monitoring: build guide

Power BI Desktop is free. Everything below is done on your own computer.
Run `phase12_monitoring.sql` in SSMS first and check T12.1 - T12.8.

## 1. Connect

1. Power BI Desktop > Home > **Get data > SQL Server**.
2. Server: the same server name you type in SSMS. Database: `DataWarehouse`.
3. Data Connectivity mode: **Import**. Do not paste SQL in the advanced box.
4. Sign in with your Windows account (the default).
5. In the Navigator expand `genbi` and tick exactly these 11 views, then **Load**:

| Tick this view | Rename to (Power Query / Model view) |
|---|---|
| genbi.vw_mon_date | Calendar |
| genbi.vw_mon_agent | Agent |
| genbi.vw_mon_questions | Questions |
| genbi.vw_mon_ai_usage | AIUsage |
| genbi.vw_mon_rules | RuleHits |
| genbi.vw_mon_eval | Eval |
| genbi.vw_mon_golden | Golden |
| genbi.vw_mon_scorecard | Scorecard |
| genbi.vw_eval_failures | EvalFailures |
| genbi.vw_improvement_backlog | Backlog |
| genbi.vw_feedback_queue | FeedbackQueue |

Why import and not DirectQuery: the data is small, imports are fast, and the dashboard never
queries your warehouse while someone looks at it. Home > **Refresh** reloads the numbers.

## 2. Model (Model view)

Mark **Calendar** as the date table (right-click Calendar > Mark as date table > `date_value`).
Create these relationships, all one-to-many, single direction (one side listed first):

| One side | Many side |
|---|---|
| Calendar[date_value] | Questions[log_date] |
| Calendar[date_value] | AIUsage[usage_date] |
| Calendar[date_value] | RuleHits[log_date] |
| Calendar[date_value] | Eval[run_date] |
| Agent[agent_name] | Questions[agent_name] |
| Agent[agent_name] | AIUsage[agent_name] |
| Agent[agent_name] | RuleHits[agent_name] |
| Agent[agent_name] | Eval[agent_name] |
| Agent[agent_name] | Golden[agent_name] |

Leave Scorecard, EvalFailures, Backlog and FeedbackQueue **without** relationships.
Scorecard is one row; the other three are lists.

If Power BI shows a relationship as many-to-many or inactive, the column types do not match:
check that `date_value` and the date columns are all type Date.

## 3. Measures

Create a table for them: Home > Enter data > name it `_Measures` > Load. Then add each measure
below with Modeling > New measure (select `_Measures` first).

```dax
-- ===== Usage =====
Questions = COUNTROWS ( Questions )

Answered = COALESCE ( CALCULATE ( COUNTROWS ( Questions ), Questions[is_answered] = 1 ), 0 )

Answer Rate % = DIVIDE ( [Answered], [Questions] )

Failures = COALESCE ( CALCULATE ( COUNTROWS ( Questions ), Questions[is_failure] = 1 ), 0 )

Failure Rate % = DIVIDE ( [Failures], [Questions] )

Blocked = COALESCE ( CALCULATE ( COUNTROWS ( Questions ), Questions[outcome] = "blocked" ), 0 )

SQL Errors = COALESCE ( CALCULATE ( COUNTROWS ( Questions ), Questions[outcome] = "sql_error" ), 0 )

-- ===== Speed (only questions that really called the AI; cache hits are instant and would hide problems) =====
Avg Seconds =
DIVIDE (
    CALCULATE ( AVERAGE ( Questions[total_ms] ), Questions[from_cache_n] = 0 ),
    1000
)

P95 Seconds =
DIVIDE (
    CALCULATE ( PERCENTILE.INC ( Questions[total_ms], 0.95 ), Questions[from_cache_n] = 0 ),
    1000
)

Slow Questions = COALESCE ( CALCULATE ( COUNTROWS ( Questions ), Questions[speed_band] = "3 Slow (> 10 s)" ), 0 )

-- ===== Cost =====
API Calls = COALESCE ( CALCULATE ( COUNTROWS ( AIUsage ), AIUsage[source] = "api" ), 0 )

Cache Hits = COALESCE ( CALCULATE ( COUNTROWS ( AIUsage ), AIUsage[source] = "cache" ), 0 )

Cache Hit % = DIVIDE ( [Cache Hits], [Cache Hits] + [API Calls] )

Failed AI Calls =
COALESCE ( CALCULATE ( COUNTROWS ( AIUsage ), AIUsage[source] = "api", AIUsage[status] = "error" ), 0 )

Tokens = SUM ( AIUsage[in_tokens] ) + SUM ( AIUsage[out_tokens] )

Calls Today = MAX ( Scorecard[api_calls_today] )

Daily Limit = MAX ( Scorecard[daily_limit] )

Budget Used % = DIVIDE ( [Calls Today], [Daily Limit] )

-- ===== Feedback =====
Thumbs Up = COALESCE ( CALCULATE ( COUNTROWS ( Questions ), Questions[rating] = "up" ), 0 )

Thumbs Down = COALESCE ( CALCULATE ( COUNTROWS ( Questions ), Questions[rating] = "down" ), 0 )

Rated % = DIVIDE ( [Thumbs Up] + [Thumbs Down], [Questions] )

Satisfaction % = DIVIDE ( [Thumbs Up], [Thumbs Up] + [Thumbs Down] )

-- ===== Evaluation =====
Eval Questions = COUNTROWS ( Eval )

Eval Passed = SUM ( Eval[passed_n] )

Pass % = DIVIDE ( [Eval Passed], [Eval Questions] )

Behavior OK % = DIVIDE ( SUM ( Eval[behavior_ok_n] ), [Eval Questions] )

Result OK % =
DIVIDE ( SUM ( Eval[result_ok_n] ), CALCULATE ( COUNT ( Eval[result_ok_n] ) ) )

Latest Run =
CALCULATE ( MAX ( Eval[run_id] ), ALL ( Eval ), Eval[run_status] = "complete" )

Latest Pass % =
VAR r = [Latest Run]
RETURN CALCULATE ( [Pass %], ALL ( Eval ), Eval[run_id] = r )

Previous Pass % =
VAR r = CALCULATE ( MAX ( Eval[run_id] ), ALL ( Eval ), Eval[run_status] = "complete", Eval[run_id] < [Latest Run] )
RETURN CALCULATE ( [Pass %], ALL ( Eval ), Eval[run_id] = r )

Pass % Change (pts) = ( [Latest Pass %] - [Previous Pass %] ) * 100

-- ===== Traffic lights (thresholds are choices, written down here on purpose) =====
Failure Status =
SWITCH ( TRUE (),
    ISBLANK ( [Failure Rate %] ), "No data",
    [Failure Rate %] <= 0.05, "Good",
    [Failure Rate %] <= 0.15, "Watch",
    "Action" )

Accuracy Status =
SWITCH ( TRUE (),
    ISBLANK ( [Latest Pass %] ), "No data",
    [Latest Pass %] >= 0.90, "Good",
    [Latest Pass %] >= 0.80, "Watch",
    "Action" )

Budget Status =
SWITCH ( TRUE (),
    [Budget Used %] >= 1, "Stopped",
    [Budget Used %] >= 0.8, "Watch",
    "Good" )
```

Set the format of every `... %` measure to Percentage (Measure tools > Format), `Avg Seconds`
and `P95 Seconds` to Decimal (1), and `Pass % Change (pts)` to Decimal (1).

Color convention for status cards (Format > Cell elements / Callout value > fx > Rules):
Good = green, Watch = amber, Action / Stopped = red. Never rely on color alone: show the status text too.

## 4. The four pages

Add a **Date slicer** (Calendar[date_value], Between) and an **Agent slicer** (Agent[agent_name])
on pages 1-3, then use Sync slicers so they work on all of them.
Page 4 uses a Run slicer instead (Eval[label]).

### Page 1 - Health (the page an interviewer sees first)
- Cards: `Questions`, `Answer Rate %`, `Failure Rate %` (with `Failure Status` as the subtitle), `P95 Seconds`, `Satisfaction %`.
- Cards from Scorecard (last 7 days, ignore slicers): `latest_eval_pass_pct`, `open_backlog`, `feedback_waiting_review`.
- Line chart: x = Calendar[date_value], y = `Questions`, `Failure Rate %` (secondary axis).
- Stacked bar: x = Questions[agent_name], y = `Questions`, legend = Questions[outcome].
- Small text note: "Answer rate is not a quality score: declining an out-of-scope question is correct behaviour."

### Page 2 - Usage and cost
- Gauge or card pair: `Calls Today` vs `Daily Limit`, `Budget Used %`, `Budget Status`.
- Clustered column: x = Calendar[date_value], y = `API Calls`, `Cache Hits`.
- Line: `Cache Hit %` by day.
- Donut or bar: `API Calls` by AIUsage[model] (shows which fallback model is really used).
- Card: `Failed AI Calls`; card: `Tokens`.

### Page 3 - Quality, safety and speed
- Bar: RuleHits[rule_code] with count of rows, tooltip RuleHits[description]; color by RuleHits[severity].
- Column: Questions[speed_band] by count (sort by speed_band, it starts with 1/2/3 on purpose).
- Stacked column: `Thumbs Up`, `Thumbs Down` by day.
- Table: Questions[asked_at], agent_name, question, outcome, total_ms, rating - filter `Questions[is_failure] = 1` or `rating = "down"`.
- Bar: thumbs-down count by Questions[reason_code].

### Page 4 - Evaluation and improvement (the portfolio centrepiece)
- Cards: `Latest Pass %`, `Previous Pass %`, `Pass % Change (pts)`, `Accuracy Status`.
- Line or column: x = Eval[label] (sort by Eval[run_id]), y = `Pass %`, `Behavior OK %`, `Result OK %`. One point per run: this is the improvement story.
- Bar: `Pass %` by Eval[question_type], and by Eval[agent_name].
- Stacked bar: count of Eval rows by Eval[failure_type] (visual filter `failure_type` is not `none`).
- Table (EvalFailures): golden_id, agent_name, question, failure_type, detail, expected_rows, got_rows. Visual-level filter: **Top N = 1 on run_id, by run_id** so it always shows the newest run.
- Table (Backlog): question, reason_code, fix_type, days_open.
- Table (Golden): count by `review_status` and `validation_status` (the test set must be Approved and valid).

## 5. Tests for the dashboard (T12.9 - T12.14)

| Test | What you do | Expected |
|---|---|---|
| T12.9 | Refresh. Compare the `Latest Pass %` card with SSMS `SELECT TOP 1 pass_pct FROM genbi.vw_eval_summary WHERE status='complete' ORDER BY run_id DESC;` | Same number (86.96% for run 3, or newer) |
| T12.10 | Page 1 `Questions` card with no slicer vs SSMS `SELECT COUNT(*) FROM genbi.vw_mon_questions;` | Same number |
| T12.11 | Page 2 `Calls Today` card vs SSMS `SELECT api_calls_today FROM genbi.vw_budget_today;` | Same number |
| T12.12 | Page 4 line chart | One point per complete run; run 2 = 82.61%, run 3 = 86.96% |
| T12.13 | Pick the agent slicer = product_agent on page 4 | Eval questions = 12 per run |
| T12.14 | In the app ask one question, give it a thumbs down, then Refresh in Power BI | `Questions` +1, `Thumbs Down` +1, FeedbackQueue shows the question |

If a number differs, the problem is the model (a relationship or a wrong column in a measure),
not the data: the SQL checks T12.2 - T12.5 already proved the views are right.

## 6. Publishing and privacy

**Do not commit the `.pbix` file.** It stores the data it loaded, including the questions people typed
(the `Questions`, `Backlog` and `FeedbackQueue` tables). The repo's `.gitignore` blocks `*.pbix` and `*.pbit`,
and the automatic checks fail if one is tracked.

**What to share instead**
- Take screenshots of pages 1-4 and save them in `docs/screenshots/`. Link them in the README.
- Before taking a screenshot, check that no real user question, name or path is visible on screen.
  If a visual shows question text, use test questions, or hide that column.
- Keep the `.pbix` on your own computer. If you share it privately, remove the `Questions`, `Backlog` and
  `FeedbackQueue` tables or their text columns first, then refresh.

**Sharing the dashboard online**
- Power BI Service (online sharing) needs a work or school account and a data gateway to a local SQL Server.
- It is optional. Screenshots in the README show the dashboard without any of that.
