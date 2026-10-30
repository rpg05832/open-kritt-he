"""Tools installed on the user's machine at first start (not shipped in images).

Prebuilt images must not contain proprietary CLIs such as Claude Code, so the
engine installs the pinned version from the official npm registry into the
runtime volume (npm verifies the registry integrity hash). The volume is mounted
read-only into the backend and every scan runner, whose entrypoint adds its
bin directory to PATH. Images built locally with the CLIs baked in skip this.
"""

import json
import logging
import os
import shutil
import subprocess
from pathlib import Path

RUNTIME_ROOT = Path(os.environ.get("OPEN_KRITT_RUNTIME_DIR", "/opt/runtime-tools"))
PINS_FILE = Path(os.environ.get("OPEN_KRITT_TOOL_PINS", "/opt/scan-tools/security-tools.json"))
# Tools that may be installed at runtime: npm package -> command name.
RUNTIME_NPM_TOOLS = {"@anthropic-ai/claude-code": "claude"}
log = logging.getLogger(__name__)


def pinned_version(package, pins_file=PINS_FILE):
    try:
        pins = json.loads(Path(pins_file).read_text(encoding="utf-8")).get("pins", [])
    except (OSError, ValueError):
        return None
    return next((pin["version"] for pin in pins if pin.get("package") == package), None)


def installed_version(package, root=RUNTIME_ROOT):
    manifest = Path(root) / "npm" / "node_modules" / package / "package.json"
    try:
        return json.loads(manifest.read_text(encoding="utf-8")).get("version")
    except (OSError, ValueError):
        return None


def ensure_npm_tool(package, command, version, root=RUNTIME_ROOT, run=subprocess.run, timeout=600):
    """Install package@version into the runtime volume unless a usable copy exists."""
    root = Path(root)
    baked = shutil.which(command)
    if baked and not Path(baked).resolve().is_relative_to(root.resolve()):
        return {"status": "baked", "path": baked}
    if installed_version(package, root) == version and (root / "bin" / command).exists():
        return {"status": "current", "version": version}
    if not os.access(root, os.W_OK):
        return {"status": "read-only", "reason": "runtime volume is not writable here"}
    (root / "npm").mkdir(parents=True, exist_ok=True)
    (root / "bin").mkdir(parents=True, exist_ok=True)
    # npm 12 only runs install scripts of packages listed here (project installs
    # reject the --allow-scripts flag); only the tools we install are allowed.
    manifest = root / "npm" / "package.json"
    manifest.write_text(json.dumps({"private": True, "allowScripts": dict.fromkeys(RUNTIME_NPM_TOOLS, True)}))
    result = run(
        ["npm", "install", "--prefix", str(root / "npm"), "--no-audit", "--no-fund", "--omit=dev",
         f"{package}@{version}"],
        capture_output=True, text=True, timeout=timeout, check=False,
    )  # fmt: skip
    if result.returncode != 0:
        return {"status": "failed", "reason": (result.stderr or "")[-400:]}
    link = root / "bin" / command
    target = root / "npm" / "node_modules" / ".bin" / command
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(target)
    return {"status": "installed", "version": version}


def prepare_runtime_tools(root=RUNTIME_ROOT, pins_file=PINS_FILE, run=subprocess.run):
    """Called once at engine start; failures are logged and never stop the engine."""
    report = {}
    for package, command in RUNTIME_NPM_TOOLS.items():
        version = pinned_version(package, pins_file)
        if not version:
            report[command] = {"status": "skipped", "reason": "no pinned version"}
            continue
        try:
            report[command] = ensure_npm_tool(package, command, version, root=root, run=run)
        except (OSError, subprocess.SubprocessError) as error:
            report[command] = {"status": "failed", "reason": type(error).__name__}
        log.info("runtime tool %s: %s", command, report[command])
    for name, spec in vendor_specs(pins_file).items():
        if os.environ.get(spec["flag"]) != "1":
            continue
        try:
            report[name] = ensure_vendor_binary(name, spec, root=root)
        except (OSError, ValueError) as error:
            report[name] = {"status": "failed", "reason": str(error)[:300]}
        log.info("runtime tool %s: %s", name, report[name])
    return report


# ---------- optional proprietary CLIs (Cursor Agent, Grok Build) ----------
VENDOR_CACHE = Path(os.environ.get("OPEN_KRITT_VENDOR_CACHE", "/run/vendor-cache"))
ARCHITECTURES = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def vendor_specs(pins_file=PINS_FILE):
    try:
        return json.loads(Path(pins_file).read_text(encoding="utf-8")).get("runtimeVendors", {})
    except (OSError, ValueError):
        return {}


def _download(url, limit=400 * 1024 * 1024):
    import urllib.request

    request = urllib.request.Request(url, headers={"User-Agent": "open-kritt-runtime"})
    with urllib.request.urlopen(request, timeout=300) as response:  # TLS verified with the runtime bundle
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("download too large")
    return data


def ensure_vendor_binary(name, spec, root=RUNTIME_ROOT, cache=VENDOR_CACHE, download=_download):
    """Install a pinned vendor CLI from a verified local file or the official URL.

    The SHA-256 must equal the pinned official value whichever source is used,
    so a modified file is rejected and nothing is installed.
    """
    import hashlib
    import io
    import tarfile

    root = Path(root)
    command = spec["command"]
    baked = shutil.which(command)
    if baked and not Path(baked).resolve().is_relative_to(root.resolve()):
        return {"status": "baked", "path": baked}
    asset = spec["assets"][ARCHITECTURES.get(os.uname().machine, "amd64")]
    target_dir = root / "vendors" / name / spec["version"]
    executable = target_dir / command
    if executable.exists():
        _link_vendor(root, spec, executable)
        return {"status": "current", "version": spec["version"]}
    local = Path(cache) / asset["file"]
    data = local.read_bytes() if local.is_file() else download(asset["url"])
    digest = hashlib.sha256(data).hexdigest()
    if digest != asset["sha256"]:
        raise ValueError(f"{name}: SHA-256 {digest} does not match the pinned official value")
    staging = target_dir.with_name(target_dir.name + ".partial")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    if spec["format"] == "tar.gz":
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            for member in archive.getmembers():
                parts = Path(member.name).parts[1:]  # strip the top-level folder
                if not parts or member.issym() or member.islnk() or ".." in parts:
                    continue
                member.name = str(Path(*parts))
                archive.extract(member, staging, filter="data")
    else:
        (staging / command).write_bytes(data)
    (staging / command).chmod(0o755)
    shutil.rmtree(target_dir, ignore_errors=True)
    staging.rename(target_dir)
    _link_vendor(root, spec, executable)
    return {"status": "installed", "version": spec["version"], "source": "local file" if local.is_file() else "download"}


def _link_vendor(root, spec, executable):
    (root / "bin").mkdir(parents=True, exist_ok=True)
    for command in [spec["command"], *spec.get("aliases", [])]:
        link = root / "bin" / command
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(executable)
