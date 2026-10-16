"""Static checks for the GenBI SQL package (no database needed).
Run:  python tools/check_sql.py        (from the repository root)
Checks: GO handling, unterminated strings/comments, USE line, objects used before they are created,
        tests that reference objects built later than the step they test."""
import re, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMAS = ("genbi", "semantic", "gold", "silver", "bronze")
problems, warnings = [], []

def strip(text):
    """Return (code_without_comments_and_strings, errors)."""
    out, i, n, err = [], 0, len(text), []
    while i < n:
        c = text[i]
        if text.startswith("--", i):
            j = text.find("\n", i); i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0: err.append("unterminated /* comment"); break
            out.append(" " * 0); i = j + 2
        elif c == "'":
            j = i + 1
            while True:
                k = text.find("'", j)
                if k < 0: err.append("unterminated string starting: " + text[i:i+50].replace("\n", " ")); j = n; break
                if text.startswith("''", k): j = k + 2; continue
                j = k + 1; break
            out.append("''"); i = j
        else:
            out.append(c); i += 1
    return "".join(out), err

def batches(path):
    raw = open(path, encoding="utf-8-sig").read()
    res, cur, start, incomment = [], [], 1, False
    for no, line in enumerate(raw.splitlines(), 1):
        # GO only counts on its own line and outside block comments
        if not incomment and re.fullmatch(r"\s*GO\s*(--.*)?", line, re.I):
            res.append((start, "\n".join(cur))); cur, start = [], no + 1; continue
        cur.append(line)
        opens, closes = line.count("/*"), line.count("*/")
        if opens > closes: incomment = True
        elif closes > opens: incomment = False
    res.append((start, "\n".join(cur)))
    return raw, res

CREATE = re.compile(r"\bCREATE\s+(?:OR\s+ALTER\s+)?(TABLE|VIEW|PROCEDURE|PROC|FUNCTION|SCHEMA)\s+\[?(\w+)\]?(?:\.\[?(\w+)\]?)?", re.I)
SELECTINTO = re.compile(r"\bINTO\s+\[?(\w+)\]?\.\[?(\w+)\]?\s+FROM", re.I)
REF = re.compile(r"\b(?:FROM|JOIN|INTO|UPDATE|EXEC(?:UTE)?|TABLE|VIEW|PROC(?:EDURE)?)\s+\[?(genbi|semantic|gold|silver|bronze)\]?\.\[?(\w+)\]?", re.I)

def kind_name(m):
    k, a, b = m.groups()
    if k.upper() == "SCHEMA": return None
    return (a.lower(), b.lower()) if b else None

def stepno(p):
    m = re.match(r"[tT]?(\d+)_", os.path.basename(p)); return int(m.group(1)) if m else None

created = {}            # (schema,name) -> step number
step_files = sorted(glob.glob(os.path.join(ROOT, "sql", "build", "*.sql")))
test_files = sorted(glob.glob(os.path.join(ROOT, "sql", "tests", "*.sql")))
other_files = sorted(glob.glob(os.path.join(ROOT, "sql", "analysis", "*.sql")) + glob.glob(os.path.join(ROOT, "sql", "ops", "*.sql")))

# Names made by dynamic SQL (the Gold load procedure builds the physical tables); checked by hand
DYNAMIC = {("gold", t): 6 for t in ("dim_customers", "dim_products", "fact_sales")}

