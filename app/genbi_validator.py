"""
GenBI - PHASE 7 : SQL validator (layer 1, text rules).

A pure function with no database and no extra packages, so it can be tested anywhere:

    python genbi_validator.py          -> runs the built-in self tests

validate_sql(sql, allowed_views) -> {"verdict": PASS | PASS WITH WARNINGS | BLOCKED,
                                     "issues":  [{"code", "severity", "message"}, ...]}

Layer 2 (does the SQL really compile for this agent?) is genbi.sp_dry_run in SQL Server.
Layer 3 (the database permissions of the agent user) was built in Phase 4 and stays the final wall.
"""
import re

MAX_SQL_CHARS = 4000

# code -> (severity, short description). The same list is written to SQL Server (genbi.sql_rule).
RULES = {
    "V01": ("BLOCK", "SQL is empty or longer than the allowed size"),
    "V02": ("BLOCK", "Query must start with SELECT or WITH"),
    "V03": ("BLOCK", "Only one statement is allowed"),
    "V04": ("BLOCK", "Comments are not allowed in generated SQL"),
    "V05": ("BLOCK", "Forbidden keyword (data change, DDL, EXEC, permissions, external access)"),
    "V06": ("BLOCK", "Object is not one of the views this agent may use (write it as semantic.<view>)"),
    "V07": ("WARN",  "SELECT * used; list the columns instead"),
    "V08": ("BLOCK", "Current-date function used; relative dates must come from semantic.vw_data_range"),
    "V09": ("WARN",  "TOP without ORDER BY gives a different result on each run"),
    "V10": ("BLOCK", "Unbalanced quote in the SQL text"),
    "V11": ("BLOCK", "SQL Server dry run failed (does not compile for this agent)"),
}

FORBIDDEN = (
    "insert", "update", "delete", "merge", "drop", "alter", "create", "truncate",
    "exec", "execute", "grant", "revoke", "deny", "backup", "restore", "shutdown",
    "kill", "dbcc", "use", "declare", "into", "openrowset", "openquery",
    "opendatasource", "bulk", "waitfor", "reconfigure", "print", "raiserror", "throw",
)
FORBIDDEN_RE = re.compile(r"\b(" + "|".join(FORBIDDEN) + r")\b|\b(?:xp|sp)_\w+", re.I)
NOW_RE = re.compile(r"\b(getdate|getutcdate|sysdatetime|sysutcdatetime|sysdatetimeoffset|current_timestamp)\b", re.I)
STAR_RE = re.compile(r"(?:\bselect|,)\s*(?:distinct\s+)?(?:top\s*\(?\s*\d+\s*\)?\s+)?(?:\w+\.)?\*", re.I)
OBJECT_RE = re.compile(r"\b(?:from|join)\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*){0,2})", re.I)
CTE_RE = re.compile(r"(?:\bwith|,)\s*([A-Za-z_]\w*)\s*(?:\([^)]*\)\s*)?as\s*\(", re.I)


def _issue(code, detail=""):
    sev, title = RULES[code]
    return {"code": code, "severity": sev, "message": title + (": " + detail if detail else "")}


def _norm_view(name):
    """'vw_sales' -> 'semantic.vw_sales'; '[semantic].[vw_sales]' -> 'semantic.vw_sales'."""
    n = name.replace("[", "").replace("]", "").strip().lower()
    return n if "." in n else "semantic." + n


def validate_sql(sql, allowed_views):
    issues = []
    text = sql if isinstance(sql, str) else ""

    if not text.strip() or len(text) > MAX_SQL_CHARS:
        return _result([_issue("V01", f"{len(text)} characters")])

    masked = re.sub(r"'(?:[^']|'')*'", "__STR__", text)      # hide string contents: 'DROP' is just text
    if "'" in masked:
        return _result([_issue("V10")])

    body = masked.strip()
    if "--" in body or "/*" in body or "*/" in body:
        issues.append(_issue("V04"))

    if not re.match(r"(?is)^\s*\(*\s*(select|with)\b", body):
        issues.append(_issue("V02"))

    if ";" in body.rstrip().rstrip(";"):
        issues.append(_issue("V03"))

    hits = sorted({(m.group(1) or m.group(0)).lower() for m in FORBIDDEN_RE.finditer(body)})
    if hits:
        issues.append(_issue("V05", ", ".join(hits)))

    allowed = {_norm_view(v) for v in allowed_views}
    ctes = {c.lower() for c in CTE_RE.findall(body)}
    bad = []
    for obj in OBJECT_RE.findall(body.replace("[", "").replace("]", "")):
        o = obj.lower()
        if o in ctes:
            continue
        if o not in allowed:
            bad.append(obj)
    if bad:
        issues.append(_issue("V06", ", ".join(sorted(set(bad))) + ". Allowed: " + ", ".join(sorted(allowed))))

    if STAR_RE.search(body):
        issues.append(_issue("V07"))

    if NOW_RE.search(body):
        issues.append(_issue("V08"))

    if re.search(r"\btop\b", body, re.I) and not re.search(r"\border\s+by\b", body, re.I):
        issues.append(_issue("V09"))

    return _result(issues)


def _result(issues):
    if any(i["severity"] == "BLOCK" for i in issues):
        verdict = "BLOCKED"
    elif issues:
        verdict = "PASS WITH WARNINGS"
    else:
        verdict = "PASS"
    return {"verdict": verdict, "issues": issues}


