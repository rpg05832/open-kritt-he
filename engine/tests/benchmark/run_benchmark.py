"""Quality benchmark for the local scanners.

Each folder here is a small project with planted weaknesses (listed in
expected.json) and SAFE counterpart files (listed under "clean"). The benchmark
copies every project to a temporary folder, fills fake secrets into *.template
files (no real-looking secret is stored in the repository), runs the same
adapters a real scan uses, and reports:
  * detection rate: planted weaknesses that were found
  * false positives: any finding in a clean file
Exit code 1 when the rates fall below thresholds.json.

    python tests/benchmark/run_benchmark.py [--json]
"""

import json
import random
import shutil
import string
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))

from open_kritt_engine.external_scanners import run_gitleaks, run_trivy_config  # noqa: E402
from open_kritt_engine.quality_checks import run_biome, run_jscpd, run_lizard, run_ruff  # noqa: E402
from open_kritt_engine.semgrep_checks import run_semgrep  # noqa: E402


def fake_secret(kind, rng):
    alphabet = string.ascii_letters + string.digits
    if kind == "github":
        return "ghp_" + "".join(rng.choice(alphabet) for _ in range(36))
    if kind == "stripe":
        return "sk_live_" + "".join(rng.choice(alphabet) for _ in range(32))
    if kind == "aws":
        return "AKIA" + "".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567") for _ in range(16))
    raise ValueError(kind)


def prepare(project, target, rng):
    shutil.copytree(project, target, ignore=shutil.ignore_patterns("expected.json"))
    for template in target.rglob("*.template"):
        text = template.read_text(encoding="utf-8")
        for kind in ("github", "stripe", "aws"):
            text = text.replace("{{SECRET:%s}}" % kind, fake_secret(kind, rng))
        template.with_suffix("").write_text(text, encoding="utf-8")
        template.unlink()
    # Real projects are Git repositories; this also exercises the history scan.
    subprocess.run(["git", "init", "-q", str(target)], check=True)
    subprocess.run(["git", "-C", str(target), "add", "."], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(target),
            "-c",
            "user.email=bench@example.invalid",
            "-c",
            "user.name=bench",
            "commit",
            "-qm",
            "benchmark",
        ],
        check=True,
    )


RUNNERS = {
    "semgrep": run_semgrep,
    "secrets": run_gitleaks,
    "configuration": run_trivy_config,
    "lint_python": run_ruff,
    "lint_javascript": run_biome,
    "complexity": run_lizard,
    "duplication": run_jscpd,
}
SECURITY_TOOLS = ["semgrep", "secrets", "configuration"]


def collect(root, tools=SECURITY_TOOLS):
    findings = []
    for tool in tools:
        report = RUNNERS[tool](root)
        if report["status"] != "completed":
            raise SystemExit(f'{tool} did not run: {report.get("reason")}')
        for item in report["candidates"]:
            rule = str(item["rule"]).split(".")[-1].split("/", 1)[-1]
            findings.append((tool, rule, item["file"]))
    return set(findings)


def run():
    rng = random.Random(20261030)
    thresholds = json.loads((HERE / "thresholds.json").read_text(encoding="utf-8"))
    total_expected = total_found = false_positives = 0
    projects = []
    with tempfile.TemporaryDirectory(prefix="kritt-benchmark-") as workspace:
        for project in sorted(p for p in HERE.iterdir() if (p / "expected.json").is_file()):
            spec = json.loads((project / "expected.json").read_text(encoding="utf-8"))
            target = Path(workspace) / project.name
            prepare(project, target, rng)
            findings = collect(target, spec.get("tools", SECURITY_TOOLS))
            expected = {(e["tool"], e["rule"], e["file"]) for e in spec["expected"]}
            missed = sorted(expected - findings)
            noise = sorted(f for f in findings if f[2] in spec["clean"])
            total_expected += len(expected)
            total_found += len(expected) - len(missed)
            false_positives += len(noise)
            projects.append(
                {
                    "project": project.name,
                    "expected": len(expected),
                    "found": len(expected) - len(missed),
                    "missed": missed,
                    "false_positives": noise,
                    "other_findings": sorted(findings - expected - set(noise)),
                }
            )
    rate = total_found / total_expected if total_expected else 0
    summary = {
        "detection_rate": round(rate, 3),
        "expected": total_expected,
        "found": total_found,
        "false_positives": false_positives,
        "projects": projects,
        "passed": rate >= thresholds["minimum_detection_rate"]
        and false_positives <= thresholds["maximum_false_positives"],
    }
    return summary


def main():
    summary = run()
    if "--json" in sys.argv:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print(
            f"זוהו {summary['found']} מתוך {summary['expected']} בעיות שתולות "
            f"({summary['detection_rate']:.0%}); התראות שווא בקבצים בטוחים: {summary['false_positives']}"
        )
        for project in summary["projects"]:
            print(
                f"  {project['project']}: {project['found']}/{project['expected']}"
                + (f", פוספסו: {project['missed']}" if project["missed"] else "")
                + (f", התראות שווא: {project['false_positives']}" if project["false_positives"] else "")
            )
    sys.exit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
