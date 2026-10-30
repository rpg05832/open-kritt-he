import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("install_security_tools", ROOT / "install_security_tools.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def test_manifest_pins_official_checksums_for_every_architecture():
    manifest = json.loads((ROOT / "security-tools.json").read_text(encoding="utf-8"))
    assert manifest["policy"]["minimumAgeDays"] >= 14
    for tool in manifest["tools"].values():
        assert tool["license"] and tool["version"]
        if "pypi" in tool or "npm" in tool:  # verified by pip and npm integrity hashes
            continue
        for arch in ("amd64", "arm64"):
            asset = tool["assets"][arch]
            assert asset["url"].startswith("https://github.com/" + tool["repository"] + "/releases/download/")
            assert len(asset["sha256"]) == 64


def test_checksum_mismatch_stops_the_build(monkeypatch, tmp_path):
    manifest = {
        "tools": {
            "demo": {
                "binary": "demo",
                "version": "1.0.0",
                "assets": {
                    "amd64": {
                        "url": "https://example.invalid/demo",
                        "sha256": hashlib.sha256(b"good").hexdigest(),
                        "format": "binary",
                    }
                },
            }
        }
    }
    path = tmp_path / "security-tools.json"
    path.write_text(json.dumps(manifest))
    monkeypatch.setattr(installer, "MANIFEST", path)
    monkeypatch.setattr(installer, "DESTINATION", tmp_path / "bin")
    monkeypatch.setenv("TARGETARCH", "amd64")
    monkeypatch.setattr(installer, "download", lambda url: b"tampered")
    with pytest.raises(SystemExit, match="SHA-256 mismatch"):
        installer.install()
    assert not (tmp_path / "bin" / "demo").exists()
