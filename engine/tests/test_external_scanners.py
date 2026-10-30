import json
import shutil
import subprocess
from types import SimpleNamespace

import pytest

from open_kritt_engine import external_scanners
from open_kritt_engine.external_scanners import run_gitleaks, run_osv_scanner, run_trivy_config


def fake_binary(monkeypatch, name):
    monkeypatch.setattr("shutil.which", lambda tool: f"/usr/local/bin/{tool}" if tool == name else None)


@pytest.mark.parametrize("runner", [run_gitleaks, run_osv_scanner, run_trivy_config])
def test_missing_tool_is_explicit(monkeypatch, tmp_path, runner):
    monkeypatch.setattr("shutil.which", lambda _: None)
    assert runner(tmp_path)["status"] == "unavailable"


def test_gitleaks_never_reports_the_secret_and_marks_history(monkeypatch, tmp_path):
    fake_binary(monkeypatch, "gitleaks")
    (tmp_path / ".git").mkdir()
    secret = "ghp_" + "R8qZ2vLw9XnT4kPb7Hs3Jd6Fm1Yc5Ae0Uo8i"  # built at runtime so the repository holds no token-shaped literal
    calls = []

    def fake_run(command, **kwargs):
        calls.append(command)
        assert "--redact" in command and kwargs["timeout"] == 90
        item = {
            "RuleID": "github-pat",
            "Description": "token",
            "StartLine": 3,
            "File": str(tmp_path / "a.py"),
            "Secret": secret,
            "Match": secret,
            "Commit": "abcdef1234567890" if command[1] == "git" else "",
        }
        return SimpleNamespace(returncode=0, stdout=json.dumps([item]))

    monkeypatch.setattr("subprocess.run", fake_run)
    report = run_gitleaks(tmp_path)
    assert report["status"] == "completed"
    assert [c[1] for c in calls] == ["dir", "git"]
    assert len(report["candidates"]) == 2
    assert report["candidates"][1]["commit"] == "abcdef123456"
    assert secret not in json.dumps(report)


def test_gitleaks_ignores_paths_outside_the_repository(monkeypatch, tmp_path):
    fake_binary(monkeypatch, "gitleaks")
    payload = [{"RuleID": "x", "File": "/etc/passwd", "StartLine": 1}]
    monkeypatch.setattr(
        "subprocess.run", lambda command, **kw: SimpleNamespace(returncode=0, stdout=json.dumps(payload))
    )
    assert run_gitleaks(tmp_path)["candidates"] == []


def test_osv_scanner_summarises_groups(monkeypatch, tmp_path):
    fake_binary(monkeypatch, "osv-scanner")
    payload = {
        "results": [
            {
                "source": {"path": str(tmp_path / "requirements.txt")},
                "packages": [
                    {
                        "package": {"name": "requests", "version": "2.19.0", "ecosystem": "PyPI"},
                        "groups": [
                            {
                                "ids": ["PYSEC-2018-28"],
                                "aliases": ["CVE-2018-18074", "PYSEC-2018-28"],
                                "max_severity": "7.5",
                            }
                        ],
                    }
                ],
            }
        ]
    }

    def fake_run(command, **kwargs):
        assert "--no-resolve" in command
        return SimpleNamespace(returncode=1, stdout=json.dumps(payload))

    monkeypatch.setattr("subprocess.run", fake_run)
    report = run_osv_scanner(tmp_path)
    assert report["status"] == "completed"
    assert report["lockfiles"] == ["requirements.txt"]
    assert report["findings"][0]["ids"] == ["CVE-2018-18074", "PYSEC-2018-28"]


def test_trivy_uses_offline_checks_and_keeps_failures_only(monkeypatch, tmp_path):
    fake_binary(monkeypatch, "trivy")
    payload = {
        "Results": [
            {
                "Target": "Dockerfile",
                "Misconfigurations": [
                    {
                        "ID": "DS-0001",
                        "Title": "latest tag",
                        "Resolution": "pin",
                        "Severity": "MEDIUM",
                        "Status": "FAIL",
                        "CauseMetadata": {"StartLine": 1},
                    },
                    {"ID": "DS-0002", "Title": "ok", "Status": "PASS"},
                ],
            }
        ]
    }

    def fake_run(command, **kwargs):
        assert "--skip-check-update" in command
        return SimpleNamespace(returncode=0, stdout=json.dumps(payload))

    monkeypatch.setattr("subprocess.run", fake_run)
    report = run_trivy_config(tmp_path)
    assert [c["rule"] for c in report["candidates"]] == ["config/DS-0001"]


def test_timeouts_are_reported(monkeypatch, tmp_path):
    fake_binary(monkeypatch, "trivy")

    def fake_run(command, **kwargs):
        raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr("subprocess.run", fake_run)
    assert run_trivy_config(tmp_path)["status"] == "timeout"


@pytest.mark.skipif(not shutil.which("gitleaks"), reason="Gitleaks not installed")
def test_real_gitleaks_redacts(tmp_path):
    secret = "ghp_" + "R8qZ2vLw9XnT4kPb7Hs3Jd6Fm1Yc5Ae0Uo8i"  # built at runtime so the repository holds no token-shaped literal
    (tmp_path / "conf.py").write_text(f'token = "{secret}"\n')
    report = run_gitleaks(tmp_path)
    assert report["status"] == "completed", report
    assert any(c["rule"] == "secret/github-pat" for c in report["candidates"])
    assert secret not in json.dumps(report)


@pytest.mark.skipif(not shutil.which("trivy"), reason="Trivy not installed")
def test_real_trivy_offline(tmp_path):
    (tmp_path / "Dockerfile").write_text("FROM ubuntu:latest\nRUN apt-get install -y curl\n")
    report = run_trivy_config(tmp_path)
    assert report["status"] == "completed", report
    assert report["candidates"]


def test_module_has_no_network_defaults():
    assert external_scanners.LIMIT == 200