def scan(path, is_build):
    base = os.path.basename(path); n = stepno(path)
    raw, bs = batches(path)
    if not re.search(r"^\s*USE\s+\[?\w+\]?\s*;?", raw, re.I | re.M): problems.append(f"{base}: no USE statement")
    local_created = set()
    file_creates = {(kind_name(m)) for m in CREATE.finditer(strip(raw)[0]) if kind_name(m)}
    for start, b in bs:
        code, errs = strip(b)
        for e in errs: problems.append(f"{base} (batch at line {start}): {e}")
        if re.search(r"^\s*(CREATE\s+(OR\s+ALTER\s+)?(VIEW|PROC|PROCEDURE|FUNCTION))", code, re.I | re.M | re.S):
            first = re.search(r"\S", code)
            if first and not re.match(r"(CREATE|USE|SET|IF|DROP)\b", code[first.start():], re.I):
                problems.append(f"{base} (batch at line {start}): CREATE VIEW/PROC must be the first statement in its batch")
            if re.search(r"\bCREATE\s+(OR\s+ALTER\s+)?(VIEW|PROC|PROCEDURE|FUNCTION)\b", code, re.I) and len(re.findall(r"\bCREATE\s+(?:OR\s+ALTER\s+)?(?:VIEW|PROC|PROCEDURE|FUNCTION)\b", code, re.I)) > 1:
                problems.append(f"{base} (batch at line {start}): two CREATE VIEW/PROC in one batch (add GO)")
        # created in this batch (includes dynamic SQL text, visible because strings are stripped from `code` only)
        for m in CREATE.finditer(code):
            kn = kind_name(m)
            if kn and kn[0] in SCHEMAS: local_created.add(kn); 
            if kn and is_build: created.setdefault(kn, n)
        for m in CREATE.finditer(b):   # dynamic SQL inside strings
            kn = kind_name(m)
            if kn and kn[0] in SCHEMAS and is_build: created.setdefault(kn, n)
        for m in SELECTINTO.finditer(b):
            kn = (m.group(1).lower(), m.group(2).lower())
            if kn[0] in SCHEMAS and is_build: created.setdefault(kn, n)
        if is_build or True:
            is_proc = re.search(r"\bCREATE\s+(?:OR\s+ALTER\s+)?PROC(?:EDURE)?\b", code, re.I) is not None
            for m in REF.finditer(code):
                key = (m.group(1).lower(), m.group(2).lower())
                if re.search(r"\bDROP\s+$", code[:m.start()], re.I) or re.search(r"\bDROP\s+(?:TABLE|VIEW)\s+(?:IF\s+EXISTS\s+)?$", code[:m.end()], re.I): continue   # DROP ... IF EXISTS is not a use
                if key in local_created: continue
                if is_proc and key in file_creates: continue          # procedure bodies resolve names when they run

                known = created.get(key) or DYNAMIC.get(key)
                limit = n if n is not None else 99
                if known is None or (known > limit and is_build and base[0].isdigit()):
                    warnings.append(f"{base} (line {start}+): uses {key[0]}.{key[1]} that is not created in an earlier step")
    return raw

for p in step_files: scan(p, True)
for p in test_files:
    # tests run after their own step; objects must exist by that step
    scan(p, False)
for p in other_files: scan(p, False)

# tests: every test file must have a matching build step and say what is expected
for p in test_files:
    n = stepno(p); txt = open(p, encoding="utf-8").read()
    if not glob.glob(os.path.join(ROOT, "sql", "build", f"{n:02d}_*.sql")): problems.append(f"{os.path.basename(p)}: no build step {n:02d}")
    if "CREATE TABLE #t" not in txt or "RAISERROR" not in txt: problems.append(f"{os.path.basename(p)}: not in the PASS/FAIL test format (see any other test file)")

# step ordering: step files numbered 01..N without gaps
nums = [stepno(p) for p in step_files]
if nums != list(range(1, len(nums) + 1)): problems.append(f"step numbers not continuous: {nums}")

# tests may use only objects created at or before their own step
for p in test_files:
    n = stepno(p); _, bs = batches(p)
    for start, b in bs:
        code, _ = strip(b)
        for m in REF.finditer(code):
            key = (m.group(1).lower(), m.group(2).lower()); k = created.get(key) or DYNAMIC.get(key)
            if k is not None and k > n:
                problems.append(f"{os.path.basename(p)} (line {start}+): uses {key[0]}.{key[1]} created in step {k:02d}, later than step {n:02d}")

print("== PROBLEMS ==" if problems else "== no problems ==")
for x in sorted(set(problems)): print(" -", x)
print("== WARNINGS (review) ==" if warnings else "== no warnings ==")
for x in sorted(set(warnings)): print(" -", x)
print(f"\nchecked {len(step_files)} build files, {len(test_files)} test files, {len(other_files)} other files")
sys.exit(1 if problems else 0)
