# GenBI Monitoring in Tableau: build guide

Same dashboard as `powerbi/powerbi_build_guide.md` (4 pages, same numbers), built in Tableau.
Run build step 21 (`21_monitoring_views.sql`) and its test `t21` first. The views must exist and the test must show no FAIL.

## 0. Choose your Tableau

| You have | How you connect | Notes |
|---|---|---|
| **Tableau Desktop** (paid or trial) | Directly to SQL Server (section 1A) | Closest to the Power BI version |
| **Tableau Public** (free) | Cannot connect to SQL Server. Export the views to CSV files, then connect to the files (section 1B) | Everything you publish is **public**: follow section 7 |

Tableau uses an **extract** (a saved copy of the data) in both cases. That matches Power BI Import mode:
the dashboard never queries your warehouse while someone looks at it, and the P95 calculation needs an extract.

## 1. Connect

### 1A. Tableau Desktop, direct connection
1. Connect > **Microsoft SQL Server** (install the SQL Server driver if Tableau asks).
2. Server: the same name you type in SSMS. Database: `DataWarehouse`. Authentication: **Windows Authentication**.
3. Drag these 11 views onto the canvas one at a time. Each becomes its own table (do not join them):

| View | Rename to |
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

4. Choose **Extract** (top right), then Sheet 1 > Extract the data.
5. Refresh later with Data > (data source) > Extract > Refresh.

Simplest layout: create **one data source per view** (Data > New Data Source, repeat for each view), so every sheet is built from exactly one table. Section 2 explains why.

### 1B. Tableau Public, CSV files
Run this once in PowerShell. It needs the `SqlServer` module (`Install-Module SqlServer -Scope CurrentUser`). Change the server name.
It writes 11 CSV files to a folder called `tableau_data` and leaves out the columns that contain text people typed.

```powershell
$server = "localhost"          # your server name
$db     = "DataWarehouse"
$out    = "tableau_data"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$views = @{
  Calendar       = "genbi.vw_mon_date"
  Agent          = "genbi.vw_mon_agent"
  Questions      = "genbi.vw_mon_questions"
  AIUsage        = "genbi.vw_mon_ai_usage"
  RuleHits       = "genbi.vw_mon_rules"
  Eval           = "genbi.vw_mon_eval"
  Golden         = "genbi.vw_mon_golden"
  Scorecard      = "genbi.vw_mon_scorecard"
  EvalFailures   = "genbi.vw_eval_failures"
  Backlog        = "genbi.vw_improvement_backlog"
  FeedbackQueue  = "genbi.vw_feedback_queue"
}
# columns that can hold what people typed (removed so the public workbook has no private text)
$private = "question","sql_text","ai_note","error_text","comment","reviewer_note"
$userTextTables = "Questions","AIUsage","Backlog","FeedbackQueue"

foreach ($name in $views.Keys) {
  $rows = Invoke-Sqlcmd -ServerInstance $server -Database $db -Query ("SELECT * FROM " + $views[$name]) -TrustServerCertificate
  if ($userTextTables -contains $name) { $rows = $rows | Select-Object * -ExcludeProperty $private }
  $rows | Export-Csv -Path (Join-Path $out ($name + ".csv")) -NoTypeInformation -Encoding UTF8
  "{0}: {1} rows" -f $name, @($rows).Count
}
```

In Tableau Public: Connect > **Text file**, add each CSV as its own data source (Data > New Data Source). If a date column arrives as text,
right-click the field > Change data type > Date. Refreshing means running the script again and reloading the files.
`Eval` question text is the author's golden question, not user text, so it stays.

## 2. Model (why there are no relationships)
Power BI joined `Calendar` and `Agent` to the fact tables. In Tableau those joins would form a loop
(Calendar, Questions, Agent, AIUsage and back to Calendar), and Tableau does not allow loops. So:

- Build every sheet from **one** table and use that table's own fields: `Questions[log_date]`, `AIUsage[usage_date]`, `Eval[run_date]`, `agent_name`.
- `Calendar` and `Agent` are not needed for charts. Skip them, or use `Calendar` only if you want days with no questions to appear as zero.
- Put the filters on the dashboard and set each one to apply to the worksheets that use that table (section 4).
- `Scorecard` is one row and `EvalFailures`, `Backlog`, `FeedbackQueue` are lists. They need no filters.

## 3. Calculated fields
Create each one on its table: right-click in the data pane > **Create Calculated Field**. Table name in brackets is where to create it.
After creating a percent field, right-click it > Default Properties > Number Format > **Percentage** (the fields return a fraction, 0.9565 = 95.65%).

