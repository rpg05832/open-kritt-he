import json
import shutil
from types import SimpleNamespace

import pytest

from open_kritt_engine import quality_checks
from open_kritt_engine.quality_checks import (
    inventory_of_tests,
    is_test_file,
    run_biome,
    run_jscpd,
    run_lizard,
    run_quality,
    run_ruff,
)


def only(monkeypatch, name):
    monkeypatch.setattr("shutil.which", lambda tool: f"/usr/local/bin/{tool}" if tool == name else None)


@pytest.mark.parametrize("runner", [run_ruff, run_biome, run_lizard, run_jscpd])
def test_missing_tool_is_explicit(monkeypatch, tmp_path, runner):
    monkeypatch.setattr("shutil.which", lambda _: None)
    assert runner(tmp_path)["status"] == "unavailable"


def test_ruff_maps_findings(monkeypatch, tmp_path):
    only(monkeypatch, "ruff")
    payload = [
        {"code": "B006", "message": "mutable default", "filename": str(tmp_path / "a.py"), "location": {"row": 3}}
    ]

    def fake_run(command, **kwargs):
        assert "--isolated" in command and "--exit-zero" in command
        return SimpleNamespace(returncode=0, stdout=json.dumps(payload))

    monkeypatch.setattr("subprocess.run", fake_run)
    report = run_ruff(tmp_path)
    assert report["candidates"] == [
        {"rule": "ruff/B006", "file": "a.py", "line": 3, "explanation": "mutable default", "verified": False}
    ]


def test_biome_ignores_the_experimental_banner(monkeypatch, tmp_path):
    only(monkeypatch, "biome")
    payload = {'diagnostics': [{'category': 'lint/correctness/noUnusedVariables', 'message': 'unused',
                                'severity': 'warning', 'location': {'path': 'm.js', 'start': {'line': 1}}}]}  # fmt: skip
    output = "The json reporter is experimental.\n" + json.dumps(payload)
    monkeypatch.setattr("subprocess.run", lambda command, **kw: SimpleNamespace(returncode=1, stdout=output))
    report = run_biome(tmp_path)
    assert report["candidates"][0]["rule"] == "biome/correctness/noUnusedVariables"
    assert report["candidates"][0]["file"] == "m.js"


def test_lizard_reports_only_functions_over_the_limits(monkeypatch, tmp_path):
    only(monkeypatch, "lizard")
    rows = [
        f'52,26,182,1,52,"big@1-52@{tmp_path}/big.py","{tmp_path}/big.py","big","big( x )",1,52',
        f'3,1,8,0,3,"g@8-10@{tmp_path}/m.py","{tmp_path}/m.py","g","g( )",8,10',
    ]
    monkeypatch.setattr("subprocess.run", lambda command, **kw: SimpleNamespace(returncode=0, stdout="\n".join(rows)))
    report = run_lizard(tmp_path)
    assert report["functions_checked"] == 2
    assert [c["function"] for c in report["candidates"]] == ["big"]


def test_jscpd_never_stores_the_duplicated_code(monkeypatch, tmp_path):
    only(monkeypatch, "jscpd")
    secret_fragment = "def compute(values): SECRET_CODE"

    def fake_run(command, **kwargs):
        output = command[command.index("--output") + 1]
        report = {'duplicates': [{'firstFile': {'name': 'a.py', 'start': 1}, 'secondFile': {'name': 'b.py', 'start': 4},
                                  'lines': 23, 'fragment': secret_fragment}],
                  'statistics': {'total': {'duplicatedLines': 23, 'percentage': 12.5}}}  # fmt: skip
        (tmp_path.parent / "x").mkdir(exist_ok=True)
        with open(f"{output}/jscpd-report.json", "w", encoding="utf-8") as handle:
            json.dump(report, handle)
        return SimpleNamespace(returncode=0, stdout="")

    monkeypatch.setattr("subprocess.run", fake_run)
    report = run_jscpd(tmp_path)
    assert report["candidates"][0]["other_file"] == "b.py"
    assert report["duplicated_lines"] == 23
    assert "SECRET_CODE" not in json.dumps(report)


def test_tests_inventory_finds_languages_without_tests(tmp_path):
    for name in ("a.py", "b.py", "c.py", "tests/test_a.py", "web/x.js", "web/y.js", "web/z.js"):
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x = 1\n")
    report = inventory_of_tests(tmp_path)
    assert report["languages"]["Python"] == {"source_files": 3, "test_files": 1}
    assert report["languages_without_tests"] == ["JavaScript"]


@pytest.mark.parametrize(
    "path,expected",
    [("tests/test_a.py", True), ("src/a.test.ts", True), ("pkg/a_test.go", True), ("src/app.py", False)],
)
def test_is_test_file(path, expected):
    assert is_test_file(path) is expected


def test_one_broken_tool_does_not_stop_the_others(monkeypatch, tmp_path):
    def broken(root):
        raise RuntimeError("boom")

    monkeypatch.setattr(quality_checks, "run_ruff", broken)
    monkeypatch.setattr("shutil.which", lambda _: None)
    report = run_quality(tmp_path)
    assert report["lint_python"]["status"] == "failed"
    assert report["tests"]["status"] == "completed"


@pytest.mark.skipif(not shutil.which("ruff"), reason="Ruff not installed")
def test_real_ruff(tmp_path):
    (tmp_path / "m.py").write_text("def f(a=[]):\n    return undefined_name\n")
    rules = {c["rule"] for c in run_ruff(tmp_path)["candidates"]}
    assert {"ruff/B006", "ruff/F821"} <= rules
