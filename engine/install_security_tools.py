"""Build-time installer for the pinned security tools in security-tools.json.

Every download is checked against the SHA-256 recorded in the manifest (taken
from the vendor's official checksum list); any mismatch stops the image build.
TLS verification stays on and uses the system CA bundle.
"""

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

MANIFEST = Path(__file__).with_name("security-tools.json")
DESTINATION = Path(os.environ.get("SECURITY_TOOLS_BIN", "/opt/scan-tools/bin"))
ARCHITECTURES = {"amd64": "amd64", "x86_64": "amd64", "arm64": "arm64", "aarch64": "arm64"}


def download(url, limit=300 * 1024 * 1024):
    request = urllib.request.Request(url, headers={"User-Agent": "open-kritt-build"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise SystemExit(f"download too large: {url}")
    return data


def extract_binary(data, fmt, name):
    if fmt == "binary":
        return data
    if fmt != "tar.gz":
        raise SystemExit(f"unsupported archive format: {fmt}")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            if member.isfile() and Path(member.name).name == name:
                return archive.extractfile(member).read()
    raise SystemExit(f"{name} not found in archive")


def link_binary(target, name):
    link = Path("/usr/local/bin") / name
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(target)


def install(only=None):
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    arch = ARCHITECTURES.get(os.environ.get("TARGETARCH") or os.uname().machine)
    if not arch:
        raise SystemExit("unsupported architecture for security tools")
    DESTINATION.mkdir(parents=True, exist_ok=True)
    for name, tool in manifest["tools"].items():
        if only and name not in only:
            continue
        if "pypi" in tool:
            # pip verifies the published hashes of the exact pinned version.
            pip = os.environ.get("SECURITY_TOOLS_PIP", "/opt/security-tools/bin/pip")
            subprocess.run([pip, "install", "--no-cache-dir", f"{tool['pypi']}=={tool['version']}"], check=True)
            if tool.get("binary"):
                link_binary(Path(pip).parent / tool["binary"], tool["binary"])
            continue
        if "npm" in tool:
            # npm verifies the registry's integrity hash (sha512) of the exact pinned version.
            subprocess.run(
                ["npm", "install", "--global", "--no-audit", "--no-fund", f"{tool['npm']}@{tool['version']}"],
                check=True,
            )
            continue
        asset = tool["assets"][arch]
        data = download(asset["url"])
        digest = hashlib.sha256(data).hexdigest()
        if digest != asset["sha256"]:
            raise SystemExit(f'SHA-256 mismatch for {name}: expected {asset["sha256"]}, got {digest}')
        target = DESTINATION / tool["binary"]
        target.write_bytes(extract_binary(data, asset["format"], tool["binary"]))
        target.chmod(0o755)
        link_binary(target, tool["binary"])
        version = subprocess.run([str(target), "--version"], capture_output=True, text=True, timeout=60)
        if version.returncode != 0:
            raise SystemExit(f"{name} does not run: {version.stderr.strip()[:200]}")
        print(f'installed {name} {tool["version"]} ({digest[:12]})')
    shutil.copyfile(MANIFEST, DESTINATION.parent / "security-tools.json")


if __name__ == "__main__":
    install(set(sys.argv[1:]) or None)
