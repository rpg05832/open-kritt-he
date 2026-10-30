"""Code-quality adapters (Ruff, Biome, Lizard, jscpd) and a test inventory.

Same contract as the security adapters: bounded time, one process each, no
source text in reports (jscpd fragments are dropped), results are leads for the
AI to verify.
"""

import csv
import io
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

LIMIT = 200
SKIP = ("node_modules", ".git", ".venv", "venv", "dist", "build", ".next", "vendor", "__pycache__", "coverage")
COMPLEXITY_LIMIT = 15
LENGTH_LIMIT = 100
PARAMETER_LIMIT = 6
SOURCE_EXTENSIONS = {
    '.py': 'Python', '.js': 'JavaScript', '.jsx': 'JavaScript', '.mjs': 'JavaScript', '.cjs': 'JavaScript',
    '.ts': 'TypeScript', '.tsx': 'TypeScript', '.go': 'Go', '.java': 'Java', '.cs': 'C#', '.php': 'PHP',
    '.rb': 'Ruby', '.rs': 'Rust', '.kt': 'Kotlin', '.swift': 'Swift', '.c': 'C', '.cpp': 'C++',
}  # fmt: skip


def _relative(root, value):
    path = Path(value or "")
    if not path.is_absolute():
        path = Path(root) / path
    try:
        return path.resolve().relative_to(Path(root).resolve()).as_posix()
    except (OSError, ValueError):
        return None


def _execute(command, timeout, cwd=None, ok_codes=(0, 1)):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    except subprocess.TimeoutExpired:
        return None, {"status": "timeout", "reason": "הכלי הגיע למגבלת הזמן", "candidates": []}
    except OSError:
        return None, {"status": "failed", "reason": "לא ניתן להפעיל את הכלי", "candidates": []}
    if result.returncode not in ok_codes:
        return None, {"status": "failed", "reason": "הכלי לא סיים בהצלחה", "candidates": []}
    return result.stdout, None


def _missing(name):
    return {"status": "unavailable", "reason": f"{name} אינו מותקן", "candidates": []}


def run_ruff(root, timeout=90):
    """Python bugs: pyflakes (F), bugbear (B), syntax errors (E9) and pylint errors (PLE)."""
    binary = shutil.which("ruff")
    if not binary:
        return _missing("Ruff")
    command = [binary, 'check', '--isolated', '--no-cache', '--select', 'F,B,E9,PLE', '--output-format', 'json',
               '--exit-zero', *[f'--extend-exclude={d}' for d in SKIP], str(root)]  # fmt: skip
    output, error = _execute(command, timeout)
    if error:
        return error
    candidates = []
    for item in json.loads(output or "[]"):
        relative = _relative(root, item.get("filename"))
        if relative:
            candidates.append({'rule': 'ruff/' + str(item.get('code')), 'file': relative,
                               'line': (item.get('location') or {}).get('row'), 'explanation': item.get('message', ''),
                               'verified': False})  # fmt: skip
        if len(candidates) >= LIMIT:
            break
    return {"status": "completed", "candidates": candidates}


def run_biome(root, timeout=90):
    """JavaScript/TypeScript correctness and suspicious-code rules (project config is respected)."""
    binary = shutil.which("biome")
    if not binary:
        return _missing("Biome")
    command = [binary, "lint", "--reporter=json", f"--max-diagnostics={LIMIT}", "--colors=off", "."]
    output, error = _execute(command, timeout, cwd=str(root))
    if error:
        return error
    start = (output or "").find("{")
    try:
        payload = json.loads(output[start:]) if start >= 0 else {}
    except ValueError:
        return {"status": "failed", "reason": "לא ניתן לקרוא את תוצאות הכלי", "candidates": []}
    candidates = []
    for item in payload.get("diagnostics", []):
        location = item.get("location") or {}
        relative = _relative(root, location.get("path"))
        if relative and not any(part in SKIP for part in Path(relative).parts):
            candidates.append({'rule': 'biome/' + str(item.get('category', '')).removeprefix('lint/'), 'file': relative,
                               'line': (location.get('start') or {}).get('line'), 'severity': item.get('severity'),
                               'explanation': item.get('message', ''), 'verified': False})  # fmt: skip
    return {"status": "completed", "candidates": candidates[:LIMIT]}


