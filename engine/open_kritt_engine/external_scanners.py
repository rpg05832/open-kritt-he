"""Adapters for the pinned local scanners (Gitleaks, OSV-Scanner, Trivy).

Same contract as semgrep_checks.run_semgrep: bounded time, one process, results
are candidates for the AI to verify, and reports never contain source text or
secret values.
"""

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

LIMIT = 200
SKIPPED_DIRECTORIES = ("node_modules", ".venv", "venv", "dist", "build", ".next")


def _relative(root, value):
    path = Path(value or "")
    if not path.is_absolute():
        path = Path(root) / path
    try:
        return path.resolve().relative_to(Path(root).resolve()).as_posix()
    except (OSError, ValueError):
        return None


def _run(command, timeout, ok_codes=(0, 1), env=None):
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout, env={**os.environ, **(env or {})}
        )
    except subprocess.TimeoutExpired:
        return None, {"status": "timeout", "reason": "הכלי הגיע למגבלת הזמן", "candidates": []}
    except OSError:
        return None, {"status": "failed", "reason": "לא ניתן להפעיל את הכלי", "candidates": []}
    if result.returncode not in ok_codes:
        return None, {"status": "failed", "reason": "הכלי לא סיים בהצלחה", "candidates": []}
    try:
        return json.loads(result.stdout or "null"), None
    except ValueError:
        return None, {"status": "failed", "reason": "לא ניתן לקרוא את תוצאות הכלי", "candidates": []}


def run_gitleaks(root, timeout=90, history_commits=300):
    """Secrets in files and, when a .git folder exists, in recent history. Values are redacted."""
    binary = shutil.which("gitleaks")
    if not binary:
        return {"status": "unavailable", "reason": "Gitleaks אינו מותקן", "candidates": []}
    base = [
        "--report-format",
        "json",
        "--report-path",
        "-",
        "--redact",
        "--no-banner",
        "--exit-code",
        "0",
        "--max-target-megabytes",
        "1",
        "--log-level",
        "error",
    ]
    candidates, scopes = [], []
    payload, error = _run([binary, "dir", str(root), *base], timeout)
    if error:
        return error
    scopes.append("קבצים נוכחיים")
    findings = list(payload or [])
    if (Path(root) / ".git").is_dir():
        # The checkout belongs to another user inside the container; trust only this path.
        history, history_error = _run(
            [binary, "git", str(root), *base, f"--log-opts=--max-count={int(history_commits)}"],
            timeout,
            env={
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "safe.directory",
                "GIT_CONFIG_VALUE_0": str(Path(root).resolve()),
            },
        )
        if not history_error:
            findings += list(history or [])
            scopes.append(f"עד {history_commits} גרסאות אחרונות בהיסטוריית Git")
    seen = set()
    for item in findings:
        relative = _relative(root, item.get("File"))
        key = (item.get("RuleID"), relative, item.get("StartLine"), (item.get("Commit") or "")[:12])
        if relative is None or key in seen or relative.startswith(".open-kritt-"):
            continue
        seen.add(key)
        candidate = {
            "rule": "secret/" + str(item.get("RuleID")),
            "file": relative,
            "line": item.get("StartLine"),
            "explanation": item.get("Description", ""),
            "verified": False,
        }
        if item.get("Commit"):
            candidate["commit"] = item["Commit"][:12]
            candidate["explanation"] += " (נמצא בהיסטוריה; גם אם נמחק מהקוד הנוכחי, יש להחליף אותו)"
        candidates.append(candidate)
        if len(candidates) >= LIMIT:
            break
    return {"status": "completed", "scopes": scopes, "candidates": candidates}


def run_osv_scanner(root, timeout=180):
    """Known vulnerabilities for lockfiles of most ecosystems (sends package names to OSV.dev)."""
    binary = shutil.which("osv-scanner")
    if not binary:
        return {"status": "unavailable", "reason": "OSV-Scanner אינו מותקן", "findings": []}
    command = [binary, "scan", "source", "--recursive", "--format", "json", "--no-resolve", str(root)]
    payload, error = _run(command, timeout, ok_codes=(0, 1, 128))
    if error:
        return {**error, "findings": []}
    findings, sources = [], set()
    for result in (payload or {}).get("results", []):
        source = _relative(root, result.get("source", {}).get("path"))
        if source is None:
            continue
        sources.add(source)
        for entry in result.get("packages", []):
            package = entry.get("package", {})
            for group in entry.get("groups", []):
                aliases = sorted(set(group.get("aliases") or group.get("ids") or []))
                findings.append(
                    {
                        "ecosystem": package.get("ecosystem"),
                        "name": package.get("name"),
                        "version": package.get("version"),
                        "file": source,
                        "ids": aliases[:8],
                        "max_severity": group.get("max_severity") or None,
                        "verified": False,
                    }
                )
                if len(findings) >= LIMIT:
                    break
    return {"status": "completed", "lockfiles": sorted(sources), "findings": findings}


def run_trivy_config(root, timeout=180):
    """Misconfigurations in Dockerfile, Kubernetes, Terraform, CI and similar files (offline checks)."""
    binary = shutil.which("trivy")
    if not binary:
        return {"status": "unavailable", "reason": "Trivy אינו מותקן", "candidates": []}
    with tempfile.TemporaryDirectory(prefix="trivy-") as cache:
        command = [
            binary,
            "config",
            "--format",
            "json",
            "--quiet",
            "--skip-check-update",
            "--cache-dir",
            cache,
            "--severity",
            "LOW,MEDIUM,HIGH,CRITICAL",
        ]
        for directory in SKIPPED_DIRECTORIES:
            command += ["--skip-dirs", directory]
        payload, error = _run(command + [str(root)], timeout, ok_codes=(0,), env={"HOME": cache})
    if error:
        return error
    candidates = []
    for result in (payload or {}).get("Results", []) or []:
        relative = _relative(root, result.get("Target"))
        if relative is None:
            continue
        for item in result.get("Misconfigurations", []) or []:
            if item.get("Status", "FAIL") != "FAIL":
                continue
            candidates.append(
                {
                    "rule": "config/" + str(item.get("ID")),
                    "file": relative,
                    "line": (item.get("CauseMetadata") or {}).get("StartLine"),
                    "severity": item.get("Severity"),
                    "explanation": (item.get("Title") or "") + " — " + (item.get("Resolution") or ""),
                    "verified": False,
                }
            )
            if len(candidates) >= LIMIT:
                break
    return {"status": "completed", "candidates": candidates}
