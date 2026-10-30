"""Bounded, offline code triage. Never execute target code or expose matched secrets."""

import ast
import hashlib
import json
import os
import re
import time
from pathlib import Path

from .security_io import atomic_json

SKIP = {".git", "node_modules", ".venv", "venv", "dist", "build", ".next", "__pycache__"}
EXTENSIONS = {
    ".js",
    ".jsx",
    ".mjs",
    ".cjs",
    ".ts",
    ".tsx",
    ".py",
    ".go",
    ".rs",
    ".java",
    ".php",
    ".rb",
    ".cs",
    ".sol",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".ini",
    ".env",
    ".conf",
    ".sh",
    ".mod",
    ".xml",
}
RULES = [
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"), "סוד אפשרי: כותרת מפתח פרטי"),
    (
        "token-literal",
        re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|AKIA[A-Z0-9]{16}|sk_live_[A-Za-z0-9]{20,})"),
        "סוד אפשרי: תבנית אסימון מוכרת",
    ),
    (
        "tls-verification-disabled",
        re.compile(
            r"(?:rejectUnauthorized\s*:\s*false|verify\s*=\s*False|NODE_TLS_REJECT_UNAUTHORIZED\s*=\s*[\x27\x22]?0)"
        ),
        "אימות תעודת TLS עשוי להיות מושבת",
    ),
    ("dynamic-eval", re.compile(r"\b(?:eval|exec)\s*\("), "הרצת קוד דינמית — יש לבדוק מקור קלט"),
    (
        "permissive-cors",
        re.compile(r"(?:Access-Control-Allow-Origin.{0,20}\*|origin\s*:\s*[\x27\x22]\*)"),
        "הרשאת CORS רחבה — יש לבדוק הקשר",
    ),
]


def inspect_repository(root, max_files=6000, time_limit=20):
    root = Path(root)
    started = time.monotonic()
    fingerprint = hashlib.sha256(Path(__file__).with_name("security_rules.json").read_bytes())
    ignore = root / ".semgrepignore"
    if ignore.is_file() and not ignore.is_symlink():
        fingerprint.update(ignore.read_bytes())
    report = {
        "version": 1,
        "files_seen": 0,
        "files_checked": 0,
        "files_skipped": 0,
        "languages": {},
        "manifests": [],
        "candidates": [],
        "limitations": [],
        "checks": ["מיפוי קבצים וטכנולוגיות", "תבניות סודות מוכרות ללא חשיפת הערך", "תבניות TLS, הרצת קוד ו־CORS"],
        "not_run": ["מאגר חולשות תלויות מעודכן (CVE)", "בדיקת אתר פרוס", "בדיקות חדירה ברשת", "Semgrep ו־CodeQL מלאים"],
    }
    stop = False
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and not Path(directory, d).is_symlink())
        for name in sorted(files):
            if name.startswith(".open-kritt-") or name in {"WORKSPACE.json", "WORKSPACE.md"}:
                continue
            if report["files_seen"] >= max_files or time.monotonic() - started > time_limit:
                report["limitations"].append("המיפוי הגיע למגבלת קבצים או זמן; הכיסוי חלקי")
                stop = True
                break
            report["files_seen"] += 1
            file = Path(directory, name)
            relative = file.relative_to(root).as_posix()
            try:
                if (
                    file.is_symlink()
                    or file.stat().st_size > 512 * 1024
                    or (
                        file.suffix.lower() not in EXTENSIONS
                        and name not in {"Dockerfile", "requirements.txt", "Gemfile"}
                    )
                ):
                    report["files_skipped"] += 1
                    continue
                text = file.read_text(encoding="utf-8", errors="strict")
                fingerprint.update(relative.encode("utf-8") + b"\0" + text.encode("utf-8") + b"\0")
                report["files_checked"] += 1
                ext = file.suffix.lower() or name
                report["languages"][ext] = report["languages"].get(ext, 0) + 1
                if (
                    name
                    in {
                        "package.json",
                        "package-lock.json",
                        "requirements.txt",
                        "pyproject.toml",
                        "Cargo.toml",
                        "go.mod",
                        "composer.json",
                        "Gemfile",
                        "pom.xml",
                    }
                    and len(report["manifests"]) < 100
                ):
                    report["manifests"].append(relative)
                for rule, pattern, explanation in RULES:
                    for match in pattern.finditer(text):
                        if len(report["candidates"]) >= 200:
                            break
                        report["candidates"].append(
                            {
                                "rule": rule,
                                "file": relative,
                                "line": text.count("\n", 0, match.start()) + 1,
                                "explanation": explanation,
                                "verified": False,
                            }
                        )
                if file.suffix == ".py":
                    try:
                        tree = ast.parse(text)
                        for node in ast.walk(tree):
                            if (
                                isinstance(node, ast.Call)
                                and any(
                                    k.arg == "shell" and isinstance(k.value, ast.Constant) and k.value.value is True
                                    for k in node.keywords
                                )
                                and len(report["candidates"]) < 200
                            ):
                                report["candidates"].append(
                                    {
                                        "rule": "python-shell",
                                        "file": relative,
                                        "line": node.lineno,
                                        "explanation": "הפעלת shell — נדרש אימות מקור קלט",
                                        "verified": False,
                                    }
                                )
                    except SyntaxError:
                        report["files_skipped"] += 1
            except (OSError, UnicodeError):
                report["files_skipped"] += 1
        if stop:
            break
    if len(report["candidates"]) >= 200:
        report["limitations"].append("רשימת החשדות מוגבלת ל־200 פריטים")
    report["limitations"].append(
        "כלל סטטי אינו מוכיח ניצול; נדרש ניתוח הקשר. קבצים בינאריים, קבצים מעל 512 KB ותיקיות תוצרים אינם נבדקים בכלי זה."
    )
    report["fingerprint"] = fingerprint.hexdigest()
    report["inventory_complete"] = not stop
    return report


