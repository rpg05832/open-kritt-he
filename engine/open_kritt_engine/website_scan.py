"""Dynamic website scan (DAST) with OWASP ZAP in an isolated container.

ZAP crawls and tests a live site, so it is only ever run against a target the
requester confirmed they own or may test (enforced in the backend). ZAP's alerts
are candidates for the AI to verify, exactly like the local code scanners: this
module never decides severity, it only collects what ZAP reported.

Modes (set by the requester):
  * passive — spider + passive checks, no attack traffic (zap-baseline).
  * active  — spider + active attacks to prove findings (zap-full-scan).
  * full    — active plus the AJAX spider and maximum attack strength; for
              authorized test environments only.

Safety: the target host is resolved and rejected if it points anywhere internal
(the scanner's own machine, the program's services, or a private/LAN address)
unless local-site scanning was turned on. ZAP runs on the default bridge, so it
can reach the public internet but not the program's compose-network services by
name. The scan never runs destructive, site-wiping payloads.
"""

import ipaddress
import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit

LIMIT = 200
# Pinned OWASP ZAP image (official, verified by digest). Overridable for tests.
DEFAULT_IMAGE = (
    "ghcr.io/zaproxy/zaproxy@sha256:030d3df57735dacbb83464854758e674dd9ad01d79d12a129a8e58b1fd384238"
)
# riskcode (ZAP) -> short Hebrew hint. The AI ranker sets the final severity.
_RISK = {"3": "סיכון גבוה (לפי הכלי)", "2": "סיכון בינוני", "1": "סיכון נמוך", "0": "מידע"}
_MODE_MINUTES = {"passive": 20, "active": 45, "full": 75}


def _host_is_internal(host: str) -> bool:
    """Mirror of the backend classifier, for the per-request safety re-check."""
    host = (host or "").strip().strip("[]").rstrip(".").lower()
    if not host:
        return True
    if host in ("localhost", "host.docker.internal") or host.endswith((".localhost", ".local", ".internal")):
        return True
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return True
    for info in infos:
        address = info[4][0].split("%")[0]
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            return True
        if ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_unspecified or ip.is_reserved:
            return True
        # CGNAT 100.64.0.0/10 is "global" to ipaddress but is not a public site.
        if ip.version == 4 and ip in ipaddress.ip_network("100.64.0.0/10"):
            return True
    return False


def _zap_command(url, mode, report_name):
    script = "zap-baseline.py" if mode == "passive" else "zap-full-scan.py"
    command = [script, "-t", url, "-J", report_name, "-I", "-m", str(_MODE_MINUTES.get(mode, 20))]
    if mode == "full":
        # AJAX spider for JavaScript apps, plus maximum attack strength.
        command += ["-j", "-z", "-config scanner.strength=HIGH -config scanner.level=LOW"]
    return command


def run_website_scan(url, *, mode="passive", scan_id=None, allow_local=False, timeout=None):
    """Run ZAP against `url` and return {status, reason, scopes, candidates}."""
    if mode not in _MODE_MINUTES:
        return {"status": "failed", "reason": "מצב סריקה לא נתמך", "candidates": []}
    host = urlsplit(url).hostname
    if not allow_local and _host_is_internal(host or ""):
        return {
            "status": "failed",
            "reason": "כתובת האתר מצביעה על רשת פנימית; הסריקה נעצרה מטעמי בטיחות.",
            "candidates": [],
        }

    docker = shutil.which(os.getenv("ENGINE_DOCKER_BIN", "docker"))
    if not docker:
        return {"status": "unavailable", "reason": "Docker אינו זמין להרצת סורק האתרים", "candidates": []}
    image = os.getenv("ENGINE_WEBSITE_SCAN_IMAGE", DEFAULT_IMAGE).strip() or DEFAULT_IMAGE

    data_dir = Path(os.getenv("ENGINE_DATA_DIR", "/data")).resolve()
    work = data_dir / "website-scans" / ("scan-" + str(scan_id or int(time.time())))
    work.mkdir(parents=True, exist_ok=True)
    os.chmod(work, 0o777)  # the ZAP image runs as uid 1000 and writes the report here
    from .harnesses import _host_path_for_engine_data_path  # local import avoids a cycle

    host_work = _host_path_for_engine_data_path(str(work))

    report_name = "zap-report.json"
    command = [
        docker,
        "run",
        "--rm",
        "--pull",
        "never",
        "--network",
        "bridge",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--memory",
        "2g",
        "--pids-limit",
        "512",
        "-v",
        f"{host_work}:/zap/wrk:rw",
    ]
    if allow_local:
        command += ["--add-host", "host.docker.internal:host-gateway"]
    command += [image] + _zap_command(url, mode, report_name)

    budget = timeout or (_MODE_MINUTES.get(mode, 20) * 60 + 600)
    try:
        # ZAP exits 0 (clean), 1 (fail threshold), 2 (warnings) — all mean it ran.
        subprocess.run(command, capture_output=True, text=True, timeout=budget)
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "reason": "סורק האתרים הגיע למגבלת הזמן", "candidates": []}
    except OSError:
        return {"status": "failed", "reason": "לא ניתן להפעיל את סורק האתרים", "candidates": []}

    report = work / report_name
    try:
        data = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"status": "failed", "reason": "סורק האתרים לא הפיק דוח תקין", "candidates": []}

    candidates = []
    for site in data.get("site", []):
        for alert in site.get("alerts", []):
            instances = alert.get("instances") or [{}]
            first = instances[0]
            risk = _RISK.get(str(alert.get("riskcode")), "")
            explanation = (alert.get("desc") or alert.get("alert") or "").strip()
            if alert.get("solution"):
                explanation += "\nתיקון מוצע: " + alert["solution"].strip()
            candidate = {
                "rule": "zap/" + str(alert.get("pluginid") or alert.get("alertRef") or alert.get("alert")),
                "file": first.get("uri") or site.get("@name") or url,
                "line": 0,
                "explanation": (risk + ": " if risk else "") + explanation,
                "verified": False,
                "tool_risk": risk,
                "method": first.get("method", ""),
                "param": first.get("param", ""),
                "evidence": (first.get("evidence") or "")[:300],
                "instance_count": len(instances),
            }
            candidates.append(candidate)
            if len(candidates) >= LIMIT:
                break
        if len(candidates) >= LIMIT:
            break

    return {
        "status": "completed",
        "scopes": [f"סריקת ZAP במצב {mode} מול {url}"],
        "mode": mode,
        "target": url,
        "candidates": candidates,
    }