def run_lizard(root, timeout=120):
    """Functions that are too complex, too long or take too many parameters (about 20 languages)."""
    binary = shutil.which("lizard")
    if not binary:
        return _missing("Lizard")
    command = [binary, "--csv", *[arg for d in SKIP for arg in ("-x", f"*/{d}/*")], str(root)]
    output, error = _execute(command, timeout)
    if error:
        return error
    candidates, functions = [], 0
    for row in csv.reader(io.StringIO(output or "")):
        if len(row) < 11 or not row[0].isdigit():
            continue
        functions += 1
        nloc, ccn, params = int(row[0]), int(row[1]), int(row[3])
        reasons = []
        if ccn > COMPLEXITY_LIMIT:
            reasons.append(f"מורכבות {ccn} (מעל {COMPLEXITY_LIMIT})")
        if nloc > LENGTH_LIMIT:
            reasons.append(f"{nloc} שורות קוד (מעל {LENGTH_LIMIT})")
        if params > PARAMETER_LIMIT:
            reasons.append(f"{params} פרמטרים (מעל {PARAMETER_LIMIT})")
        relative = _relative(root, row[6])
        if reasons and relative:
            candidates.append({'rule': 'complexity', 'file': relative, 'line': int(row[9]), 'function': row[7],
                               'explanation': 'פונקציה קשה לתחזוקה ולבדיקה: ' + ', '.join(reasons), 'verified': False})  # fmt: skip
    candidates.sort(key=lambda c: c["explanation"], reverse=True)
    return {"status": "completed", "functions_checked": functions, "candidates": candidates[:LIMIT]}


def run_jscpd(root, timeout=120):
    """Copy-pasted code between files. The duplicated fragment itself is never stored."""
    binary = shutil.which("jscpd")
    if not binary:
        return _missing("jscpd")
    with tempfile.TemporaryDirectory(prefix="jscpd-") as output_dir:
        command = [binary, '--silent', '--reporters', 'json', '--output', output_dir, '--min-lines', '10',
                   '--min-tokens', '70', '--max-size', '200kb', '--max-lines', '3000',
                   '--ignore', ','.join(f'**/{d}/**' for d in SKIP), '.']  # fmt: skip
        _, error = _execute(command, timeout, cwd=str(root), ok_codes=(0, 1))
        if error:
            return error
        try:
            payload = json.loads((Path(output_dir) / "jscpd-report.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {"status": "completed", "duplicated_lines": 0, "candidates": []}
    candidates = []
    for item in payload.get("duplicates", []):
        first, second = item.get("firstFile") or {}, item.get("secondFile") or {}
        a, b = _relative(root, first.get("name")), _relative(root, second.get("name"))
        if a and b:
            candidates.append({'rule': 'duplication', 'file': a, 'line': first.get('start'), 'other_file': b,
                               'other_line': second.get('start'), 'lines': item.get('lines'),
                               'explanation': f"קוד כפול ({item.get('lines')} שורות) בין {a} לבין {b}",
                               'verified': False})  # fmt: skip
        if len(candidates) >= LIMIT:
            break
    total = (payload.get("statistics") or {}).get("total") or {}
    return {'status': 'completed', 'duplicated_lines': total.get('duplicatedLines', 0),
            'duplication_percentage': total.get('percentage'), 'candidates': candidates}  # fmt: skip


def is_test_file(relative):
    path = Path(relative)
    name = path.name.lower()
    parts = {p.lower() for p in path.parts[:-1]}
    return bool(
        parts & {"test", "tests", "__tests__", "spec", "specs"}
        or name.startswith("test_")
        or any(marker in name for marker in ("_test.", ".test.", ".spec.", "test.java", "tests.cs"))
    )


def inventory_of_tests(root, max_files=20000):
    """Source and test files per language; a language without tests is a coverage gap."""
    languages = {}
    seen = 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".")]
        for name in files:
            seen += 1
            if seen > max_files:
                break
            language = SOURCE_EXTENSIONS.get(Path(name).suffix.lower())
            if not language:
                continue
            relative = Path(directory, name).relative_to(root).as_posix()
            entry = languages.setdefault(language, {"source_files": 0, "test_files": 0})
            entry["test_files" if is_test_file(relative) else "source_files"] += 1
    gaps = sorted(lang for lang, e in languages.items() if e["source_files"] >= 3 and e["test_files"] == 0)
    return {
        "status": "completed",
        "languages": languages,
        "languages_without_tests": gaps,
        "complete": seen <= max_files,
    }


def run_quality(root):
    """All quality checks; each tool failing independently is recorded, never fatal."""
    report = {}
    for key, runner in (('lint_python', run_ruff), ('lint_javascript', run_biome), ('complexity', run_lizard),
                        ('duplication', run_jscpd), ('tests', inventory_of_tests)):  # fmt: skip
        try:
            report[key] = runner(root)
        except Exception as error:  # a broken tool must not stop the scan
            report[key] = {"status": "failed", "reason": type(error).__name__, "candidates": []}
    return report
