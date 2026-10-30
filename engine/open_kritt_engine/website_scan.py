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

Residual limitation: the validated public IP is pinned for the primary host, but
a cross-host redirect during an active/full scan is not independently re-checked
here — the same host-level egress policy the project's threat model already asks
operators to enforce (docs/threat-model.md) covers that case.
"""

import ipaddress
import json
import os
import re
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


_CGNAT = ipaddress.ip_network("100.64.0.0/10")


def _ip_is_internal(ip: ipaddress._BaseAddress) -> bool:
    if ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_unspecified or ip.is_reserved:
        return True
    return ip.version == 4 and ip in _CGNAT


def _resolve_public_ip(host: str):
    """Resolve `host` and return a single public IP to pin, or None if anything
    about it is internal or unresolvable. Pinning the IP closes the DNS-rebinding
    window: ZAP connects to this address instead of re-resolving the name."""
    host = (host or "").strip().strip("[]").rstrip(".").lower()
    if not host:
        return None
    if host in ("localhost", "host.docker.internal") or host.endswith((".localhost", ".local", ".internal")):
        return None
    try:
        infos = socket.getaddrinfo(host, None)
    except OSError:
        return None
    chosen = None
    for info in infos:
        address = info[4][0].split("%")[0]
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            return None
        if _ip_is_internal(ip):
            return None  # any internal address at all disqualifies the target
        if chosen is None:
            chosen = address
    return chosen


def _host_is_internal(host: str) -> bool:
    """True when the host is not a safely resolvable public address."""
    return _resolve_public_ip(host) is None


_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _clean(value, limit):
    """ZAP alerts echo attacker-influenced text. Keep it as plain, bounded data
    (control characters stripped) so it reaches the AI as a lead, not as markup."""
    return _CONTROL.sub(" ", str(value or "")).strip()[:limit]


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
    pinned_ip = None
    if not allow_local:
        pinned_ip = _resolve_public_ip(host or "")
        if pinned_ip is None:
            return {
                "status": "failed",
                "reason": "כתובת האתר מצביעה על רשת פנימית או אינה ניתנת לפתרון; הסריקה נעצרה מטעמי בטיחות.",
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
    elif pinned_ip and host:
        # Pin the validated public IP so ZAP uses it instead of re-resolving the
        # name (closes the DNS-rebinding window for the primary host).
        command += ["--add-host", f"{host}:{pinned_ip}"]
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
            explanation = _clean(alert.get("desc") or alert.get("alert"), 1500)
            if alert.get("solution"):
                explanation += "\nתיקון מוצע: " + _clean(alert["solution"], 600)
            candidate = {
                "rule": _clean("zap/" + str(alert.get("pluginid") or alert.get("alertRef") or alert.get("alert")), 120),
                "file": _clean(first.get("uri") or site.get("@name") or url, 2048),
                "line": 0,
                "explanation": (risk + ": " if risk else "") + explanation,
                "verified": False,
                "tool_risk": risk,
                "method": _clean(first.get("method"), 10),
                "param": _clean(first.get("param"), 120),
                "evidence": _clean(first.get("evidence"), 300),
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
