
"""
GenBI - PHASE 11: the Python app (validator, guardrails, query log, feedback). The evaluation runner genbi_eval.py imports it.

Run with:   streamlit run genbi_app.py

For every question:
  1. Reads the agent's prompt from SQL Server (view genbi.vw_agent_prompt).
  2. Asks Google Gemini for ONE JSON reply {"behavior", "sql", "note"}.
  3. Runs the SQL AS the agent's own database user (EXECUTE AS USER).
  4. Shows the answer, the SQL and the assumption.

Environment variables (set them in the SAME terminal that runs Streamlit):
  GENBI_CONN              SQL Server connection string (required)
  GEMINI_API_KEY          Google Gemini API key (required)
  GENBI_GEMINI_MODEL      optional: pin ONE Gemini model.

NOT in this phase: Phase 12 Power BI | Phase 13 improvement | Phase 10 feedback
"""

import os
import re
import json
import time
import hashlib
from contextlib import closing

import pandas as pd
import pyodbc
import streamlit as st
from google import genai
from google.genai import types

import genbi_validator as gv     # Phase 7 text rules (must be in the same folder)

pyodbc.pooling = False

CONN_STR = os.environ.get("GENBI_CONN", "")
MAX_ROWS = 1000          # defaults only: the real limits live in genbi.guardrail (Phase 8 SQL)
TIMEOUT_SEC = 120

DEFAULT_LIMITS = {
    "daily_ai_calls": 100,
    "max_ai_calls_per_question": 3,
    "max_rows": MAX_ROWS,
    "query_timeout_sec": TIMEOUT_SEC,
    "max_output_tokens": 4096,
    "max_prompt_chars": 60000,
    "max_question_chars": 500,
    "cache_ttl_minutes": 60,
}


class GuardrailError(Exception):
    """A cost guardrail stopped the request. The message is safe to show to the user."""


GEMINI_MODEL = os.environ.get(
    "GENBI_GEMINI_MODEL", "gemini-3.5-flash-lite"
).strip()

MAX_FALLBACK_MODELS = 3

PREFERRED_MODELS = [
    GEMINI_MODEL,
    "gemini-3.8-flash-lite",
    "gemini-3.8-flash",
]

SECTION_TITLES = {
    1: "BUSINESS CONTEXT",
    2: "VIEWS YOU MAY USE",
    3: "COLUMNS OF THESE VIEWS",
    4: "TRUSTED METRICS (use these expressions)",
    5: "GLOSSARY (business words and what they mean)",
}
ANSWERABLE = ("Answer", "Answer with stated assumption")
BEHAVIORS = ANSWERABLE + ("Clarify", "Decline", "Redirect")


# ------------------------------------------------------------------
# Database
# ------------------------------------------------------------------
def db_read(sql, params=()):
    with closing(pyodbc.connect(CONN_STR, autocommit=True)) as cn:
        return cn.cursor().execute(sql, params).fetchall()


def db_exec(sql, params=()):
    with closing(pyodbc.connect(CONN_STR, autocommit=True)) as cn:
        cn.cursor().execute(sql, params)


def get_agents():
    rows = db_read(
        "SELECT agent_name, db_user, description "
        "FROM genbi.agent WHERE is_active = 1 ORDER BY agent_name"
    )
    return {
        r[0]: {"db_user": r[1], "description": r[2]}
        for r in rows
    }


def run_as_agent(db_user, sql, max_rows=MAX_ROWS, timeout=TIMEOUT_SEC):
    """Run SQL as the agent's database user."""
    if not re.fullmatch(r"\w+", db_user):
        raise ValueError("Bad agent user name.")

    if not re.match(r"(?is)^\s*(select|with)\b", sql):
        raise ValueError("Only SELECT queries can be run.")

    with closing(pyodbc.connect(CONN_STR, autocommit=True)) as cn:
        cn.timeout = timeout
        cur = cn.cursor()
        cur.execute(f"EXECUTE AS USER = N'{db_user}'")

        try:
            t0 = time.time()
            cur.execute(sql)
            cols = [c[0] for c in cur.description]
            rows = cur.fetchmany(max_rows + 1)
            ms = int((time.time() - t0) * 1000)

            truncated = len(rows) > max_rows
            df = pd.DataFrame.from_records(
                [tuple(r) for r in rows[:max_rows]],
                columns=cols,
            )
            return df, truncated, ms

        finally:
            try:
                cur.execute("REVERT")
            except Exception:
                pass


