"""Every rule in security_rules.json must report each "ruleid:" line of the
fixtures in tests/rule_fixtures and must not report any "ok:" line."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
RULES = ROOT / "open_kritt_engine" / "security_rules.json"
FIXTURES = Path(__file__).with_name("rule_fixtures")
ANNOTATION = re.compile(r"(?:#|//|/\*)\s*(ruleid|ok):\s*([\w-]+)")


def expectations():
    expected, forbidden = set(), set()
    for file in FIXTURES.iterdir():
        lines = file.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, start=1):
            match = ANNOTATION.search(line)
            if match:
                target = (file.name, number + 1, match.group(2))
                (expected if match.group(1) == "ruleid" else forbidden).add(target)
    return expected, forbidden


def test_rules_are_unique_and_explained_in_hebrew():
    rules = json.loads(RULES.read_text(encoding="utf-8"))["rules"]
    ids = [rule["id"] for rule in rules]
    assert len(ids) == len(set(ids))
    for rule in rules:
        assert re.search("[֐-׿]", rule["message"]), rule["id"]
        assert rule["severity"] in {"INFO", "WARNING", "ERROR"}


def test_every_rule_has_a_positive_fixture():
    rules = {rule["id"] for rule in json.loads(RULES.read_text(encoding="utf-8"))["rules"]}
    expected, _ = expectations()
    assert rules - {rule for _, _, rule in expected} == set()


@pytest.mark.skipif(not shutil.which("semgrep"), reason="Semgrep not installed")
def test_rules_match_fixtures_exactly():
    result = subprocess.run(
        [
            "semgrep",
            "scan",
            "--config",
            str(RULES),
            "--json",
            "--metrics=off",
            "--disable-version-check",
            "--no-git-ignore",
            str(FIXTURES),
        ],
        capture_output=True,
        text=True,
        timeout=300,
        check=False,
    )
    payload = json.loads(result.stdout)
    assert not payload.get("errors"), payload.get("errors")
    found = {
        (Path(item["path"]).name, item["start"]["line"], item["check_id"].split(".")[-1]) for item in payload["results"]
    }
    expected, forbidden = expectations()
    assert expected - found == set(), "missed"
    assert forbidden & found == set(), "false positives"