### Questions table (usage, speed, feedback)
```
Questions        = COUNT([log_id])
Answered         = SUM([is_answered])
Answer Rate %    = SUM([is_answered]) / COUNT([log_id])
Failures         = SUM([is_failure])
Failure Rate %   = SUM([is_failure]) / COUNT([log_id])
Blocked          = COUNT(IF [outcome] = "blocked" THEN [log_id] END)
SQL Errors       = COUNT(IF [outcome] = "sql_error" THEN [log_id] END)

// speed: only questions that really called the AI (cache hits are instant and would hide problems)
Avg Seconds      = AVG(IF [from_cache_n] = 0 THEN [total_ms] END) / 1000
P95 Seconds      = PERCENTILE(IF [from_cache_n] = 0 THEN [total_ms] END, 0.95) / 1000
Slow Questions   = COUNT(IF [speed_band] = "3 Slow (> 10 s)" THEN [log_id] END)

// feedback
Thumbs Up        = COUNT(IF [rating] = "up" THEN [log_id] END)
Thumbs Down      = COUNT(IF [rating] = "down" THEN [log_id] END)
Rated %          = ([Thumbs Up] + [Thumbs Down]) / [Questions]
Satisfaction %   = [Thumbs Up] / ([Thumbs Up] + [Thumbs Down])

// traffic light (the thresholds are choices, written down here on purpose)
Failure Status   = IF ISNULL([Failure Rate %]) THEN "No data"
                   ELSEIF [Failure Rate %] <= 0.05 THEN "Good"
                   ELSEIF [Failure Rate %] <= 0.15 THEN "Watch"
                   ELSE "Action" END
```
`P95 Seconds` works on an extract only (it is not available on a live SQL Server connection).
Tableau shows a divide-by-zero as Null, so an empty database shows blanks instead of an error.

### AIUsage table (cost)
```
API Calls        = COUNT(IF [source] = "api" THEN [usage_id] END)
Cache Hits       = COUNT(IF [source] = "cache" THEN [usage_id] END)
Cache Hit %      = [Cache Hits] / ([Cache Hits] + [API Calls])
Failed AI Calls  = COUNT(IF [source] = "api" AND [status] = "error" THEN [usage_id] END)
Tokens           = SUM([in_tokens]) + SUM([out_tokens])
```

### Scorecard table (budget and top cards, one row)
```
Calls Today      = MAX([api_calls_today])
Daily Limit      = MAX([daily_limit])
Budget Used %    = MAX([api_calls_today]) / MAX([daily_limit])
Budget Status    = IF [Budget Used %] >= 1 THEN "Stopped"
                   ELSEIF [Budget Used %] >= 0.8 THEN "Watch"
                   ELSE "Good" END
```
`latest_eval_pass_pct`, `answer_rate_7d`, `failure_rate_7d` and `satisfaction_pct_7d` in this table are **already percentages (0 to 100)**.
Show them as a number with 2 decimals plus a "%" in the title. Do not give them the Percentage format, or 95.65 becomes 9565%.

### Eval table (evaluation)
```
Eval Questions   = COUNT([golden_id])
Eval Passed      = SUM([passed_n])
Pass %           = SUM([passed_n]) / COUNT([golden_id])
Behavior OK %    = SUM([behavior_ok_n]) / COUNT([golden_id])
Result OK %      = SUM([result_ok_n]) / COUNT([result_ok_n])      // COUNT skips the rows where no result was expected

Latest Run       = { FIXED : MAX(IF [run_status] = "complete" THEN [run_id] END) }
Previous Run     = { FIXED : MAX(IF [run_status] = "complete" AND [run_id] < [Latest Run] THEN [run_id] END) }
Latest Pass %    = SUM(IF [run_id] = [Latest Run] THEN [passed_n] END)
                   / COUNT(IF [run_id] = [Latest Run] THEN [golden_id] END)
Previous Pass %  = SUM(IF [run_id] = [Previous Run] THEN [passed_n] END)
                   / COUNT(IF [run_id] = [Previous Run] THEN [golden_id] END)
Pass % Change (pts) = ([Latest Pass %] - [Previous Pass %]) * 100      // format: number, 1 decimal

Accuracy Status  = IF ISNULL([Latest Pass %]) THEN "No data"
                   ELSEIF [Latest Pass %] >= 0.90 THEN "Good"
                   ELSEIF [Latest Pass %] >= 0.80 THEN "Watch"
                   ELSE "Action" END
```
`Avg Seconds` and `P95 Seconds`: number format, 1 decimal.
Colors for status text: Good = green, Watch = amber, Action / Stopped = red. Always show the status word as well, never color alone.

## 4. Filters on the dashboards
- **Date**: drag `log_date` (Questions) to Filters on each Questions sheet > Range of dates. Show the filter on the dashboard.
  Click the filter's arrow > **Apply to Worksheets > Selected Worksheets** and tick the sheets built from the same table.
  Repeat once for `usage_date` (AIUsage) on page 2 and once for `run_date` (Eval) on page 4.
- **Agent**: `agent_name` filter, same way, on each table that has it (Questions, AIUsage, RuleHits, Eval, Golden).
- **Run** (page 4): filter on `label` (Eval), single value list.
- In a worksheet: use **Dashboard > Actions** or "Use as Filter" (the funnel icon on a chart) when you want a click on a bar to filter the others.