# ------------------------------------------------------------------
# Prompt
# ------------------------------------------------------------------
def build_prompt(agent_name):
    lines = db_read(
        "SELECT sec, line_text FROM genbi.vw_agent_prompt "
        "WHERE agent_name = ? ORDER BY sec, ord, item",
        (agent_name,),
    )

    others = db_read(
        "SELECT agent_name, description FROM genbi.agent "
        "WHERE is_active = 1 AND agent_name <> ? ORDER BY agent_name",
        (agent_name,),
    )

    parts, current = [], None

    for sec, line_text in lines:
        if sec != current:
            parts.append(
                f"\n=== {SECTION_TITLES.get(sec, 'SECTION ' + str(sec))} ==="
            )
            current = sec
        parts.append(line_text)

    knowledge = "\n".join(parts)
    other_text = "\n".join(
        f"- {a}: {d}" for a, d in others
    ) or "(none)"

    return (
        "You are a careful SQL Server (T-SQL) data analyst assistant for business users.\n"
        "You are the agent '" + agent_name + "'. "
        "You can only use the views listed below.\n\n"
        "Reply with ONLY one JSON object, nothing else. "
        "No explanation, no markdown, no code fences:\n"
        '{"behavior": "<one of the five below>", '
        '"sql": "<one SELECT or null>", "note": "<text>"}\n\n'
        "behavior:\n"
        '- "Answer": the question is clear and you wrote the SQL. '
        "note = one short sentence on what the result shows.\n"
        '- "Answer with stated assumption": you wrote the SQL after applying '
        "a glossary default or an assumption. "
        "note MUST state the assumption and the exact time period used.\n"
        '- "Clarify": too vague to answer without guessing. '
        "sql = null. note = ONE short question to the user.\n"
        '- "Decline": the data cannot answer it (for example profit, forecasts). '
        "sql = null. note = why not, and what you can offer instead.\n"
        '- "Redirect": the question needs a view you do not have. sql = null. '
        "note = which other agent can answer it.\n"
        "Decline vs Redirect: if the data could exist in ANOTHER agent's area "
        "(see OTHER AGENTS below; for example country, region, sales, orders, "
        "revenue, products), use Redirect and name that agent, even if you "
        "cannot see its columns. Use Decline only when no agent could answer "
        "it (churn, profit, forecasts).\n\n"
        "SQL RULES:\n"
        "1. ONE SELECT statement (WITH ... SELECT is allowed). "
        "No semicolon, no comments.\n"
        "2. Use ONLY the views listed for you, written as semantic.<view>. "
        "Never invent views or columns.\n"
        "3. Orders: COUNT(DISTINCT order_number). "
        "Customers: COUNT(DISTINCT customer_key). "
        "Never COUNT(*) on order lines for these.\n"
        "4. When a TRUSTED METRIC exists, use its expression exactly.\n"
        "5. Cast to DECIMAL before dividing and use NULLIF to avoid division by zero.\n"
        "6. TOP n needs ORDER BY the measure, then a tie-breaker column that is "
        "ALREADY in the output or GROUP BY. Never add a column to GROUP BY "
        "just to break ties: it changes the number of rows.\n"
        "7. Use DATEFROMPARTS, not DATETRUNC. Never use GETDATE() or SYSDATETIME(): "
        "relative dates come from semantic.vw_data_range.\n"
        "8. Give every output column a readable alias.\n"
        "9. Do not join views of different grain unless the result cannot double count.\n"
        "10. If the question names NO time period, use ALL data: no date filter, "
        "and do not touch semantic.vw_data_range. Example: total sales -> "
        "SELECT SUM(<trusted sales expression>) AS total_sales "
        "FROM semantic.vw_sales\n"
        "11. semantic.vw_data_range has ONE row. Use it only for relative dates "
        "(last month, last year, year to date), and only as a scalar subquery, "
        "for example WHERE order_date >= (SELECT DATEFROMPARTS("
        "YEAR(last_order_date), MONTH(last_order_date), 1) "
        "FROM semantic.vw_data_range). Never put its columns next to an aggregate "
        "without GROUP BY. Check its real column names in the views list above.\n"
        "12. For totals by month or year, or relative periods such as last month "
        "or this year, use semantic.vw_monthly_sales when it is in your views "
        "list (one row per month, filter on sales_month). Use semantic.vw_sales "
        "only when you need order-level detail. Never wrap a date column in a "
        "function inside a WHERE clause.\n"
        "13. 'per X', 'by X' or 'for each X' means ONE output row per value of X: "
        "GROUP BY X only. Do not add key or name columns to the GROUP BY.\n"
        "14. For LAG, LEAD or running totals, calculate them in a CTE over ALL "
        "rows first, then apply the year, month or other filter in the outer "
        "SELECT. Filtering first removes the previous row and gives NULL.\n\n"
        "ANSWER STYLE: short plain business language. "
        "Mention a data limitation only when it affects the answer.\n\n"
        "OTHER AGENTS (for Redirect):\n" + other_text + "\n"
        + knowledge + "\n"
    )


