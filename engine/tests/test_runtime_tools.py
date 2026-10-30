import json
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from open_kritt_engine import runtime_tools
from open_kritt_engine.runtime_tools import ensure_npm_tool, pinned_version, prepare_runtime_tools

ENGINE = Path(__file__).resolve().parents[1]
APP = ENGINE.parent


def test_pinned_version_reads_the_shared_manifest():
    assert pinned_version("@anthropic-ai/claude-code", ENGINE / "security-tools.json")
    assert pinned_version("not-a-tool", ENGINE / "security-tools.json") is None


def test_baked_cli_is_left_alone(monkeypatch, tmp_path):
    monkeypatch.setattr("shutil.which", lambda name: "/usr/local/bin/claude")
    assert ensure_npm_tool("@anthropic-ai/claude-code", "claude", "1.0.0", root=tmp_path)["status"] == "baked"


def test_installs_pinned_version_into_runtime_volume(monkeypatch, tmp_path):
    monkeypatch.setattr("shutil.which", lambda name: None)
    calls = []

    def fake_npm(command, **kwargs):
        calls.append(command)
        package_dir = tmp_path / "npm" / "node_modules" / "@anthropic-ai" / "claude-code"
        package_dir.mkdir(parents=True)
        (package_dir / "package.json").write_text(json.dumps({"version": "2.1.215"}))
        (tmp_path / "npm" / "node_modules" / ".bin").mkdir(parents=True)
        (tmp_path / "npm" / "node_modules" / ".bin" / "claude").write_text("#!/bin/sh\n")
        return SimpleNamespace(returncode=0, stderr="")

    report = ensure_npm_tool("@anthropic-ai/claude-code", "claude", "2.1.215", root=tmp_path, run=fake_npm)
    assert report == {"status": "installed", "version": "2.1.215"}
    assert calls[0][:3] == ["npm", "install", "--prefix"]
    assert "@anthropic-ai/claude-code@2.1.215" in calls[0]
    assert (tmp_path / "bin" / "claude").is_symlink()
    again = ensure_npm_tool("@anthropic-ai/claude-code", "claude", "2.1.215", root=tmp_path, run=fake_npm)
    assert again["status"] == "current" and len(calls) == 1


def test_failures_never_stop_the_engine(monkeypatch, tmp_path):
    monkeypatch.setattr("shutil.which", lambda name: None)

    def broken(command, **kwargs):
        raise subprocess.TimeoutExpired(command, 1)

    pins = tmp_path / "pins.json"
    pins.write_text(json.dumps({"pins": [{"package": "@anthropic-ai/claude-code", "version": "2.1.215"}]}))
    report = prepare_runtime_tools(root=tmp_path, pins_file=pins, run=broken)
    assert report["claude"]["status"] == "failed"


def test_runtime_entrypoint_copies_are_identical():
    copies = {(APP / service / "runtime-env.sh").read_bytes().replace(b"\r\n", b"\n") for service in
              ("engine", "backend", "executor-view")}  # fmt: skip
    assert len(copies) == 1


@pytest.mark.skipif(not shutil.which("sh"), reason="POSIX shell not available")
def test_runtime_entrypoint_appends_approved_certificates(tmp_path):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    script = (ENGINE / "runtime-env.sh").read_text().replace("/run/approved-ca", str(tmp_path / "approved"))
    script = script.replace("/etc/ssl/certs/ca-certificates.crt", str(tmp_path / "system.pem"))
    (tmp_path / "approved").mkdir()
    (tmp_path / "approved" / "net.crt").write_text("APPROVED\n")
    (tmp_path / "system.pem").write_text("SYSTEM\n")
    (tmp_path / "env.sh").write_text(script)
    result = subprocess.run(
        ["sh", str(tmp_path / "env.sh"), "sh", "-c", 'cat "$SSL_CERT_FILE"; echo "$NODE_EXTRA_CA_CERTS"'],
        capture_output=True, text=True, env={"OPEN_KRITT_RUNTIME_DIR": str(runtime), "PATH": "/usr/bin:/bin"},
        check=True,
    )  # fmt: skip
    assert result.stdout.splitlines()[:2] == ["SYSTEM", "APPROVED"]
    assert result.stdout.splitlines()[2] == str(runtime / "ca" / "bundle.pem")


