"""
GenBI - PHASE 11 : evaluation runner.

Sends every active + approved golden question through the REAL pipeline
(guardrails -> cache -> Gemini -> SQL validator -> SQL as the agent user) and scores the reply
against your answer key. Results go to genbi.eval_run / genbi.eval_result.

Usage (same terminal as the app: GENBI_CONN and GEMINI_API_KEY must be set)

    python genbi_eval.py --selftest                 # no database, no AI: tests the scoring logic
    python genbi_eval.py --label baseline           # start a new run
    python genbi_eval.py --label baseline --limit 15            # only 15 questions this session
    python genbi_eval.py --run-id 3                 # resume run 3: only questions it does not have yet
    python genbi_eval.py --label x --agent sales_agent          # one agent only
    python genbi_eval.py --label x --fresh          # ignore the answer cache (fresh AI replies)

A question PASSES when:
    behavior is right  (Answer and Answer-with-assumption count as the same family)
    AND, if an answer was expected, the returned numbers match the stored snapshot
         (genbi.golden_question.expected_result_json): same rows, any order, numbers rounded to 2 decimals,
         extra columns are allowed.
Questions that should not be answered (Clarify / Decline / Redirect) must match the behavior exactly.
"""
import argparse
import hashlib
import json
import re
import sys
import time
from collections import Counter
from datetime import date, datetime
from decimal import Decimal, ROUND_HALF_UP, InvalidOperation

ANSWERABLE = ("Answer", "Answer with stated assumption")
CENT = Decimal("0.01")
DATE_ONLY = re.compile(r"^(\d{4}-\d{2}-\d{2})(?:[T ]00:00:00(?:\.0+)?)?$")


# ------------------------------------------------------------------ comparing results (pure functions)
def norm(v):
    """Make a database value comparable: numbers to 2 decimals, dates to text, text trimmed."""
    if hasattr(v, "item") and not isinstance(v, (str, bytes)):      # numpy scalars
        try:
            v = v.item()
        except Exception:
            pass
    if v is None:
        return None
    if isinstance(v, bool):
        return Decimal(int(v)).quantize(CENT)
    if isinstance(v, (int, float, Decimal)):
        try:
            d = Decimal(str(v))
        except InvalidOperation:
            return None
        if d.is_nan():
            return None
        return d.quantize(CENT, rounding=ROUND_HALF_UP)
    if isinstance(v, datetime):
        return v.date().isoformat() if v.time() == datetime.min.time() else v.isoformat()
    if isinstance(v, date):
        return v.isoformat()
    s = str(v).strip()
    m = DATE_ONLY.match(s)
    return m.group(1) if m else s


def _col_key(col):
    return tuple(sorted((repr(x) for x in col)))


def compare_results(expected_rows, got_rows):
    """
    expected_rows: list of dicts (parsed expected_result_json) or [] for an empty answer
    got_rows:      list of tuples (what the AI's SQL returned)
    Returns (ok, detail).
    """
    # FOR JSON leaves out NULL values, so a row can have fewer keys than the others
    # (e.g. the first month has no growth). Rebuild every row with the same columns.
    keys = []
    for row in expected_rows:
        for k in row:
            if k not in keys:
                keys.append(k)
    exp = [tuple(norm(row.get(k)) for k in keys) for row in expected_rows]
    got = [tuple(norm(v) for v in row) for row in got_rows]

    if len(exp) != len(got):
        return False, f"rows: expected {len(exp)}, got {len(got)}"
    if not exp:
        return True, "both empty"

    ew, gw = len(exp[0]), len(got[0])

    if gw < ew:
        return False, f"columns: expected {ew}, got {gw}"

    if gw == ew:
        if Counter(exp) == Counter(got):
            return True, ("same rows, same order" if exp == got else "same rows, different order")
        return False, _first_difference(exp, got)

    # the AI returned extra columns: find, for every expected column, a got column with the same values
    exp_cols = list(zip(*exp))
    got_cols = list(zip(*got))
    used, picks = set(), []
    for ec in exp_cols:
        target = _col_key(ec)
        hit = next((i for i, gc in enumerate(got_cols) if i not in used and _col_key(gc) == target), None)
        if hit is None:
            return False, f"values differ (AI returned {gw} columns, expected {ew}): {_first_difference(exp, got)}"
        used.add(hit)
        picks.append(hit)

    projected = [tuple(r[i] for i in picks) for r in got]
    if Counter(exp) == Counter(projected):
        return True, f"match, {gw - ew} extra column(s) ignored"
    return False, "columns have the right values but the rows do not line up"


