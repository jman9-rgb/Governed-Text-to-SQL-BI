# Case study: making an AI SQL assistant trustworthy

**Role:** data analyst, sole builder. **Stack:** SQL Server, Python (Streamlit), Google Gemini free tier, Power BI.

## The problem
An AI that writes SQL is easy to demo and hard to trust. It can invent columns, add up the wrong grain, merge different customers
and drop decimals, and nobody notices until a wrong number reaches a decision. The question was not "can the AI write SQL?" but
**"how do we know when it is right, and what do we do when it is not?"**

## What I built
- **A governed warehouse:** bronze, silver and gold layers, with gold stored as indexed tables and a semantic layer of five views.
- **Knowledge in SQL tables, not in the prompt:** business context, a metric catalog with trusted KPI definitions, and a business glossary. One fix in a table applies to every future question.
- **Three agents** (sales, customer, product), each limited to its own views and its own database user.
- **Three safety layers:** a text validator (rules V01-V11), a dry run that checks the SQL compiles for that agent, and database permissions as the final wall (a forbidden object returns error 229).
- **Cost control** for a free tier: a daily call limit, an answer cache and a usage ledger.
- **Observability:** every question logged, thumbs up/down with a reason, and a four-page Power BI dashboard.
- **An evaluation harness:** 46 golden questions with a stored answer key. A question passes only if the AI chose the right behavior (answer, ask, decline, redirect) **and** the result matches the key.

## What the measurements showed
| Run | Score |
|---|---|
| Baseline | 82.61% |
| After fixing the first causes | 86.96% |
| After improvement cycle 1 | 93.48% |
| Final, fresh answers | **95.65%** (44 of 46) |

Scores move by about two questions between runs because the AI varies, so the honest claim is **about 93-96%, up from 83%**.

## What the failures were really caused by
None of them needed a smarter model.

| Failure | Real cause | Fix |
|---|---|---|
| Two questions timed out | The database shut itself down when idle | `AUTO_CLOSE OFF` |
| Growth included an incomplete month, and January came back empty | Missing time rule; the previous row was filtered out first | Metric time rule + one prompt rule |
| A price question returned 130 rows instead of 3 | The product agent had no trusted price metric | New weighted metric |
| Average order value lost the cents | Whole-number division | Trusted metric with a decimal cast |
| The AI answered where it should have asked | Glossary text allowed a default answer | Clarify-only wording |
| A customer ranking put a merged person first | Two customers share a name; the AI grouped by name | Catalog rule: names are not unique |

## Two things I got wrong, and how I handled them
- **My own scorer had a bug.** A NULL left out of the answer key made a correct answer look wrong. I found it by comparing the stored key with the live SQL, fixed it and added a test.
- **One run was not a fair test.** A resumed run reused cached answers and scored 100%. I excluded it and wrote down the rule for clean runs.

## How the project is tested
- 21 SQL test files, one per build step. Each prints PASS / FAIL, labels every check as RULE (always true), SEED (true after its own step) or DATA (depends on the source files), and stops the build when a RULE fails.
- Python self-tests (33/33 and 35/35) that need no database and no AI.
- The 46 golden questions for AI quality.
- While cleaning the repository for publication I found and fixed gaps the tests had hidden, for example golden questions that nothing ever approved. All are listed in `problems_and_fixes.md`.

## Skills shown
SQL Server design (schemas, permissions, views, stored procedures), data modelling, metric governance, testing with expected results,
Python, evaluation design, cost-aware engineering, Power BI (star schema, DAX), and honest reporting of results and limits.

## Limits
46 questions, one data set, hand-written answer key, and AI answers that vary between runs. #12 ("What is the sales growth?") is a known weak spot.
