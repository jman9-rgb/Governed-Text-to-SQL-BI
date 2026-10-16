# Architecture, stage by stage

The picture is in [architecture.svg](architecture.svg). This page explains each stage: what it does, which objects it creates,
which file builds it, which test proves it, and why it is designed that way.
Names below are the real object names in `sql/build/` and `app/`.

## How the pieces connect

```
 source CSV files
      |  03 load            04/05 clean            06 model            08 expose
 [bronze] --------> [silver] ---------> [gold tables] ---------> [semantic views] <---- the only data the AI may read
                                         fact_sales, dim_*             vw_sales, vw_monthly_sales,
                                                                       vw_customer_metrics, vw_product_metrics, vw_data_range
 [genbi governance tables: context, catalog, glossary, agents] --(view genbi.vw_agent_prompt)--> prompt text
 question -> agent -> prompt -> Gemini -> validator -> dry run -> run as agent user -> answer
                                                  \-> log, cache, usage ledger, feedback -> monitoring views -> Power BI
 46 golden questions -> evaluation run -> failures -> fix (data layer or prompt) -> change log -> run again
```

## Stage 1. Warehouse (steps 01-08)

| Layer | Objects | Built by | Tested by |
|---|---|---|---|
| Database and schemas | `bronze`, `silver`, `gold`, `semantic`; `AUTO_CLOSE OFF` | `01_create_database.sql` | `t22` (I1) |
| Bronze | 6 raw tables (3 CRM, 3 ERP) and `bronze.load_bronze` | 02, 03 | `t03_bronze_tests.sql` |
| Silver | 6 cleaned tables and `silver.load_silver` | 04, 05 | `t05_silver_tests.sql` |
| Gold | `gold.fact_sales`, `gold.dim_customers`, `gold.dim_products` as **indexed tables**, `gold.sp_load_gold`; report views `gold.report_customers`, `gold.report_products` | 06, 07 | `t06`, `t07` |
| Semantic | 5 views the AI can read | 08 | `t08_warehouse_checks.sql` |

Design decisions
- Gold is stored as tables, not views. As views they re-ran the Silver joins on every question and the validator was too slow. Re-run `EXEC gold.sp_load_gold;` after Silver changes.
- The AI never sees bronze, silver or gold. It sees five views with business names and a documented grain.
- Known data fact: 19 order lines have no order date (4,992 in sales). The dated views total 29,351,258; the all-time total is 29,356,250. The difference is documented, not hidden (`t08` W17).

## Stage 2. Governed knowledge (steps 10-13)

| Object | What it holds | Built by | Tested by |
|---|---|---|---|
| `genbi.business_context`, `genbi.view_context` | company, time rules (data ends mid-month), known limits, one description per view | 10 | `t10` |
| `genbi.metric_catalog` | one row per semantic column: type, how it may be aggregated | 11 | `t11` (M1, M2: every column documented) |
| `genbi.metric_definition` | trusted KPIs with their SQL expression, preferred view and caveat | 11 | `t11` |
| `genbi.business_glossary` | business words mapped to a metric, a column or a rule (some must make the AI ask) | 12 | `t12` |
| `genbi.agent`, `genbi.agent_view_access`, `genbi.sp_apply_scope` | three agents (sales, customer, product), the views each may use, and database users without a login that enforce it | 13 | `t13` |
| `genbi.vw_agent_prompt` | the prompt text, assembled per agent from the tables above | 13 | `t13`, `t22` |

Design decisions
- Definitions live in tables, not in prompt text. A fix to one row reaches every future question and is visible in the change log.
- Each agent gets only its own views, so the prompt is smaller and a wrong table is blocked by the database as well as by the prompt.

### Data contracts (step 24)
| Object | What it holds | Test |
|---|---|---|
| `genbi.data_contract_view` | for each semantic view: its grain, its unique key, its source tables and an exact row count where one applies | `t24` |
| `genbi.data_contract_column` | every column with its position and data type | `t24` |
| `genbi.vw_contract_drift` | every difference between the contract and the live views (empty means healthy) | `t24` C4 |
| `genbi.sp_contract_check` | drift, duplicate keys and the row count rule in one call | `t24` C8 |
| `genbi.sp_contract_rebaseline` | accepts a deliberate change to one view | |

The metric catalog says what a column **means**; the contract says what the view **is** (grain, key, types). If someone drops, renames or retypes a column, the check reports it before the AI, the golden questions or a dashboard break. Test `t24` also proves the check works: it edits the contract inside a transaction, confirms the three kinds of change are detected, and rolls back.

## Stage 3. Ask and answer (`app/`)

