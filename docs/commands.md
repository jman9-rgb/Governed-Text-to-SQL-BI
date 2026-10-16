# Every command used in this project

Windows PowerShell, from the repository folder. Replace the values in `< >`.
Commands marked *(optional)* are helpers. SQL can also be run by opening the file in SSMS and pressing F5.

## 1. One-time setup

```powershell
# Python packages
pip install -r requirements.txt

# ODBC driver check (the connection string below must name an installed driver)
Get-OdbcDriver | Where-Object Name -like "*SQL Server*" | Select-Object Name

# SQL Server command-line tool check (optional; SSMS works instead)
sqlcmd -?
```

Environment variables (user level; open a NEW terminal afterwards):

```powershell
setx GENBI_CONN "DRIVER={ODBC Driver 17 for SQL Server};SERVER=<server>;DATABASE=DataWarehouse;Trusted_Connection=yes;"
setx GEMINI_API_KEY "<your Gemini key>"
# optional: pin one model
setx GENBI_GEMINI_MODEL "gemini-3.5-flash-lite"
```

Check them in the new terminal:

```powershell
echo $env:GENBI_CONN
if ($env:GEMINI_API_KEY) { "key is set" } else { "key is NOT set" }
```

## 2. Build the database and the GenBI layer

All build files are in `sql/build/`, numbered 01 to 24. The full table is in `sql/RUN_ORDER.md`.
Step 01 DROPS an existing DataWarehouse database. Before step 03, edit the folder path inside `03_load_bronze.sql`.

Option A (SSMS): open each file in number order and press F5. No database needs to be selected.

Option B (one command, stops at the first error):

```powershell
.\run_all.ps1 -Server "<server>"                 # for example localhost or .\SQLEXPRESS
.\run_all.ps1 -Server "<server>" -From 10        # continue from step 10 after fixing a failure
.\run_all.ps1 -Server "<server>" -Tests          # also runs the matching test file after each step
.\run_all.ps1 -Server "<server>" -OnlyTests      # runs only the test files
```

The same thing by hand for one file (`-I` is needed so quoted identifiers are on):

```powershell
sqlcmd -S "<server>" -E -b -I -f 65001 -i sql\build\01_create_database.sql
```

Check after step 08 (expected total sales: 29,356,250):

```powershell
sqlcmd -S "<server>" -E -Q "SELECT SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM DataWarehouse.semantic.vw_sales;"
```

Optional step 09 (read-only login): change the placeholder password in the file, then run it by hand.

## 3. Tests

Every SQL test file prints a PASS / FAIL table and one summary line. A RULE failure also prints a `FAILED RULE TEST` table and ends with an error.

```powershell
# all tests, no build (step 09 is skipped because it is optional)
.\run_all.ps1 -Server "<server>" -OnlyTests

# build and test together, step by step
.\run_all.ps1 -Server "<server>" -Tests

# one test file, output saved to a text file
sqlcmd -S "<server>" -E -I -f 65001 -i sql\tests\t11_metric_catalog_tests.sql -o test_output_t11.txt

# show only the failing lines of a test
sqlcmd -S "<server>" -E -I -f 65001 -i sql\tests\t22_improvement_tests.sql | Select-String "FAIL"
```

Optional read-only login and its test (run step 09 first):

```powershell
sqlcmd -S "<server>" -E -b -I -f 65001 -i sql\build\09_reader_login_optional.sql
sqlcmd -S "<server>" -E -I -f 65001 -i sql\tests\t09_reader_login_tests.sql
```

Python tests need no database and no AI:

```powershell
cd app
python genbi_validator.py          # validator self-test: 33/33
python genbi_eval.py --selftest    # scoring self-test:  35/35
cd ..
```

Using a test copy of the database: replace `DataWarehouse` with `DataWarehouse_test` in the SQL files and in `GENBI_CONN`, then run the same commands.

## 4. Settings

```powershell
# daily AI call limit (the build sets it to 20)
sqlcmd -S "<server>" -E -Q "UPDATE DataWarehouse.genbi.guardrail SET limit_value = 20 WHERE guardrail_name = N'daily_ai_calls';"
```

## 5. Run the app

```powershell
cd app
streamlit run genbi_app.py
```

## 6. Evaluation (46 golden questions)

```powershell
cd app
# EVALUATION DAY ONLY: raise the daily limit first (see sql/ops/operations.sql), then set it back to 20
python genbi_eval.py --label my-run --fresh                 # new full run, fresh AI answers
python genbi_eval.py --label customers --agent customer_agent --fresh   # one agent only
python genbi_eval.py --label quick --limit 15 --fresh       # only 15 questions
python genbi_eval.py --run-id <n>                           # RESUME run n (unfinished questions only)
```

- Use a new `--label` with `--fresh` for a clean test. A resumed run (`--run-id`) ignores `--agent` and may reuse cached answers.
- If the run stops with "Daily AI call budget reached", raise `daily_ai_calls`, or resume tomorrow.
- Results: `SELECT * FROM genbi.vw_eval_summary;` and `SELECT * FROM genbi.vw_eval_failures WHERE run_id = <n>;`

## 7. Maintenance

```powershell
# clean Python caches
Get-ChildItem -Recurse -Directory -Filter __pycache__ | Remove-Item -Recurse -Force

# reload Gold after Silver changed
sqlcmd -S $S -d DataWarehouse -E -b -Q "EXEC gold.sp_load_gold;"

# daily budget today
sqlcmd -S $S -d DataWarehouse -E -Q "SELECT api_calls_today, daily_limit, remaining FROM genbi.vw_budget_today;"
```

## 8. Git and GitHub

```powershell
git init
git add .
git status                      # check no key, password, .pbix or CSV is listed
git commit -m "GenBI: governed natural-language BI on SQL Server"
git branch -M main
git remote add origin https://github.com/<your-user>/<repo>.git
git push -u origin main
```

Search for secrets before the first push:

```powershell
Select-String -Path (Get-ChildItem -Recurse -File -Include *.py,*.sql,*.md).FullName -Pattern "AIza","password\s*=","api_key\s*=\s*['\"]"
```