## 5. The four dashboards
Create one worksheet per chart, then one **dashboard** per page (size: Automatic, or Fixed 1200 x 800 for screenshots).
Dashboard titles: "1 Health", "2 Usage and cost", "3 Quality, safety and speed", "4 Evaluation and improvement".

### Dashboard 1: Health (the page a reader sees first)
- Cards (a sheet with the measure as text): `Questions`, `Answer Rate %`, `Failure Rate %` with `Failure Status` next to it, `P95 Seconds`, `Satisfaction %`.
- Cards from `Scorecard` (last 7 days, ignore the date filter): `latest_eval_pass_pct`, `open_backlog`, `feedback_waiting_review`.
- Line chart: columns = `log_date` (Day, exact date), rows = `Questions` and `Failure Rate %` as a dual axis (right-click the second axis > Dual Axis, then Synchronize off).
- Stacked bar: columns = `agent_name`, rows = `Questions`, color = `outcome`.
- Text box: "Answer rate is not a quality score: declining an out-of-scope question is correct behaviour."

### Dashboard 2: Usage and cost
- Cards: `Calls Today`, `Daily Limit`, `Budget Used %`, `Budget Status` (from Scorecard).
- Clustered columns: `usage_date` by day, `API Calls` and `Cache Hits` (Measure Names / Measure Values).
- Line: `Cache Hit %` by day.
- Bar or pie: `API Calls` by `model` (shows which fallback model is really used).
- Cards: `Failed AI Calls`, `Tokens`.

### Dashboard 3: Quality, safety and speed
- Bar: `rule_code` (RuleHits) with `Number of Records`, color = `severity`, tooltip = `description`.
- Column: `speed_band` (Questions) by `Questions`. Sort by the field name so it stays 1, 2, 3.
- Stacked column: `Thumbs Up` and `Thumbs Down` by day.
- Table: `asked_at`, `agent_name`, `outcome`, `total_ms`, `rating` (a public workbook has no `question` column; see section 7). Filter `is_failure = 1` or `rating = "down"`.
- Bar: thumbs-down count by `reason_code`.

### Dashboard 4: Evaluation and improvement (the portfolio centerpiece)
- Cards: `Latest Pass %`, `Previous Pass %`, `Pass % Change (pts)`, `Accuracy Status`.
- Line: columns = `label` (sort: Field > `run_id` > Minimum > ascending), rows = `Pass %`, `Behavior OK %`, `Result OK %`. One point per run is the improvement story.
- Bars: `Pass %` by `question_type`, and by `agent_name`.
- Stacked bar: `Eval Questions` by `failure_type`, with the filter `failure_type` excluding `none`.
- Table (EvalFailures): `golden_id`, `agent_name`, `failure_type`, `detail`, `expected_rows`, `got_rows`.
  Filter so it always shows the newest run: right-click Filters > Add Filter > calculated: `[run_id] = { FIXED : MAX([run_id]) }` > True.
- Table (Backlog): `reason_code`, `fix_type`, `days_open`.
- Table (Golden): count of rows by `review_status` and `validation_status` (the test set must be Approved and valid).

## 6. Tests for the dashboard
| Test | What you do | Expected |
|---|---|---|
| TB1 | Refresh the extract. Compare the `Latest Pass %` card with SSMS: `SELECT TOP 1 pass_pct FROM genbi.vw_eval_summary WHERE status='complete' ORDER BY run_id DESC;` | Same number (95.65 for run 6 on the author's database; yours is your latest run) |
| TB2 | `Questions` card with no filter vs `SELECT COUNT(*) FROM genbi.vw_mon_questions;` | Same number |
| TB3 | `Calls Today` card vs `SELECT api_calls_today FROM genbi.vw_budget_today;` | Same number |
| TB4 | Dashboard 4 line chart | One point per complete run |
| TB5 | Agent filter = product_agent on dashboard 4 | 12 evaluation questions per run |
| TB6 | In the app ask one question and give it a thumbs down, re-export or refresh | `Questions` +1, `Thumbs Down` +1 |

If a number differs, check the calculated field or the filter scope first. The SQL tests in `t21` already prove the views.

## 7. Publishing and privacy
- **Tableau Public publishes the data too.** Anyone with the link can download the extract. Never publish the version that has `question`, `sql_text`, `ai_note`, `error_text`, `comment` or `reviewer_note`; the export script in 1B removes them.
- Before you publish: Data > (each source) > **Hide All Unused Fields**, then Extract > Remove unused fields. Save as `GenBI_Monitoring.twbx`.
- Do not commit the `.twbx` or the `tableau_data` folder to GitHub unless you are sure they contain no real user text. Add `tableau_data/` and `*.twb*` to `.gitignore`.
- For the README, take screenshots of the 4 dashboards instead (put them in `docs/screenshots/`).
- Tableau Desktop with a direct SQL Server connection needs a local machine or a gateway for online sharing; screenshots are enough for the portfolio.