| Step | What happens | Where |
|---|---|---|
| 1. Question | The user picks an agent and types a question | `app/genbi_app.py` (Streamlit) |
| 2. Cache | A cached, still-valid answer skips the AI call | `genbi.sp_cache_get` / `sp_cache_put` (step 17) |
| 3. Budget | A daily call limit (20 on the free tier) stops runaway cost | `genbi.guardrail`, `vw_budget_today` (step 17) |
| 4. Prompt | Built from the SQL tables for that agent only | `genbi.vw_agent_prompt` |
| 5. Gemini | Returns JSON: behavior (Answer, Answer with stated assumption, Clarify, Decline, Redirect) and one SELECT | `google-genai` |
| 6. Safety 1 | Text rules V01-V11: one statement, SELECT/WITH only, no comments, no forbidden keywords, only this agent's views, no current-date functions, balanced quotes | `app/genbi_validator.py`, catalog `genbi.sql_rule` (step 16) |
| 7. Safety 2 | `genbi.sp_dry_run` compiles the SQL as that agent without running it | step 16 |
| 8. Safety 3 | The query runs as a database user that can read only that agent's views; anything else returns error 229 | step 13 |
| 9. Retry | If Gemini's JSON is unreadable, the app asks once more with a reminder (the retry counts as an AI call) | `genbi_app.py` |
| 10. Log | Every question, outcome, rule hit, timing, token count and retry flag is stored | steps 17-18 |

Tests: `t16` (rules and dry run), `t17` (budget, cache, ledger), `t18` (logging). Python: `genbi_validator.py` self-test 33/33.

## Stage 4. Observe (steps 17-19, 21 and Power BI)

| Need | Objects | Step | Test |
|---|---|---|---|
| Cost | `genbi.guardrail`, `ai_usage`, `answer_cache`, `vw_budget_today`, `vw_usage_daily` | 17 | `t17` |
| Every question | `genbi.query_log`, `query_log_rule`, `vw_query_log_recent`, `vw_query_log_daily`, `vw_rule_hits`, `vw_slow_queries` | 18 | `t18` |
| Human feedback | `genbi.feedback`, `feedback_reason`, `sp_submit_feedback`, `sp_review_feedback`, `vw_feedback_queue`, `vw_improvement_backlog`; a thumbs-down evicts the cached answer | 19 | `t19` |
| Dashboard feed | 8 read-only views `genbi.vw_mon_*` and the role `genbi_monitor` | 21 | `t21` |
| Dashboard | Power BI, Import mode, star schema, four pages: health, usage and cost, quality and safety, evaluation and improvement | `powerbi/powerbi_build_guide.md` | (visual) |

Design decisions
- Rows created by tests are marked (`test_agent`, `TEST`) and left out of the monitoring views.
- The Power BI file is not committed: it contains the questions people typed.

## Stage 5. Evaluate and improve (steps 14, 15, 20, 22 and `app/genbi_eval.py`)

| Piece | Detail | Step |
|---|---|---|
| Golden questions | 46 questions: 18 sales, 16 customer, 12 product; 38 answerable with trusted SQL and 8 that should be clarified, declined or redirected | 14 |
| Answer key | `genbi.sp_validate_golden` runs each trusted SQL as its agent and stores a result snapshot with a hash of the SQL; a changed SQL rebuilds only its own snapshot | 15 |
| Approval | Only validated questions become `Approved`; the evaluation runs approved questions only | 15 |
| Evaluation | `genbi_eval.py` asks every approved question; **pass = right behavior family AND result equals the snapshot** | 20 |
| Reports | `vw_eval_summary`, `vw_eval_by_agent`, `vw_eval_by_type`, `vw_eval_failures`, `vw_eval_detail`, `vw_eval_changes` | 20 |
| Change log | each fix is stored with the questions it should affect and the run before and after; `vw_change_effect` shows fixed / unchanged / regression | 22 |

The loop: measure, find the cause of each failure, fix it in the data layer or the prompt, log it, run again.
Every fix so far was a missing or vague definition, not a model weakness (see [problems_and_fixes.md](problems_and_fixes.md)).

## Stage 6. Testing approach

| Level | What | How it reports |
|---|---|---|
| SQL tests (`sql/tests/`) | one file per step, 21 files | PASS / FAIL table, one summary line, a `FAILED RULE TEST` table, and an error that stops `run_all.ps1` when a RULE fails |
| Python self-tests | validator 33/33, scorer 35/35 | no database or AI needed |
| AI quality | 46 golden questions | `vw_eval_summary` |
| CI on every push (`.github/workflows/checks.yml`) | compile the Python files, both self-tests, the SQL static check, and a scan for keys and private files (no database or API key needed) | a green or red check on GitHub |
| Static checks used while cleaning | every object created before it is used; balanced quotes and BEGIN/END; `CREATE VIEW/PROC` first in its batch; a `USE` in every file | run by the author before packaging |

Test kinds: **RULE** must always pass, **SEED** is true right after its own step, **DATA** depends on your source files (a mismatch shows as DIFF, not as an error).

## Security notes
- No keys in code: `GENBI_CONN` and `GEMINI_API_KEY` are environment variables; `.gitignore` blocks `.env`, secrets, CSVs and `.pbix`.
- The optional login password in step 09 is a placeholder; change it and never commit a real one.
- Generated SQL is read-only by construction: text rules, a dry run, and database users that have SELECT on their own views only.