# ------------------------------------------------------------------
# Reading the AI reply
# ------------------------------------------------------------------
def _unreadable(note, raw):
    return {
        "behavior": "Unreadable",
        "sql": None,
        "note": note,
        "raw": (raw or "")[:3000],
    }


def parse_reply(text):
    """Turn the model text into {behavior, sql, note, raw}. Never raises."""
    if not isinstance(text, str) or not text.strip():
        return _unreadable(
            "The AI returned an empty reply (the model may be busy "
            "or ran out of tokens).",
            text,
        )

    raw = text
    text = text.strip()
    text = re.sub(
        r"^\s*```(?:json)?\s*", "", text, flags=re.I
    )
    text = re.sub(r"\s*```\s*$", "", text)

    data = None

    try:
        cand = json.loads(text, strict=False)
        if isinstance(cand, dict):
            data = cand
    except (ValueError, TypeError):
        pass

    if data is None:
        dec = json.JSONDecoder(strict=False)
        for i, ch in enumerate(text):
            if ch != "{":
                continue
            try:
                cand, _ = dec.raw_decode(text[i:])
                if isinstance(cand, dict) and (
                    "behavior" in cand or "sql" in cand
                ):
                    data = cand
                    break
            except (ValueError, TypeError):
                continue

    if data is None:
        return _unreadable(
            "The AI reply was not valid JSON.", raw
        )

    sql = data.get("sql")
    sql = (
        sql.strip().rstrip(";").strip()
        if isinstance(sql, str) and sql.strip()
        else None
    )

    if sql and sql.lower() in ("null", "none"):
        sql = None

    behavior = data.get("behavior")

    if behavior not in BEHAVIORS:
        behavior = "Answer" if sql else "Clarify"

    if behavior in ANSWERABLE and not sql:
        behavior = "Clarify"

    if behavior not in ANSWERABLE:
        sql = None

    return {
        "behavior": behavior,
        "sql": sql,
        "note": str(data.get("note") or ""),
        "raw": "",
    }


# ------------------------------------------------------------------
# Google Gemini API
# ------------------------------------------------------------------
def candidate_models():
    """Return Gemini models in preferred order, with duplicate IDs removed."""
    models = []

    for model in PREFERRED_MODELS:
        model = model.strip()
        if model and model not in models:
            models.append(model)

    return models[:MAX_FALLBACK_MODELS]


def get_limits():
    """Read the limits from genbi.guardrail (falls back to defaults for any missing name)."""
    try:
        rows = db_read("SELECT guardrail_name, limit_value FROM genbi.guardrail")
    except Exception as e:
        raise GuardrailError(
            "The guardrail tables are missing. Run phase8_cost_guardrails.sql in SSMS first. ("
            + str(e)[:150] + ")"
        )
    limits = dict(DEFAULT_LIMITS)
    limits.update({r[0]: int(r[1]) for r in rows})
    return limits