def test_scan_runners_mount_the_runtime_volume_read_only(monkeypatch):
    from open_kritt_engine import harnesses

    source = Path(harnesses.__file__).read_text(encoding="utf-8")
    assert "ENGINE_RUNTIME_TOOLS_VOLUME" in source
    assert "readonly" in source
    for key in ("REQUESTS_CA_BUNDLE", "GIT_SSL_CAINFO", "npm_config_cafile"):
        assert f'"{key}"' in source


def test_module_defaults():
    assert runtime_tools.RUNTIME_NPM_TOOLS == {"@anthropic-ai/claude-code": "claude"}


def _spec(data, fmt="binary", command="grok"):
    import hashlib

    asset = {"file": "tool-1.0", "url": "https://example.invalid/tool", "sha256": hashlib.sha256(data).hexdigest()}
    return {"flag": "INSTALL_GROK", "command": command, "aliases": ["alias"], "version": "1.0", "format": fmt,
            "assets": {"amd64": asset, "arm64": asset}}  # fmt: skip


def test_vendor_binary_from_verified_local_file(monkeypatch, tmp_path):
    from open_kritt_engine.runtime_tools import ensure_vendor_binary

    monkeypatch.setattr("shutil.which", lambda name: None)
    data = b"#!/bin/sh\necho grok\n"
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / "tool-1.0").write_bytes(data)

    def no_network(url):
        raise AssertionError("must not download when a verified local file exists")

    report = ensure_vendor_binary("grok", _spec(data), root=tmp_path / "rt", cache=cache, download=no_network)
    assert report["status"] == "installed" and report["source"] == "local file"
    assert (tmp_path / "rt" / "bin" / "grok").resolve().read_bytes() == data
    assert (tmp_path / "rt" / "bin" / "alias").is_symlink()


def test_vendor_binary_rejects_a_modified_file(monkeypatch, tmp_path):
    from open_kritt_engine.runtime_tools import ensure_vendor_binary

    monkeypatch.setattr("shutil.which", lambda name: None)
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / "tool-1.0").write_bytes(b"tampered")
    with pytest.raises(ValueError, match="does not match"):
        ensure_vendor_binary("grok", _spec(b"original"), root=tmp_path / "rt", cache=cache)
    assert not (tmp_path / "rt" / "bin" / "grok").exists()


def test_vendor_archive_is_extracted_without_its_top_folder(monkeypatch, tmp_path):
    import io
    import tarfile

    from open_kritt_engine.runtime_tools import ensure_vendor_binary

    monkeypatch.setattr("shutil.which", lambda name: None)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, content in (("dist-package/cursor-agent", b"#!/bin/sh\n"), ("dist-package/lib/x.js", b"1")):
            info = tarfile.TarInfo(name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
    data = buffer.getvalue()
    report = ensure_vendor_binary("cursor", _spec(data, "tar.gz", "cursor-agent"), root=tmp_path / "rt",
                                  cache=tmp_path / "none", download=lambda url: data)  # fmt: skip
    assert report["source"] == "download"
    assert (tmp_path / "rt" / "vendors" / "cursor" / "1.0" / "lib" / "x.js").exists()
    assert (tmp_path / "rt" / "bin" / "cursor-agent").exists()


def test_runtime_vendor_pins_match_the_engine_dockerfile():
    import re

    dockerfile = (ENGINE / "Dockerfile").read_text(encoding="utf-8")
    vendors = json.loads((ENGINE / "security-tools.json").read_text(encoding="utf-8"))["runtimeVendors"]
    assert f"ARG CURSOR_AGENT_VERSION={vendors['cursor']['version']}" in dockerfile
    assert f"ARG GROK_BUILD_VERSION={vendors['grok']['version']}" in dockerfile
    for spec in vendors.values():
        for asset in spec["assets"].values():
            assert re.search(asset["sha256"], dockerfile), asset["file"]