def _first_difference(exp, got):
    only_exp = list((Counter(exp) - Counter(got)).elements())
    only_got = list((Counter(got) - Counter(exp)).elements())
    e = tuple(str(x) for x in only_exp[0]) if only_exp else "-"
    g = tuple(str(x) for x in only_got[0]) if only_got else "-"
    return f"values differ: expected {e} but got {g}"[:300]


def parse_expected(g):
    """Golden row (dict) -> list of dict rows, or None when the answer key is missing."""
    raw = g.get("expected_result_json")
    if raw:
        data = json.loads(raw)
        return data if isinstance(data, list) else None
    if g.get("expected_row_count") == 0:
        return []                                  # FOR JSON gives NULL for an empty result
    return None


# ------------------------------------------------------------------ scoring one question
def score(g, res=None, exc=None):
    """
    g   golden question dict: expected_behavior, expected_result_json, expected_row_count
    res the app's answer() result dict, or None when answer() raised
    exc the exception when answer() raised
    Returns a dict ready for genbi.sp_eval_save.
    """
    expected = g["expected_behavior"]
    exp_answerable = expected in ANSWERABLE
    exp_rows = None

    out = dict(
        expected_behavior=expected, got_behavior=None, behavior_ok=False, behavior_family_ok=False,
        assumption_ok=None, result_ok=None, passed=False, failure_type="none", detail=None,
        expected_rows=g.get("expected_row_count"), got_rows=None, got_sql=None, got_note=None,
        validator_verdict=None, rule_codes=None, model=None, ai_calls=None, from_cache=False,
        in_tokens=None, out_tokens=None, run_ms=None,
    )
    if exp_answerable:
        out["result_ok"] = False

    if exc is not None:
        gname = type(exc).__name__
        out["failure_type"] = "guardrail" if gname == "GuardrailError" else "ai_error"
        out["detail"] = str(exc)[:400]
        return out

    got = res["behavior"]
    chk = res.get("check")
    out.update(
        got_behavior=got, got_sql=res.get("sql"), got_note=res.get("note"),
        validator_verdict=chk["verdict"] if chk else None,
        rule_codes=",".join(i["code"] for i in chk["issues"]) if chk and chk["issues"] else None,
        model=res.get("model"), ai_calls=res.get("ai_calls"), from_cache=bool(res.get("from_cache")),
        in_tokens=res.get("in_tok"), out_tokens=res.get("out_tok"), run_ms=res.get("ms"),
    )
    out["behavior_ok"] = got == expected
    out["behavior_family_ok"] = got == expected or (got in ANSWERABLE and exp_answerable)
    if expected == "Answer with stated assumption":
        out["assumption_ok"] = got == "Answer with stated assumption"

    df = res.get("df")
    if df is not None:
        out["got_rows"] = len(df)

    if got == "Unreadable":
        out["failure_type"], out["detail"] = "unreadable", "The AI reply was not valid JSON"
        return out

    if not exp_answerable:
        out["passed"] = out["behavior_ok"]
        if not out["passed"]:
            out["failure_type"] = "wrong_behavior"
            out["detail"] = f"expected {expected}, got {got}"
        return out

    # an answer was expected
    if got not in ANSWERABLE:
        out["failure_type"], out["detail"] = "wrong_behavior", f"expected {expected}, got {got}"
        return out
    if chk and chk["verdict"] == "BLOCKED":
        out["failure_type"] = "blocked"
        out["detail"] = "validator: " + " | ".join(
            i["message"] for i in chk["issues"] if i["severity"] == "BLOCK")[:390]      # includes the SQL Server error for V11
        return out
    if res.get("error"):
        out["failure_type"], out["detail"] = "sql_error", str(res["error"])[:400]
        return out

    exp_rows = parse_expected(g)
    if exp_rows is None:
        out["failure_type"], out["detail"] = "wrong_result", "the golden question has no answer key (snapshot)"
        return out

    got_rows = [tuple(r) for r in df.itertuples(index=False, name=None)] if df is not None else []
    ok, detail = compare_results(exp_rows, got_rows)
    out["result_ok"], out["detail"] = ok, detail
    if not ok:
        out["failure_type"] = "wrong_result"
    out["passed"] = bool(out["behavior_family_ok"] and ok)
    return out