def budget_today():
    """(AI calls used today, daily limit)."""
    row = db_read("SELECT api_calls_today, daily_limit FROM genbi.vw_budget_today")[0]
    return int(row[0]), int(row[1])


def log_ai_call(agent_name, model, source, in_tok, out_tok, status, error=None):
    """Write one row to the cost ledger. A logging problem must never break an answer."""
    try:
        db_exec(
            "EXEC genbi.sp_log_ai_call ?, ?, ?, ?, ?, ?, ?",
            (agent_name, model, source, in_tok, out_tok, status, (error or "")[:400] or None),
        )
    except Exception as e:
        print("Could not write the AI usage log:", e)


def norm_question(question):
    """'  What are TOTAL sales?? ' and 'what are total sales' share one cache entry."""
    return " ".join(question.lower().split()).rstrip("?.! ")


def make_cache_key(agent_name, prompt, question):
    prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()   # a changed glossary/metric = new key
    raw = f"{agent_name}|{prompt_hash}|{norm_question(question)}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def cache_get(key, ttl_minutes):
    rows = db_read("EXEC genbi.sp_cache_get ?, ?", (key, ttl_minutes))
    return rows[0] if rows else None


def cache_put(key, agent_name, question, reply):
    try:
        db_exec(
            "EXEC genbi.sp_cache_put ?, ?, ?, ?, ?, ?",
            (key, agent_name, question[:500], reply["behavior"], reply["sql"], reply["note"]),
        )
    except Exception as e:
        print("Could not write the answer cache:", e)


def _generate(model, system_prompt, question, ctx):
    """Call Gemini (counted, limited and logged) and return response text and token counts."""
    lim = ctx["limits"]

    if ctx["calls"] >= lim["max_ai_calls_per_question"]:
        raise GuardrailError(
            f"AI call limit for one question reached ({lim['max_ai_calls_per_question']})."
        )
    if ctx["used_today"] + ctx["calls"] >= lim["daily_ai_calls"]:
        raise GuardrailError(
            f"Daily AI call budget reached ({lim['daily_ai_calls']}). "
            "Cached answers still work. The budget resets tomorrow, or raise "
            "daily_ai_calls in genbi.guardrail."
        )

    ctx["calls"] += 1
    client = genai.Client(api_key=os.environ["GEMINI_API_KEY"])

    try:
        response = client.models.generate_content(
            model=model,
            contents=question,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0,
                max_output_tokens=lim["max_output_tokens"],
                response_mime_type="application/json",
            ),
        )

        text = response.text or ""
        usage = response.usage_metadata

        in_tok = (getattr(usage, "prompt_token_count", 0) or 0) if usage else 0
        out_tok = (getattr(usage, "candidates_token_count", 0) or 0) if usage else 0

        log_ai_call(ctx["agent"], model, "api", in_tok, out_tok, "ok")
        return text, in_tok, out_tok

    except Exception as e:
        log_ai_call(ctx["agent"], model, "api", 0, 0, "error", str(e))   # failed calls still use quota
        raise

    finally:
        client.close()


def ask_model(model, system_prompt, question, ctx):
    """Ask Gemini; if JSON is unreadable, retry once with a reminder (the retry is counted too)."""
    text, in_tok, out_tok = _generate(model, system_prompt, question, ctx)
    reply = parse_reply(text)

    if reply["behavior"] == "Unreadable":
        text, i2, o2 = _generate(
            model,
            system_prompt,
            question + "\n\nReply with ONLY the JSON object. No other text, no markdown.",
            ctx,
        )
        in_tok += i2
        out_tok += o2
        reply = parse_reply(text)

    return reply, in_tok, out_tok


