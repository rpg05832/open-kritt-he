#!/usr/bin/env node
// Refreshes pinned tool versions to the newest STABLE release that is at least
// `policy.minimumAgeDays` old (default 14), so a freshly published (possibly
// compromised or broken) release is never picked up.
//
//   node scripts/update-security-tools.mjs          # report only
//   node scripts/update-security-tools.mjs --apply  # rewrite the pins
//
// Sources:
//   engine/security-tools.json "tools"  GitHub releases (+ official SHA-256 list) and PyPI
//   engine/security-tools.json "pins"   npm packages pinned inside Dockerfiles/tests
// Behind a TLS-inspecting filter run Node with --use-system-ca (Node 22.15+).
// After --apply, rebuild and run all tests before publishing anything.
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(root, 'engine', 'security-tools.json');
const apply = process.argv.includes('--apply');
const headers = { 'User-Agent': 'open-kritt-tool-updater', Accept: 'application/json' };
if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;

export function parseVersion(value) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(value);
  return match ? match.slice(1).map(Number) : null; // pre-releases and odd tags are skipped
}
export function compareVersions(a, b) {
  const x = parseVersion(a), y = parseVersion(b);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}
// Newest stable version whose publication date is on or before the cutoff.
export function pickVersion(published, cutoff) {
  return Object.entries(published)
    .filter(([version, date]) => parseVersion(version) && date && new Date(date) <= cutoff)
    .sort(([a], [b]) => compareVersions(b, a))[0] || null;
}

async function json(url) {
  const response = await fetch(url, { headers });
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.json();
}
async function text(url) {
  const response = await fetch(url, { headers: { 'User-Agent': headers['User-Agent'] } });
  if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
  return response.text();
}

// Asset and checksum-file names per GitHub tool; {v} is the version without "v".
const GITHUB_LAYOUT = {
  gitleaks: { checksums: 'gitleaks_{v}_checksums.txt', amd64: ['gitleaks_{v}_linux_x64.tar.gz', 'tar.gz'], arm64: ['gitleaks_{v}_linux_arm64.tar.gz', 'tar.gz'] },
  'osv-scanner': { checksums: 'osv-scanner_SHA256SUMS', amd64: ['osv-scanner_linux_amd64', 'binary'], arm64: ['osv-scanner_linux_arm64', 'binary'] },
  trivy: { checksums: 'trivy_{v}_checksums.txt', amd64: ['trivy_{v}_Linux-64bit.tar.gz', 'tar.gz'], arm64: ['trivy_{v}_Linux-ARM64.tar.gz', 'tar.gz'] },
};

async function latestGithub(name, tool, cutoff) {
  const layout = GITHUB_LAYOUT[name];
  const releases = await json(`https://api.github.com/repos/${tool.repository}/releases?per_page=40`);
  const stable = Object.fromEntries(
    releases.filter((r) => !r.draft && !r.prerelease).map((r) => [r.tag_name.replace(/^v/, ''), r.published_at])
  );
  const picked = pickVersion(stable, cutoff);
  if (!picked) return null;
  const [version, released] = picked;
  const release = releases.find((r) => r.tag_name.replace(/^v/, '') === version);
  const fill = (s) => s.replaceAll('{v}', version);
  const sumsAsset = release.assets.find((a) => a.name === fill(layout.checksums));
  if (!sumsAsset) throw new Error(`${name} ${version}: official checksum list not found`);
  const sums = Object.fromEntries(
    (await text(sumsAsset.browser_download_url))
      .split('\n')
      .map((line) => line.trim().split(/\s+\*?/))
      .filter((parts) => /^[a-f0-9]{64}$/.test(parts[0]))
      .map(([hash, file]) => [file, hash])
  );
  const assets = {};
  for (const arch of ['amd64', 'arm64']) {
    const [file, format] = layout[arch];
    const asset = release.assets.find((a) => a.name === fill(file));
    if (!asset || !sums[fill(file)]) throw new Error(`${name} ${version}: ${arch} asset or checksum missing`);
    assets[arch] = { url: asset.browser_download_url, sha256: sums[fill(file)], format };
  }
  return { version, released: released.slice(0, 10), assets };
}

async function latestPypi(tool, cutoff) {
  const data = await json(`https://pypi.org/pypi/${tool.pypi}/json`);
  const published = {};
  for (const [version, files] of Object.entries(data.releases)) {
    const usable = files.filter((f) => !f.yanked);
    if (usable.length) published[version] = usable.map((f) => f.upload_time_iso_8601).sort()[0];
  }
  const picked = pickVersion(published, cutoff);
  return picked && { version: picked[0], released: picked[1].slice(0, 10) };
}

async function latestNpm(pin, cutoff) {
  const data = await json(`https://registry.npmjs.org/${pin.package.replace('/', '%2F')}`);
  const published = Object.fromEntries(Object.entries(data.time).filter(([v]) => data.versions?.[v] && !data.versions[v].deprecated));
  const picked = pickVersion(published, cutoff);
  return picked && { version: picked[0], released: picked[1].slice(0, 10) };
}

async function main() {
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  const days = manifest.policy?.minimumAgeDays ?? 14;
  const cutoff = new Date(Date.now() - days * 86400000);
  const changes = [];
  for (const [name, tool] of Object.entries(manifest.tools)) {
    const latest = tool.pypi
      ? await latestPypi(tool, cutoff)
      : tool.npm
        ? await latestNpm({ package: tool.npm }, cutoff)
        : await latestGithub(name, tool, cutoff);
    if (!latest) { console.log(`${name}: no stable release older than ${days} days`); continue; }
    if (latest.version === tool.version) { console.log(`${name}: ${tool.version} is current`); if (tool.released === 'unknown') tool.released = latest.released; continue; }
    if (compareVersions(latest.version, tool.version) < 0) { console.log(`${name}: keeping ${tool.version} (newer than the eligible ${latest.version})`); continue; }
    changes.push(`${name}: ${tool.version} -> ${latest.version} (released ${latest.released})`);
    Object.assign(tool, latest);
  }
  for (const pin of manifest.pins || []) {
    const latest = await latestNpm(pin, cutoff);
    if (!latest || compareVersions(latest.version, pin.version) <= 0) { console.log(`${pin.package}: ${pin.version} is current`); continue; }
    changes.push(`${pin.package}: ${pin.version} -> ${latest.version} (released ${latest.released})`);
    if (apply) {
      for (const file of pin.files) {
        const full = path.join(root, file);
        const before = await readFile(full, 'utf8');
        const after = before.replaceAll(`${pin.package}@${pin.version}`, `${pin.package}@${latest.version}`);
        if (after === before) throw new Error(`${file} does not pin ${pin.package}@${pin.version}`);
        await writeFile(full, after);
      }
    }
    Object.assign(pin, latest);
  }
  console.log(changes.length ? 'Updates:\n  ' + changes.join('\n  ') : 'Everything is current.');
  if (apply && changes.length) {
    await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
    console.log('Pins rewritten. Rebuild the images and run every test suite before publishing.');
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((error) => { console.error(error.message); process.exit(1); });
}
