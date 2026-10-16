# Run order

Run the files in `sql/build/` **one after the other, in number order**. Nothing else is needed.
Every file selects the right database itself, so it does not matter which database is selected in SSMS.
After a step, run its test file from `sql/tests/`. Every test file prints a PASS / FAIL table and one summary line, so you never compare numbers by hand.

Two steps need you:
- **03** has one line to edit: the folder that holds `source_crm\` and `source_erp\`.
- **09** is optional and has a placeholder password to change.

| Step | File | What it does | Test after it |
|---|---|---|---|
| 01 | `01_create_database.sql` | **Drops and recreates** the DataWarehouse database, schemas, `AUTO_CLOSE OFF` | |
| 02 | `02_bronze_tables_and_procedure.sql` | Bronze tables and load procedure | |
| 03 | `03_load_bronze.sql` | **Edit the path**, loads the CSV files, shows row counts | `t03_bronze_tests.sql` |
| 04 | `04_silver_tables_and_procedure.sql` | Silver tables and load procedure | |
| 05 | `05_load_silver.sql` | Loads Silver, shows row counts | `t05_silver_tests.sql` |
| 06 | `06_gold_star_schema.sql` | Gold views, stored as indexed tables, loaded | `t06_gold_tests.sql` |
| 07 | `07_gold_reports.sql` | `gold.report_customers`, `gold.report_products` | `t07_gold_reports_tests.sql` |
| 08 | `08_semantic_views.sql` | The five semantic views the AI reads | `t08_warehouse_checks.sql` |
| 09 | `09_reader_login_optional.sql` | Read-only login and user (optional; needed only for the reader test) | `t09_reader_login_tests.sql` |
| 10 | `10_business_context.sql` | Company, time and limitation facts | `t10_business_context_tests.sql` |
| 11 | `11_metric_catalog.sql` | Column catalog and trusted KPIs | `t11_metric_catalog_tests.sql` |
| 12 | `12_business_glossary.sql` | Business words | `t12_glossary_tests.sql` |
| 13 | `13_curated_scope.sql` | Agents, permissions, prompt view | `t13_scope_tests.sql` |
| 14 | `14_golden_questions.sql` | 46 golden questions and the validator | `t14_golden_tests.sql` |
| 15 | `15_build_answer_key.sql` | Builds the answer snapshots (slow the first time) and approves the validated questions | `t15_answer_key_tests.sql` |
| 16 | `16_sql_validator.sql` | Rule catalog V01-V11 and `sp_dry_run` | `t16_sql_validator_tests.sql` |
| 17 | `17_cost_guardrails.sql` | Call limits, usage ledger, cache | `t17_guardrail_tests.sql` |
| 18 | `18_query_logging.sql` | Query log | `t18_logging_tests.sql` |
| 19 | `19_feedback.sql` | Thumbs up/down and review queue | `t19_feedback_tests.sql` |
| 20 | `20_evaluation.sql` | Evaluation tables and views | `t20_evaluation_tests.sql` |
| 21 | `21_monitoring_views.sql` | Power BI views and monitor role | `t21_monitoring_tests.sql` |
| 22 | `22_improvements.sql` | Change log and three improvement cycles | `t22_improvement_tests.sql` |
| 23 | `23_final_settings.sql` | Daily AI call limit (20) | `t23_final_settings_tests.sql` |
| 24 | `24_data_contracts.sql` | Data contract for the 5 semantic views: grain, key, every column and type; drift check | `t24_data_contract_tests.sql` |

Rules of thumb
- If a step fails, fix it and run **that same file again**. Files are written to be safe to re-run, except 01, which wipes the database.
- Start over from step 01 if you are unsure what state the database is in.
- `sql/tests/` files insert a few rows marked `test_agent` or `TEST`. The monitoring views leave them out.
- Re-run only the tests: `.\run_all.ps1 -Server "<server>" -OnlyTests`.
- `sql/ops/operations.sql` has the commands for later (limits, feedback review, results).
- `sql/analysis/` is the exploratory analysis. It is not needed to rebuild.

How to read a test result
- `PASS` the check holds. `FAIL` a RULE broke: fix the cause (the file name and test id tell you where). `DIFF` is not an error.
- **RULE** must always pass. **SEED** is true right after that step; a later step may change it on purpose (for example the glossary grows in step 22). **DATA** depends on the files you loaded; a DIFF only means your data is different from the one in the case study.
- A test file ends with an error message only when a RULE failed, so `run_all.ps1 -Tests` stops there.
- Tests that insert rows (`test_agent`, `TEST`) delete them again at the end.
