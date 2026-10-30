import json

import pytest

from open_kritt_engine import website_scan
from open_kritt_engine.security_preflight import write_website_preflight


@pytest.mark.parametrize(
    "host",
    ["localhost", "127.0.0.1", "10.1.2.3", "192.168.0.1", "172.20.0.5", "169.254.1.1", "::1", "host.docker.internal"],
)
def test_internal_hosts_are_rejected(host):
    assert website_scan._host_is_internal(host) is True


def test_public_hosts_resolve_and_pass(monkeypatch):
    monkeypatch.setattr(website_scan.socket, "getaddrinfo", lambda *a, **k: [(2, 1, 6, "", ("93.184.216.34", 0))])
    assert website_scan._host_is_internal("example.com") is False


def test_full_mode_uses_the_full_scan_script_at_max_strength():
    cmd = website_scan._zap_command("https://example.com", "full", "zap-report.json")
    assert cmd[0] == "zap-full-scan.py"
    assert "-j" in cmd and "scanner.strength=HIGH" in " ".join(cmd)
    assert website_scan._zap_command("https://example.com", "passive", "r.json")[0] == "zap-baseline.py"


def test_internal_target_blocks_the_scan_without_opt_in(monkeypatch):
    monkeypatch.setattr(website_scan, "_host_is_internal", lambda host: True)
    called = []
    monkeypatch.setattr(website_scan.subprocess, "run", lambda *a, **k: called.append(a))
    result = website_scan.run_website_scan("http://192.168.1.1", mode="active", allow_local=False)
    assert result["status"] == "failed"
    assert not called  # ZAP must never launch against a blocked target


def test_report_parses_into_candidates_in_preflight_format(monkeypatch, tmp_path):
    monkeypatch.setenv("ENGINE_DATA_DIR", str(tmp_path))
    monkeypatch.setattr(website_scan, "_host_is_internal", lambda host: False)
    monkeypatch.setattr(website_scan.shutil, "which", lambda *a, **k: "/usr/bin/docker")
    monkeypatch.setattr(website_scan, "_host_path_for_engine_data_path", lambda p: p, raising=False)
    import open_kritt_engine.harnesses as harnesses

    monkeypatch.setattr(harnesses, "_host_path_for_engine_data_path", lambda p: p)

    def fake_run(command, **kwargs):
        work = command[command.index("-v") + 1].split(":")[0]
        from pathlib import Path

        Path(work, "zap-report.json").write_text(
            json.dumps(
                {
                    "site": [
                        {
                            "@name": "https://example.com",
                            "alerts": [
                                {
                                    "pluginid": "40012",
                                    "alert": "Cross Site Scripting (Reflected)",
                                    "riskcode": "3",
                                    "desc": "Reflected XSS",
                                    "solution": "Encode output",
                                    "instances": [
                                        {"uri": "https://example.com/q?x=1", "method": "GET", "param": "x", "evidence": "<script>"}
                                    ],
                                }
                            ],
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )

        class R:
            returncode = 2

        return R()

    monkeypatch.setattr(website_scan.subprocess, "run", fake_run)
    report = write_website_preflight(tmp_path, 7, url="https://example.com", mode="active", output_root=tmp_path)
    assert report["scan_kind"] == "website"
    assert report["website"]["status"] == "completed"
    [candidate] = report["candidates"]
    assert candidate["rule"] == "zap/40012"
    assert candidate["file"] == "https://example.com/q?x=1"
    assert candidate["line"] == 0
    assert candidate["param"] == "x"
    assert "סריקת אתר דינמית" in report["checks"][0]
    saved = json.loads((tmp_path / ".open-kritt-security-checks.json").read_text(encoding="utf-8"))
    assert saved["target_url"] == "https://example.com"