def add_dry_run_failure(result, error_text):
    """Add rule V11 (SQL Server could not compile the query for this agent)."""
    result["issues"].append(_issue("V11", str(error_text)[:300]))
    result["verdict"] = "BLOCKED"
    return result


# ------------------------------------------------------------------ self tests
def _selftest():
    allowed = ["semantic.vw_sales", "vw_monthly_sales", "semantic.vw_data_range"]
    cases = [
        # (name, sql, expected verdict, expected codes that must be present)
        ("simple total", "SELECT SUM(sales_amount) AS total_sales FROM semantic.vw_sales", "PASS", []),
        ("trailing semicolon ok", "SELECT 1 AS x FROM semantic.vw_data_range;", "PASS", []),
        ("unqualified view name", "SELECT sales_month FROM vw_monthly_sales", "BLOCKED", ["V06"]),
        ("brackets", "SELECT m.total_sales FROM [semantic].[vw_monthly_sales] m", "PASS", []),
        ("join + subquery", "SELECT SUM(s.sales_amount) AS t FROM semantic.vw_sales s CROSS JOIN semantic.vw_data_range d "
                            "WHERE s.order_date >= DATEADD(MONTH,-1,d.latest_month)", "PASS", []),
        ("cte", "WITH c AS (SELECT order_date FROM semantic.vw_sales) SELECT COUNT(*) AS n FROM c", "PASS", []),
        ("two ctes", "WITH a AS (SELECT 1 AS x FROM semantic.vw_data_range), b AS (SELECT x FROM a) SELECT x FROM b", "PASS", []),
        ("count star is fine", "SELECT COUNT(*) AS n FROM semantic.vw_sales", "PASS", []),
        ("keyword inside string", "SELECT 1 AS x FROM semantic.vw_sales WHERE product_name = 'DROP TABLE; --'", "PASS", []),
        ("column like update_date", "SELECT update_date FROM semantic.vw_sales", "PASS", []),
        ("top with order", "SELECT TOP 5 order_date FROM semantic.vw_sales ORDER BY order_date DESC", "PASS", []),
        ("escaped quote", "SELECT 1 AS x FROM semantic.vw_sales WHERE c = 'it''s'", "PASS", []),

        ("select star", "SELECT * FROM semantic.vw_sales", "PASS WITH WARNINGS", ["V07"]),
        ("alias star", "SELECT s.* FROM semantic.vw_sales s", "PASS WITH WARNINGS", ["V07"]),
        ("top no order", "SELECT TOP 5 order_date FROM semantic.vw_sales", "PASS WITH WARNINGS", ["V09"]),

        ("empty", "", "BLOCKED", ["V01"]),
        ("none", None, "BLOCKED", ["V01"]),
        ("too long", "SELECT 1 " + "x" * 5000, "BLOCKED", ["V01"]),
        ("not select", "DROP TABLE gold.fact_sales", "BLOCKED", ["V02", "V05"]),
        ("two statements", "SELECT 1 AS x FROM semantic.vw_data_range; DROP TABLE gold.fact_sales", "BLOCKED", ["V03", "V05"]),
        ("comment dash", "SELECT 1 AS x FROM semantic.vw_data_range -- hi", "BLOCKED", ["V04"]),
        ("comment block", "SELECT 1 /* hi */ AS x FROM semantic.vw_data_range", "BLOCKED", ["V04"]),
        ("exec", "SELECT 1; EXEC xp_cmdshell 'dir'", "BLOCKED", ["V05"]),
        ("select into", "SELECT * INTO #t FROM semantic.vw_sales", "BLOCKED", ["V05"]),
        ("openrowset", "SELECT a FROM OPENROWSET('x','y','z')", "BLOCKED", ["V05"]),
        ("gold table", "SELECT * FROM gold.fact_sales", "BLOCKED", ["V06"]),
        ("sys table", "SELECT name FROM sys.objects", "BLOCKED", ["V06"]),
        ("other agent's view", "SELECT customer_key FROM semantic.vw_customer_metrics", "BLOCKED", ["V06"]),
        ("join to bad table", "SELECT 1 AS x FROM semantic.vw_sales s JOIN gold.dim_customers c ON 1=1", "BLOCKED", ["V06"]),
        ("getdate", "SELECT GETDATE() AS now_ FROM semantic.vw_data_range", "BLOCKED", ["V08"]),
        ("sysdatetime", "SELECT 1 AS x FROM semantic.vw_sales WHERE order_date < SYSDATETIME()", "BLOCKED", ["V08"]),
        ("unbalanced quote", "SELECT 1 AS x FROM semantic.vw_sales WHERE a = 'oops", "BLOCKED", ["V10"]),
        ("stacked with comment trick", "SELECT 1 AS x FROM semantic.vw_data_range;--", "BLOCKED", ["V04"]),
    ]
    failed = 0
    for name, sql, want_verdict, want_codes in cases:
        r = validate_sql(sql, allowed)
        got = {i["code"] for i in r["issues"]}
        ok = r["verdict"] == want_verdict and set(want_codes) <= got
        failed += not ok
        print(("OK   " if ok else "FAIL ") + f"{name:28s} -> {r['verdict']:20s} {sorted(got)}")
    print(f"\n{len(cases) - failed}/{len(cases)} passed")
    return failed


if __name__ == "__main__":
    raise SystemExit(1 if _selftest() else 0)