def ask_gemini(system_prompt, question, ctx):
    """Try configured Gemini models in order, inside the per-question and daily limits."""
    tried = []
    last_unreadable = None

    for model in candidate_models():
        try:
            reply, in_tok, out_tok = ask_model(model, system_prompt, question, ctx)
        except GuardrailError:
            if last_unreadable:
                break                      # out of budget: show the last reply we did get
            raise
        except Exception as e:
            tried.append(f"{model}: {str(e)[:150]}")
            continue

        if reply["behavior"] == "Unreadable":
            tried.append(f"{model}: unreadable reply")
            last_unreadable = (reply, in_tok, out_tok, model)
            continue

        return reply, in_tok, out_tok, model, tried

    if last_unreadable:
        reply, in_tok, out_tok, model = last_unreadable
        return reply, in_tok, out_tok, model, tried

    raise RuntimeError("No Gemini model answered. " + " | ".join(tried))


# ------------------------------------------------------------------
# One question end to end
# ------------------------------------------------------------------
def allowed_views(agent_name):
    return [
        r[0] for r in db_read(
            "SELECT view_name FROM genbi.agent_view_access WHERE agent_name = ?",
            (agent_name,),
        )
    ]


def check_sql(agent_name, sql):
    """Layer 1 (text rules), then layer 2 (SQL Server dry run). Returns the validator result."""
    result = gv.validate_sql(sql, allowed_views(agent_name))

    if result["verdict"] == "BLOCKED":
        return result                      # no need to ask the database

    try:
        row = db_read("EXEC genbi.sp_dry_run ?, ?", (agent_name, sql))[0]
        if not row[0]:
            gv.add_dry_run_failure(result, f"error {row[2]}: {row[3]}")
    except Exception as e:
        gv.add_dry_run_failure(result, "dry run could not be executed: " + str(e))

    return result


def run_reply(
    question, agent, reply, in_tok, out_tok,
    prompt_chars, label=None, tried=None, check=None,
    limits=None, from_cache=False, ai_calls=0
):
    """Run the SQL of a parsed reply as the agent's user, inside the row and time limits."""
    limits = limits or DEFAULT_LIMITS
    result = {"question": question}

    result.update(
        reply,
        in_tok=in_tok,
        out_tok=out_tok,
        prompt_chars=prompt_chars,
        df=None,
        error=None,
        label=label,
        tried=tried or [],
        check=check,
        max_rows=limits["max_rows"],
        from_cache=from_cache,
        ai_calls=ai_calls,
    )

    if reply["sql"] and check and check["verdict"] == "BLOCKED":
        return result                      # blocked by the validator: never sent to the database

    if reply["sql"]:
        for attempt in (1, 2):
            try:
                df, truncated, ms = run_as_agent(
                    agent["db_user"], reply["sql"],
                    limits["max_rows"], limits["query_timeout_sec"],
                )
                result.update(
                    df=df, truncated=truncated, ms=ms,
                    retried=(attempt == 2), error=None,
                )
                break

            except Exception as e:
                result["error"] = str(e)[:600]
                is_timeout = (
                    "HYT00" in str(e) or "timeout expired" in str(e).lower()
                )

                if is_timeout:
                    print("SQL QUERY TIMED OUT:")
                    print(reply["sql"])

                if attempt == 1 and is_timeout:
                    continue
                break

    return result


def answer(question, agent_name, agent, use_cache=True):
    """Guardrails -> cache -> AI -> validator -> SQL -> cache the good replies."""
    limits = get_limits()
    question = " ".join(question.split())

    if len(question) > limits["max_question_chars"]:
        raise GuardrailError(
            f"The question is {len(question)} characters; the limit is {limits['max_question_chars']}."
        )

    prompt = build_prompt(agent_name)

    if len(prompt) > limits["max_prompt_chars"]:
        raise GuardrailError(
            f"The prompt is {len(prompt):,} characters; the limit is {limits['max_prompt_chars']:,}. "
            "Trim the glossary or context, or raise max_prompt_chars."
        )

    key = make_cache_key(agent_name, prompt, question)
    cached = cache_get(key, limits["cache_ttl_minutes"]) if use_cache else None   # evaluation can bypass the cache

    if cached:
        reply = {"behavior": cached[0], "sql": cached[1], "note": cached[2] or "", "raw": ""}
        in_tok = out_tok = ai_calls = 0
        model, tried, from_cache = "cache", [], True
        log_ai_call(agent_name, "cache", "cache", 0, 0, "ok")
    else:
        used, _ = budget_today()
        ctx = {"agent": agent_name, "limits": limits, "used_today": used, "calls": 0}
        reply, in_tok, out_tok, model, tried = ask_gemini(prompt, question, ctx)
        ai_calls, from_cache = ctx["calls"], False

    check = check_sql(agent_name, reply["sql"]) if reply["sql"] else None

    result = run_reply(
        question,
        agent,
        reply,
        in_tok,
        out_tok,
        len(prompt),
        label="Answered from cache (no AI call used)" if from_cache else f"Google Gemini {model}",
        tried=tried,
        check=check,
        limits=limits,
        from_cache=from_cache,
        ai_calls=ai_calls,
    )

    result["model"] = model
    result["cache_key"] = key

    good = (
        not from_cache
        and reply["behavior"] != "Unreadable"
        and not result["error"]
        and not (check and check["verdict"] == "BLOCKED")
    )
    if good:
        cache_put(key, agent_name, question, reply)

    return result