# ------------------------------------------------------------------ the runner
def is_rate_limit(e):
    t = str(e)
    return "429" in t or "RESOURCE_EXHAUSTED" in t


def main():
    ap = argparse.ArgumentParser(description="Evaluate GenBI against the golden questions.")
    ap.add_argument("--label", help="name of a NEW run, e.g. baseline")
    ap.add_argument("--run-id", type=int, help="resume an existing run")
    ap.add_argument("--limit", type=int, help="evaluate at most N questions in this session")
    ap.add_argument("--agent", help="only this agent")
    ap.add_argument("--fresh", action="store_true", help="do not use the answer cache")
    ap.add_argument("--pause", type=float, default=4.0, help="seconds to wait after each AI call (rate limit)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.label and not args.run_id:
        ap.error("give --label for a new run or --run-id to resume one")

    import genbi_app as app             # imported here so --selftest needs no libraries

    agents = app.get_agents()
    limits = app.get_limits()

    where = "is_active = 1 AND review_status = 'Approved'" + (" AND agent_name = ?" if args.agent else "")
    rows = app.db_read(
        "SELECT golden_id, agent_name, question, expected_behavior, expected_row_count, expected_result_json, "
        "question_type, difficulty FROM genbi.golden_question WHERE " + where + " ORDER BY golden_id",
        (args.agent,) if args.agent else (),
    )
    cols = ["golden_id", "agent_name", "question", "expected_behavior", "expected_row_count",
            "expected_result_json", "question_type", "difficulty"]
    golden = [dict(zip(cols, r)) for r in rows]
    if not golden:
        print("No active, approved golden questions found.")
        return 1

    missing = [g["golden_id"] for g in golden
               if g["expected_behavior"] in ANSWERABLE and parse_expected(g) is None]
    if missing:
        print(f"{len(missing)} answerable golden question(s) have no answer key (ids {missing[:10]}).")
        print("Run:  EXEC genbi.sp_validate_golden @create_snapshot = 1;   in SSMS, then try again.")
        return 1

    # ---- the run
    if args.run_id:
        run_id = args.run_id
        if not app.db_read("SELECT 1 FROM genbi.eval_run WHERE run_id = ?", (run_id,)):
            print(f"Run {run_id} does not exist.")
            return 1
        done = {r[0] for r in app.db_read("SELECT golden_id FROM genbi.eval_result WHERE run_id = ?", (run_id,))}
    else:
        h = hashlib.sha256()
        for name in sorted(agents):
            h.update(app.build_prompt(name).encode("utf-8"))
        run_id = int(app.db_read("EXEC genbi.sp_eval_start ?, ?, ?",
                                 (args.label, h.hexdigest(), "fresh" if args.fresh else None))[0][0])
        done = set()

    todo = [g for g in golden if g["golden_id"] not in done]
    if args.limit:
        todo = todo[: args.limit]

    used, daily = app.budget_today()
    print(f"Run {run_id}: {len(golden)} questions, {len(done)} already done, {len(todo)} to do this session.")
    print(f"AI calls today: {used} / {daily}. Roughly one call per question that is not cached.")
    if daily - used < len(todo):
        print("Note: the daily budget may stop this session early. Resume later with --run-id", run_id)
    print()

    passed = failed = 0
    for n, g in enumerate(todo, 1):
        agent = agents.get(g["agent_name"])
        if not agent:
            print(f"[{n}/{len(todo)}] skipped (agent {g['agent_name']} is not active)")
            continue

        res = exc = None
        t0 = time.time()
        for attempt in (1, 2):
            try:
                res = app.answer(g["question"], g["agent_name"], agent, use_cache=not args.fresh)
                exc = None
                break
            except app.GuardrailError as e:
                if "Daily AI call budget" in str(e):
                    print(f"\nStopped: {e}")
                    print(f"{passed + failed} questions scored this session. Resume with:  python genbi_eval.py --run-id {run_id}")
                    return finish(app, run_id)
                exc = e
                break
            except Exception as e:
                if is_rate_limit(e) and attempt == 1:
                    print("   rate limit reached, waiting 60 s ...")
                    time.sleep(60)
                    continue
                if is_rate_limit(e):
                    print(f"\nStopped: the AI is rate-limiting. {passed + failed} scored. Resume with --run-id {run_id}")
                    return finish(app, run_id)
                exc = e
                break
        total_ms = int((time.time() - t0) * 1000)

        s = score(g, res, exc)
        app.db_exec(
            "EXEC genbi.sp_eval_save ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?",
            (run_id, g["golden_id"], s["expected_behavior"], s["got_behavior"], s["behavior_ok"],
             s["behavior_family_ok"], s["assumption_ok"], s["result_ok"], s["passed"], s["failure_type"],
             s["detail"], s["expected_rows"], s["got_rows"], s["got_sql"], s["got_note"],
             s["validator_verdict"], s["rule_codes"], s["model"], s["ai_calls"], s["from_cache"],
             s["in_tokens"], s["out_tokens"], s["run_ms"], total_ms),
        )

        if s["passed"]:
            passed += 1
        else:
            failed += 1
            if res and res.get("cache_key"):           # do not keep serving a wrong answer from the cache
                try:
                    app.db_exec("EXEC genbi.sp_cache_evict ?", (res["cache_key"],))
                except Exception:
                    pass

        mark = "PASS" if s["passed"] else "FAIL"
        extra = "" if s["passed"] else f"  [{s['failure_type']}] {s['detail'] or ''}"
        print(f"[{n}/{len(todo)}] {mark}  #{g['golden_id']} {g['agent_name']}: {g['question'][:60]}{extra}")

        if res is not None and not res.get("from_cache") and args.pause > 0:
            time.sleep(args.pause)                       # stay under the free-tier requests-per-minute limit

    print(f"\nThis session: {passed} passed, {failed} failed.")
    return finish(app, run_id)


def finish(app, run_id):
    row = app.db_read("EXEC genbi.sp_eval_finish ?", (run_id,))[0]
    print(f"\nRun {run_id} is {row[3]}: {row[5]}/{row[4]} questions passed ({row[6]}%)  |  "
          f"behavior ok {row[7]}%  |  result ok {row[8]}%")
    print("Details in SSMS:  SELECT * FROM genbi.vw_eval_failures WHERE run_id = " + str(run_id) + ";")
    return 0


# ------------------------------------------------------------------ self test (no database, no AI)
class _Df:
    def __init__(self, rows):
        self._rows = rows

    def __len__(self):
        return len(self._rows)

    def itertuples(self, index=False, name=None):
        return iter(self._rows)


def selftest():
    from datetime import date, datetime
    E = lambda *rows: [dict(zip("abc", r)) for r in rows]
    cases = [
        # (name, expected, got, want_ok)
        ("same single number",              E((29356250,)), [(29356250,)],                    True),
        ("int vs decimal vs float",         E((29356250,)), [(Decimal("29356250.00"),)],      True),
        ("float rounding",                  E((1061.36,)),  [(1061.3612,)],                   True),
        ("different number",                E((29356250,)), [(9084294,)],                     False),
        ("order does not matter",           E(("A", 1), ("B", 2)), [("B", 2), ("A", 1)],      True),
        ("missing row",                     E(("A", 1), ("B", 2)), [("A", 1)],                False),
        ("wrong value in a row",            E(("A", 1), ("B", 2)), [("A", 1), ("B", 3)],      False),
        ("extra column ignored",            E(("A", 1), ("B", 2)), [("A", "x", 1), ("B", "y", 2)], True),
        ("extra column in front",           E(("A", 1), ("B", 2)), [(99, "A", 1), (98, "B", 2)],   True),
        ("fewer columns",                   E(("A", 1)),    [("A",)],                         False),
        ("date text vs date",               E(("2013-12-01T00:00:00", 5)), [(date(2013, 12, 1), 5)], True),
        ("datetime midnight vs date text",  E(("2013-12-01", 5)), [(datetime(2013, 12, 1), 5)], True),
        ("text trimmed",                    E((" Bikes ", 1)), [("Bikes", 1)],               True),
        ("text is case sensitive",          E(("Bikes", 1)), [("bikes", 1)],                  False),
        ("None matches None",               E((None, 1)),   [(None, 1)],                      True),
        ("empty vs empty",                  [],             [],                               True),
        ("empty vs rows",                   [],             [(1,)],                           False),
        ("duplicate rows are counted",      E(("A", 1), ("A", 1)), [("A", 1)],                False),
        ("NULL left out of the answer key (FOR JSON)", [{"a": "A", "b": 1}, {"a": "B", "b": 2, "c": 5}],
                                            [("A", 1, None), ("B", 2, 5)],                   True),
        ("columns right but misaligned",    E(("A", 1), ("B", 2)), [("A", "p", 2), ("B", "q", 1)], False),
    ]
    bad = 0
    for name, exp, got, want in cases:
        ok, detail = compare_results(exp, got)
        good = ok == want
        bad += not good
        print(("OK   " if good else "FAIL ") + f"{name:34s} ok={ok!s:5s} {detail}")

    G = lambda beh, rows=None, rc=None: dict(
        expected_behavior=beh, expected_result_json=json.dumps(rows) if rows is not None else None,
        expected_row_count=rc)
    R = lambda beh, rows=None, **kw: dict(
        behavior=beh, sql="SELECT 1" if beh in ANSWERABLE else None, note="n",
        df=_Df(rows) if rows is not None else None, error=kw.get("error"), check=kw.get("check"),
        model="m", ai_calls=1, from_cache=False, in_tok=1, out_tok=1, ms=5)
    PASS = {"verdict": "PASS", "issues": []}
    BLOCK = {"verdict": "BLOCKED", "issues": [{"code": "V06", "severity": "BLOCK", "message": ""}]}

    sc = [
        ("answer ok",               G("Answer", [{"t": 5}]), R("Answer", [(5,)], check=PASS), None, True, "none"),
        ("answer, wrong number",    G("Answer", [{"t": 5}]), R("Answer", [(6,)], check=PASS), None, False, "wrong_result"),
        ("assumption expected, AI said Answer", G("Answer with stated assumption", [{"t": 5}]),
                                    R("Answer", [(5,)], check=PASS), None, True, "none"),
        ("answer expected, AI declined", G("Answer", [{"t": 5}]), R("Decline"), None, False, "wrong_behavior"),
        ("answer expected, blocked", G("Answer", [{"t": 5}]), R("Answer", None, check=BLOCK), None, False, "blocked"),
        ("answer expected, sql error", G("Answer", [{"t": 5}]), R("Answer", None, check=PASS, error="Invalid column"), None, False, "sql_error"),
        ("unreadable",              G("Answer", [{"t": 5}]), R("Unreadable"), None, False, "unreadable"),
        ("decline ok",              G("Decline"), R("Decline"), None, True, "none"),
        ("decline expected, redirect given", G("Decline"), R("Redirect"), None, False, "wrong_behavior"),
        ("decline expected, answered", G("Decline"), R("Answer", [(1,)], check=PASS), None, False, "wrong_behavior"),
        ("clarify ok",              G("Clarify"), R("Clarify"), None, True, "none"),
        ("empty answer key (0 rows)", G("Answer", None, 0), R("Answer", [], check=PASS), None, True, "none"),
        ("missing answer key",      G("Answer", None, 3), R("Answer", [(1,)], check=PASS), None, False, "wrong_result"),
        ("guardrail exception",     G("Answer", [{"t": 5}]), None, type("GuardrailError", (Exception,), {})("limit"), False, "guardrail"),
        ("ai exception",            G("Answer", [{"t": 5}]), None, RuntimeError("503"), False, "ai_error"),
    ]
    for name, g, r, exc, want_pass, want_type in sc:
        s = score(g, r, exc)
        good = s["passed"] == want_pass and s["failure_type"] == want_type
        bad += not good
        print(("OK   " if good else "FAIL ") + f"score: {name:38s} passed={s['passed']!s:5s} {s['failure_type']}")

    s = score(G("Answer with stated assumption", [{"t": 5}]), R("Answer", [(5,)], check=PASS))
    assert s["assumption_ok"] is False and s["behavior_ok"] is False and s["behavior_family_ok"] is True
    s = score(G("Answer", [{"t": 5}]), R("Answer", [(5,)], check=PASS))
    assert s["assumption_ok"] is None and s["result_ok"] is True

    total = len(cases) + len(sc)
    print(f"\n{total - bad}/{total} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())