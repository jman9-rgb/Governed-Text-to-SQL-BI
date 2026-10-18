# Commands

Every command used in this project, in the order you need them. Windows PowerShell, run from the repository folder.

**How to read this page**
- Each task has the same three parts: **When** to use it, the **Command**, and what you should **See** afterwards.
- Replace anything in `< >` with your own value.
- SQL files can also be run in SSMS: open the file and press F5. The commands here do the same from PowerShell.

---

## Quick start

The shortest path from nothing to a running app. Details for each line are in the sections below.

```powershell
pip install -r requirements.txt                        # 1. install Python packages
# 2. set GENBI_CONN and GEMINI_API_KEY (section 1), then open a NEW terminal
# 3. edit the data folder path inside sql\build\03_load_bronze.sql
.\run_all.ps1 -Server "<server>" -Tests                # 4. build everything and test each step
cd app; streamlit run genbi_app.py                     # 5. start the app
```

## Find the command you need

| I want to... | Go to |
|---|---|
| Install and set up for the first time | [1. Setup](#1-setup) |
| Build the whole database | [2. Build](#2-build-the-database) |
| Run the tests | [3. Tests](#3-tests) |
| Start the app | [4. Run the app](#4-run-the-app) |
| Measure the AI with the 46 questions | [5. Evaluation](#5-evaluation) |
| Change the daily AI limit or check today's use | [6. Settings and checks](#6-settings-and-checks) |
| Clean up, reload Gold, find a problem | [7. Maintenance](#7-maintenance) |
| Put the project on GitHub | [8. Git and GitHub](#8-git-and-github) |

---

## 1. Setup

Do this once per computer.

### 1.1 Install the Python packages

**When:** first time, and after `requirements.txt` changes.

```powershell
pip install -r requirements.txt
```

**See:** `Successfully installed ...` at the end.

### 1.2 Check the tools

**When:** first time, or if a later command says a tool is missing.

```powershell
# is an ODBC driver for SQL Server installed? (note the exact name)
Get-OdbcDriver | Where-Object Name -like "*SQL Server*" | Select-Object Name

# is sqlcmd installed? (optional; SSMS can replace it)
sqlcmd -?
```

**See:** a line such as `ODBC Driver 17 for SQL Server` or `ODBC Driver 18 for SQL Server`. Use that name in the next step.

### 1.3 Set the environment variables

**When:** first time, and whenever the server name or key changes.
**Why:** the app reads its connection and key from the environment, so nothing secret is written in the code.

```powershell
setx GENBI_CONN "DRIVER={ODBC Driver 17 for SQL Server};SERVER=<server>;DATABASE=DataWarehouse;Trusted_Connection=yes;"
setx GEMINI_API_KEY "<your Gemini key>"

# optional: pin one Gemini model
setx GENBI_GEMINI_MODEL "gemini-3.5-flash-lite"
```

`setx` takes effect only in **new** terminals. Close this window and open a new PowerShell before going on.

### 1.4 Check them (in the new terminal)

```powershell
echo $env:GENBI_CONN
if ($env:GEMINI_API_KEY) { "key is set" } else { "key is NOT set" }
```

**See:** your connection string, and `key is set`.

| Problem | Fix |
|---|---|
| `key is NOT set` | You are in an old terminal. Open a new one. |
| Driver name not found later | Put the exact name from 1.2 in `GENBI_CONN` (driver 17 or 18). |

---

## 2. Build the database

Build files live in `sql/build/`, numbered 01 to 24. The full table is in [sql/RUN_ORDER.md](../sql/RUN_ORDER.md).

**Before you start**
- Step 01 **drops** an existing `DataWarehouse` database. Do not run it on data you want to keep.
- Edit the folder path inside `sql\build\03_load_bronze.sql` (the folder that holds `source_crm\` and `source_erp\`).

### 2.1 One command (recommended)

Stops at the first error.

```powershell
.\run_all.ps1 -Server "<server>"                    # build steps 01-24 (server examples: localhost, .\SQLEXPRESS)
.\run_all.ps1 -Server "<server>" -Tests             # build, and run each step's test after it
```

**See:** each step's name as it runs, then a PASS / FAIL table per test.

If it stops, fix the cause and continue from that step:

```powershell
.\run_all.ps1 -Server "<server>" -From 10           # continue from step 10
.\run_all.ps1 -Server "<server>" -From 10 -Tests    # continue from 10, with tests
```

**Certificate error?** `run_all.ps1` passes `-C` to `sqlcmd`. `-C` trusts the server certificate. A local SQL Server needs it.

### 2.2 One file at a time

**When:** to run a single step by hand. `-I` is needed so quoted identifiers are on.

```powershell
sqlcmd -S "<server>" -E -b -I -f 65001 -i sql\build\01_create_database.sql
```

### 2.3 Check after step 08

```powershell
sqlcmd -S "<server>" -E -Q "SELECT SUM(CAST(sales_amount AS BIGINT)) AS total_sales FROM DataWarehouse.semantic.vw_sales;"
```

**See:** `29356250` with the course data. A different number only means your data is different.

### 2.4 Optional: the read-only login (step 09)

Change the placeholder password in the file first, then run it by hand. Skipped by `run_all.ps1`.

```powershell
sqlcmd -S "<server>" -E -b -I -f 65001 -i sql\build\09_reader_login_optional.sql
```

---

## 3. Tests

Every SQL test file prints a PASS / FAIL table and one summary line. If a RULE fails, it also prints a `FAILED RULE TEST` table and ends with an error.

### 3.1 SQL tests

| I want to... | Command |
|---|---|
| Run all tests (no build) | `.\run_all.ps1 -Server "<server>" -OnlyTests` |
| Build and test together | `.\run_all.ps1 -Server "<server>" -Tests` |

Run one test and save the output:

```powershell
sqlcmd -S "<server>" -E -I -f 65001 -i sql\tests\t11_metric_catalog_tests.sql -o test_output_t11.txt
```

Show only the failing lines of one test:

```powershell
sqlcmd -S "<server>" -E -I -f 65001 -i sql\tests\t22_improvement_tests.sql | Select-String "FAIL"
```

How to read the result:

| Word | Meaning |
|---|---|
| `PASS` | the check holds |
| `FAIL` | a RULE broke: fix the cause (the test id tells you where) |
| `DIFF` | a DATA check differs from the case study because your data differs. Not an error |

### 3.2 Optional: test the read-only login

Run step 09 first (section 2.4).

```powershell
sqlcmd -S "<server>" -E -I -f 65001 -i sql\tests\t09_reader_login_tests.sql
```

### 3.3 Python tests

No database and no AI needed.

```powershell
cd app
python genbi_validator.py          # validator self-test
python genbi_eval.py --selftest    # scoring self-test
cd ..
```

**See:** `33/33 passed` and `35/35 passed`.

### 3.4 Test on a copy of the database

To try the build without touching your database: replace `DataWarehouse` with `DataWarehouse_test` in the SQL files and in `GENBI_CONN`, then run the same commands.

---

## 4. Run the app

**Before:** the build is done (section 2) and the environment variables are set (section 1.3).

```powershell
cd app
streamlit run genbi_app.py
```

**See:** a browser tab opens with the app. Pick an agent, then ask a question or choose a golden question in the sidebar.

---

## 5. Evaluation

Asks the 46 golden questions and scores the answers.

**Before every full run:** raise the daily AI call limit (section 6.1). A fresh run needs about 46 calls. Set it back to 20 afterwards.

```powershell
cd app
python genbi_eval.py --label my-run --fresh                              # full run, fresh AI answers
python genbi_eval.py --label customers --agent customer_agent --fresh    # one agent only
python genbi_eval.py --label quick --limit 15 --fresh                    # only 15 questions
python genbi_eval.py --run-id <n>                                        # resume run n (unfinished questions only)
```

| Option | Meaning |
|---|---|
| `--label` | the name of a new run |
| `--fresh` | do not use the cached answers |
| `--agent` | only this agent |
| `--limit` | at most this many questions |
| `--run-id` | continue an unfinished run |

Rules of thumb:
- For a clean test, use a **new** `--label` with `--fresh`.
- A resumed run (`--run-id`) ignores `--agent` and may reuse cached answers.
- If it stops with "Daily AI call budget reached", raise the limit, or resume tomorrow.

See the results (in SSMS or `sqlcmd`):

```sql
SELECT * FROM genbi.vw_eval_summary;
SELECT * FROM genbi.vw_eval_failures WHERE run_id = <n>;
```

---

## 6. Settings and checks

Define the server once per PowerShell window, so the commands below can be pasted as they are:

```powershell
$S = "<server>"
```

### 6.1 Daily AI call limit

```powershell
# normal day: 20 calls (the build sets this)
sqlcmd -S $S -E -Q "UPDATE DataWarehouse.genbi.guardrail SET limit_value = 20 WHERE guardrail_name = N'daily_ai_calls';"

# evaluation day: raise it, run the evaluation, then set it back to 20
sqlcmd -S $S -E -Q "UPDATE DataWarehouse.genbi.guardrail SET limit_value = 120 WHERE guardrail_name = N'daily_ai_calls';"
```

### 6.2 How many AI calls were used today?

```powershell
sqlcmd -S $S -d DataWarehouse -E -Q "SELECT api_calls_today, daily_limit, remaining FROM genbi.vw_budget_today;"
```

More hand-run commands (feedback review, evaluation results, change log) are in `sql/ops/operations.sql`.

---

## 7. Maintenance

| I want to... | Command |
|---|---|
| Reload Gold after Silver changed | `sqlcmd -S $S -d DataWarehouse -E -b -Q "EXEC gold.sp_load_gold;"` |
| Clean the Python caches | `Get-ChildItem -Recurse -Directory -Filter __pycache__ \| Remove-Item -Recurse -Force` |

(`$S` is set in section 6.)

---

## 8. Git and GitHub

### 8.1 First upload

```powershell
git init
git add .
git status                      # check that no key, password, .pbix or CSV is listed
git commit -m "GenBI: governed natural-language BI on SQL Server"
git branch -M main
git remote add origin https://github.com/<your-user>/<repo>.git
git push -u origin main
```

### 8.2 Later changes

```powershell
git add .
git commit -m "<what you changed>"
git push
```

### 8.3 Search for secrets before you push

```powershell
Select-String -Path (Get-ChildItem -Recurse -File -Include *.py,*.sql,*.md).FullName -Pattern "AIza","password\s*=","api_key\s*=\s*['\"]"
```

**See:** nothing. Any line found must be removed first.