# ------------------------------------------------------------------
# Query log (Phase 9)
# ------------------------------------------------------------------
def outcome_of(res):
    """One word for what happened to a question. Matches the CHECK in genbi.query_log."""
    chk = res.get("check")
    if res["behavior"] == "Unreadable":
        return "unreadable"
    if chk and chk["verdict"] == "BLOCKED":
        return "blocked"
    if res.get("error"):
        return "sql_error"
    if res["behavior"] in ANSWERABLE:
        return "answered"
    return "not_answered"                  # Clarify, Decline, Redirect


def log_query(agent_name, question, res=None, outcome=None, error=None, total_ms=None):
    """Write one row to genbi.query_log. Returns the log_id, or None. Never breaks an answer."""
    try:
        chk = (res or {}).get("check")
        codes = [i["code"] for i in chk["issues"]] if chk else []
        df = (res or {}).get("df")

        row = db_read(
            "EXEC genbi.sp_log_query ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?",
            (
                agent_name,
                question[:500],
                res["behavior"] if res else None,
                outcome or outcome_of(res),
                (res["note"] or None) if res else None,
                res["sql"] if res else None,
                chk["verdict"] if chk else None,
                ",".join(codes) or None,
                bool(res and res["sql"] and not (chk and chk["verdict"] == "BLOCKED")),
                len(df) if df is not None else None,
                res.get("ms") if res else None,
                total_ms,
                bool(res and res.get("from_cache")),
                res.get("ai_calls") if res else None,
                res.get("model") if res else None,
                res.get("in_tok") if res else None,
                res.get("out_tok") if res else None,
                bool(res and res.get("retried")),
                (error or (res or {}).get("error") or None),
            ),
        )
        log_id = int(row[0][0])

        for code in codes:
            db_exec("EXEC genbi.sp_log_query_rule ?, ?", (log_id, code))

        return log_id

    except Exception as e:
        print("Could not write the query log:", e)
        return None


def answer_and_log(question, agent_name, agent):
    """answer() plus the log, including questions stopped by a guardrail or an AI failure."""
    t0 = time.time()

    try:
        res = answer(question, agent_name, agent)
    except GuardrailError as e:
        log_query(agent_name, question, outcome="guardrail", error=str(e)[:600],
                  total_ms=int((time.time() - t0) * 1000))
        raise
    except Exception as e:
        log_query(agent_name, question, outcome="ai_error", error=str(e)[:600],
                  total_ms=int((time.time() - t0) * 1000))
        raise

    res["log_id"] = log_query(agent_name, question, res,
                              total_ms=int((time.time() - t0) * 1000))
    return res


# ------------------------------------------------------------------
# Feedback (Phase 10)
# ------------------------------------------------------------------
FALLBACK_REASONS = [("other", "Something else (please add a comment)")]


def get_reasons():
    try:
        rows = db_read("SELECT reason_code, description FROM genbi.feedback_reason ORDER BY sort_order")
        return [(r[0], r[1]) for r in rows] or FALLBACK_REASONS
    except Exception:
        return FALLBACK_REASONS


