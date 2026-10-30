import importlib.util
import shutil
from pathlib import Path

import pytest

TOOLS = ("semgrep", "gitleaks", "trivy", "git", "ruff", "biome", "lizard", "jscpd")


@pytest.mark.skipif(not all(shutil.which(tool) for tool in TOOLS), reason="local scanners not installed")
def test_benchmark_meets_thresholds():
    path = Path(__file__).with_name("benchmark") / "run_benchmark.py"
    spec = importlib.util.spec_from_file_location("run_benchmark", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    summary = module.run()
    details = [(p["project"], p["missed"], p["false_positives"]) for p in summary["projects"]]
    assert summary["passed"], details