def _reuse_or_run(report, previous, key, runner, root):
    cached = previous.get(key, {})
    if (
        report["inventory_complete"]
        and previous.get("fingerprint") == report["fingerprint"]
        and cached.get("status") == "completed"
    ):
        return {**cached, "reused": True}
    return runner(root)


def _record(report, result, label):
    if result.get("status") == "completed":
        report["checks"].append(label)
    else:
        report["limitations"].append(label + ": " + result.get("reason", "לא הושלם"))


def write_preflight(root, scan_id, *, dependency_audit=False, output_root=None, incremental=None, scan_kind="security"):
    """scan_kind: "security" (default), "quality" (code quality only) or "both"."""
    started = time.monotonic()
    report = inspect_repository(root)
    report["scan_id"] = str(scan_id)
    report["scan_kind"] = scan_kind
    report["incremental"] = incremental
    directory = Path(os.getenv("ENGINE_DATA_DIR", "/data")) / "security-reports"
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / ("scan-" + str(int(scan_id)) + ".json")
    previous = {}
    try:
        previous = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass
    if scan_kind in ("security", "both"):
        _write_security_checks(report, previous, root, dependency_audit)
    if scan_kind in ("quality", "both"):
        from .quality_checks import run_quality

        cached = previous.get("quality", {})
        if (
            report["inventory_complete"]
            and previous.get("fingerprint") == report["fingerprint"]
            and cached
            and all(v.get("status") == "completed" for v in cached.values())
        ):
            report["quality"] = {k: {**v, "reused": True} for k, v in cached.items()}
        else:
            report["quality"] = run_quality(root)
        for key, label in (
            ("lint_python", "באגים נפוצים ב־Python (Ruff)"),
            ("lint_javascript", "באגים ובעיות ב־JavaScript/TypeScript (Biome)"),
            ("complexity", "פונקציות מורכבות או ארוכות מדי (Lizard)"),
            ("duplication", "קוד כפול בין קבצים (jscpd)"),
            ("tests", "מיפוי קובצי בדיקות לפי שפה"),
        ):
            _record(report, report["quality"][key], label)
    if output_root:
        report["limitations"].append(
            "בדיקות הכלים והשוואת הקבצים במצב תמונת עבודה כוללות את המאגר הראשי בלבד; מאגרי תלות נוספים נשארים זמינים לניתוח AI אך אינם כלולים במוני הכלי המקומי."
        )
    report["duration_seconds"] = round(time.monotonic() - started, 2)
    report["generated_at"] = time.time()
    output = Path(output_root or root) / ".open-kritt-security-checks.json"
    atomic_json(output, report)
    atomic_json(target, report)
    return report


def _write_security_checks(report, previous, root, dependency_audit):
    from .external_scanners import run_gitleaks, run_osv_scanner, run_trivy_config
    from .semgrep_checks import run_semgrep

    report["semgrep"] = _reuse_or_run(report, previous, "semgrep", run_semgrep, root)
    # Offline scanners: secrets (files + recent Git history) and configuration files.
    for key, runner, label in (
        ("secrets", run_gitleaks, "חיפוש סודות בקבצים ובהיסטוריית Git (Gitleaks)"),
        ("configuration", run_trivy_config, "בדיקת קובצי הגדרות: Docker, Kubernetes, Terraform ו־CI (Trivy)"),
    ):
        report[key] = _reuse_or_run(report, previous, key, runner, root)
        _record(report, report[key], label)
    if dependency_audit:
        from .dependency_audit import audit_dependencies, dependency_inventory

        inventory = dependency_inventory(Path(root))
        previous_audit = previous.get("dependency_audit", {})
        if (
            not inventory["incomplete"]
            and previous_audit.get("fingerprint") == inventory["fingerprint"]
            and previous_audit.get("status") == "completed"
            and time.time() - previous_audit.get("checked_at", 0) < 3600
        ):
            report["dependency_audit"] = {**previous_audit, "reused": True}
        else:
            report["dependency_audit"] = audit_dependencies(root, inventory=inventory)
        if report["dependency_audit"]["status"] == "completed":
            report["not_run"] = [item for item in report["not_run"] if "CVE" not in item]
            report["checks"].append("בדיקת גרסאות ספריות נתמכות מול מאגר OSV")
        # Broader lockfile coverage (yarn, pnpm, poetry, Go, Rust, PHP, Java, .NET ...).
        report["dependency_scanner"] = run_osv_scanner(root)
        _record(report, report["dependency_scanner"], "בדיקת ספריות בכל מנהלי החבילות הנתמכים מול OSV (OSV-Scanner)")
    else:
        report["dependency_audit"] = {"status": "disabled", "checked_packages": 0, "findings": []}
        report["dependency_scanner"] = {"status": "disabled", "findings": []}
    rule_count = len(json.loads(Path(__file__).with_name("security_rules.json").read_text(encoding="utf-8"))["rules"])
    report["limitations"].append(
        f"Semgrep מופעל עם {rule_count} כללים מקומיים, תהליך אחד ועד 60 שניות; זו אינה חבילת כללי אבטחה מלאה."
    )