def submit_feedback(log_id, rating, reason=None, comment=None, cache_key=None):
    """Save the rating. A thumbs-down also removes the answer from the cache."""
    db_exec(
        "EXEC genbi.sp_submit_feedback ?, ?, ?, ?",
        (log_id, rating, reason if rating == "down" else None, (comment or "").strip()[:500] or None),
    )
    if rating == "down" and cache_key:
        try:
            db_exec("EXEC genbi.sp_cache_evict ?", (cache_key,))
        except Exception as e:
            print("Could not evict the cache entry:", e)


def feedback_box(res):
    log_id = res.get("log_id")
    if not log_id:
        return                                   # the question was not logged, so it cannot be rated

    done_key = f"fb_done_{log_id}"
    if st.session_state.get(done_key):
        st.success(f"Thanks, your feedback is saved (Log #{log_id}): {st.session_state[done_key]}")
        return

    reasons = get_reasons()
    labels = dict(reasons)

    with st.form(f"fb_form_{log_id}"):
        st.write("**Was this answer right?**")
        rating = st.radio(
            "Rating", ["Helpful", "Not right"], horizontal=True, label_visibility="collapsed"
        )
        reason = st.selectbox(
            "If not right, why?", [r[0] for r in reasons], format_func=lambda c: labels[c]
        )
        comment = st.text_input("Comment (optional)", max_chars=500)
        sent = st.form_submit_button("Send feedback")

    if sent:
        try:
            submit_feedback(
                log_id,
                "up" if rating == "Helpful" else "down",
                reason,
                comment,
                res.get("cache_key"),
            )
            st.session_state[done_key] = "Helpful" if rating == "Helpful" else "Not right: " + labels[reason]
            st.rerun()
        except Exception as e:
            st.error("Could not save the feedback: " + str(e)[:300])


# ------------------------------------------------------------------
# Screen
# ------------------------------------------------------------------
def show(res):
    beh = res["behavior"]

    box = (
        st.success if beh == "Answer"
        else st.info if beh == "Answer with stated assumption"
        else st.warning
    )

    box(f"**{beh}**  {res['note']}")

    chk = res.get("check")

    if chk and chk["verdict"] == "BLOCKED":
        st.error("**Blocked by the SQL validator.** The query was not run.")

    if chk and chk["issues"]:
        with st.expander(
            f"SQL validator: {chk['verdict']}",
            expanded=chk["verdict"] == "BLOCKED",
        ):
            for i in chk["issues"]:
                st.write(f"**{i['code']}** ({i['severity']}): {i['message']}")
    elif chk:
        st.caption("SQL validator: PASS")

    if res["error"]:
        st.error(
            "The query could not run: " + res["error"]
        )

    if res["df"] is not None:
        df = res["df"]
        st.dataframe(df, use_container_width=True)

        if res.get("truncated"):
            st.caption(
                f"Showing the first {res.get('max_rows', MAX_ROWS)} rows only (row limit)."
            )

        if (
            df.shape[1] == 2
            and 1 < len(df) <= 50
            and pd.api.types.is_numeric_dtype(df.iloc[:, 1])
        ):
            st.bar_chart(df.set_index(df.columns[0]))

        st.caption(
            f"{len(df)} row(s) in {res['ms']} ms"
            + (
                "  |  retried once after a timeout (cold cache)"
                if res.get("retried") else ""
            )
        )

    if res["sql"]:
        with st.expander(
            "SQL that was blocked"
            if chk and chk["verdict"] == "BLOCKED" else "SQL used"
        ):
            st.code(res["sql"], language="sql")

    if beh == "Unreadable" and res.get("raw"):
        with st.expander("Raw model reply (for debugging)"):
            st.code(res["raw"])

    if res.get("tried"):
        with st.expander("Other models tried first"):
            for t in res["tried"]:
                st.write(t)

    if res.get("log_id"):
        st.caption(f"Log #{res['log_id']}")

    if res.get("from_cache"):
        st.caption(
            "Answered from cache: 0 AI calls used. The SQL was validated and run again on live data."
        )
    else:
        st.caption(
            f"{res.get('label')}  |  AI calls used: {res.get('ai_calls', 0)}  |  "
            f"tokens in {res['in_tok']}, out {res['out_tok']}  |  "
            f"prompt {res['prompt_chars']:,} characters"
        )

    feedback_box(res)


# ------------------------------------------------------------------
# App
# ------------------------------------------------------------------
def main():
    st.set_page_config(
        page_title="GenBI", layout="wide"
    )
    st.title("Ask your data")

    if not CONN_STR:
        st.error(
            "The environment variable GENBI_CONN is not set. "
            "See the setup steps."
        )
        st.stop()

    if not os.environ.get("GEMINI_API_KEY"):
        st.error(
            "The environment variable GEMINI_API_KEY is not set. "
            "Set it in this terminal and restart the app."
        )
        st.stop()

    try:
        agents = get_agents()
    except Exception as e:
        st.error(
            "Cannot read genbi.agent from SQL Server: "
            + str(e)[:400]
        )
        st.stop()

    with st.sidebar:
        st.caption("AI provider: Google Gemini API")
        st.caption(
            "Model: " + (GEMINI_MODEL or "default")
        )

        try:
            used, daily = budget_today()
            st.progress(min(used / daily, 1.0) if daily else 1.0)
            st.caption(f"AI calls today: {used} / {daily}")
        except Exception:
            st.caption("Budget not available (run phase8_cost_guardrails.sql)")

        with st.expander("Recent questions"):
            try:
                recent = db_read(
                    "SELECT TOP (8) asked_at, agent_name, outcome, question "
                    "FROM genbi.vw_query_log_recent"
                )
                for r in recent:
                    st.caption(f"{r[0]:%H:%M}  {r[1]}  [{r[2]}]  {r[3][:60]}")
                if not recent:
                    st.caption("Nothing logged yet.")
            except Exception:
                st.caption("Log not available (run phase9_query_logging.sql)")

        agent_name = st.selectbox(
            "Agent",
            list(agents),
            format_func=lambda a: (
                f"{a}: {agents[a]['description']}"
            ),
        )

        views = [
            r[0]
            for r in db_read(
                "SELECT view_name FROM genbi.agent_view_access "
                "WHERE agent_name = ? ORDER BY view_name",
                (agent_name,),
            )
        ]

        st.caption(
            "Views this agent can read: "
            + ", ".join(views)
        )

        golden = db_read(
            "SELECT question, expected_behavior, expected_note "
            "FROM genbi.golden_question "
            "WHERE agent_name = ? AND is_active = 1 "
            "ORDER BY golden_id",
            (agent_name,),
        )

        picked = st.selectbox(
            "Or try a golden question",
            [""] + [g[0] for g in golden],
        )

        if picked:
            g = next(x for x in golden if x[0] == picked)
            st.caption(
                f"Expected behavior: **{g[1]}**"
                + (f"  \n{g[2]}" if g[2] else "")
            )

    question = st.text_input(
        "Ask a business question",
        value=picked,
        key=f"q_{agent_name}_{picked}",
        placeholder="e.g. What were total sales last month?",
    )

    if st.button("Ask", type="primary") and question.strip():
        with st.spinner("Working..."):
            try:
                st.session_state["res"] = answer_and_log(
                    question.strip(),
                    agent_name,
                    agents[agent_name],
                )

            except GuardrailError as e:
                st.session_state["res"] = None
                st.warning("Stopped by a cost guardrail: " + str(e))

            except Exception as e:
                st.session_state["res"] = None
                msg = str(e)[:700]

                if "429" in msg or "RESOURCE_EXHAUSTED" in msg:
                    msg += (
                        "  -> Gemini quota or rate limit reached. "
                        "Check your API quota and try again later."
                    )

                if "API_KEY_INVALID" in msg or "API key not valid" in msg:
                    msg += (
                        "  -> Check that GEMINI_API_KEY is correct "
                        "and enabled for the Gemini API."
                    )

                st.error(
                    "Something failed before the query ran: " + msg
                )

    if st.session_state.get("res"):
        show(st.session_state["res"])


if __name__ == "__main__":
    main()
