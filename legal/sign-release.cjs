// Signs a published release's update package on the publisher's computer and
// uploads the signed manifest (like Tzevet's `release.mjs --publish`).
// The private key never leaves this computer.
//
// Usage: node legal/sign-release.cjs <tag> [owner/repo] [--dry-run]
// Needs: the private key (OPEN_KRITT_UPDATE_PRIVATE_KEY_FILE, default
//        <installation root>/keys/update-private.pem) and a GitHub token with
//        contents:write (GITHUB_TOKEN, or GITHUB_TOKEN_FILE).
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const { signManifest } = require('./update-signing.cjs');

const dryRun = process.argv.includes('--dry-run');
const [tag, repoArg] = process.argv.slice(2).filter((a) => a !== '--dry-run');
if (!tag) throw new Error('usage: node legal/sign-release.cjs <tag> [owner/repo]');
const root = path.resolve(__dirname, '..');
const repo = repoArg || JSON.parse(fs.readFileSync(path.join(root, 'update-source.json'), 'utf8')).repository;
if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo || '')) throw new Error('no repository: pass owner/repo or set update-source.json');
const keyFile = process.env.OPEN_KRITT_UPDATE_PRIVATE_KEY_FILE || path.join(root, '..', 'keys', 'update-private.pem');
const token = (process.env.GITHUB_TOKEN || fs.readFileSync(process.env.GITHUB_TOKEN_FILE, 'utf8')).trim();
const headers = { Authorization: 'Bearer ' + token, 'User-Agent': 'open-kritt-sign-release', Accept: 'application/vnd.github+json' };
const NAME = 'open-kritt-hebrew-update.json';

async function api(url, options = {}) {
  const res = await fetch(url, { ...options, headers: { ...headers, ...(options.headers || {}) } });
  if (!res.ok) throw new Error(`${options.method || 'GET'} ${url} -> HTTP ${res.status}`);
  return res;
}

// Never sign blindly what CI produced: the GitHub tag must be the commit we have
// here, and every file in the zip must be identical to that commit (ignoring
// CRLF/LF line endings). The one generated file,
// app/images.json, may only pin this repository's GHCR images by digest.
async function verifyAgainstTag(zipBytes) {
  const cp = require('child_process'), os = require('os');
  const git = (...args) => cp.execFileSync('git', args, { cwd: root, maxBuffer: 64 * 1024 * 1024 });
  const gitQuiet = (...args) => cp.execFileSync('git', args, { cwd: root, maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] });
  const local = git('rev-parse', `${tag}^{commit}`).toString().trim();
  const ref = await (await api(`https://api.github.com/repos/${repo}/git/ref/tags/${encodeURIComponent(tag)}`)).json();
  let remote = ref.object.sha;
  if (ref.object.type === 'tag') remote = (await (await api(ref.object.url)).json()).object.sha;
  if (remote !== local) throw new Error(`tag ${tag} on GitHub (${remote}) is not the local commit (${local})`);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kritt-verify-'));
  try {
    fs.writeFileSync(path.join(dir, 'u.zip'), zipBytes);
    const out = path.join(dir, 'x'); fs.mkdirSync(out);
    // bsdtar reads zip; on Windows use the system one (Git's GNU tar cannot).
    const tar = process.platform === 'win32' ? path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'tar.exe') : 'bsdtar';
    cp.execFileSync(tar, ['-xf', path.join(dir, 'u.zip'), '-C', out]);
    // Line endings may differ (CI checkout on Windows); content may not.
    const normalize = (data) => (data.includes(0) ? data : Buffer.from(data.toString('utf8').replace(/\r\n/g, '\n'), 'utf8'));
    let count = 0;
    (function walk(folder, rel) {
      for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
        const name = rel ? rel + '/' + entry.name : entry.name;
        if (entry.isSymbolicLink()) throw new Error('symbolic link in update package: ' + name);
        if (entry.isDirectory()) { walk(path.join(folder, entry.name), name); continue; }
        const data = fs.readFileSync(path.join(folder, entry.name));
        if (name === 'app/images.json' || name === 'app/legal/images.json') {
          const images = JSON.parse(data.toString('utf8').replace(/^﻿/, ''));
          const pin = new RegExp(`^ghcr\\.io/${repo.split('/')[0].toLowerCase()}/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$`);
          if (images.version !== tag || !Object.values(images.images || {}).every((v) => pin.test(v))) throw new Error('images.json does not pin this repository\'s images for ' + tag);
        } else {
          if (!name.startsWith('app/')) throw new Error('unexpected path in update package: ' + name);
          let expected;
          try { expected = gitQuiet('show', `${local}:${name.slice(4)}`); } catch { throw new Error('file not in tag ' + tag + ': ' + name); }
          if (!normalize(expected).equals(normalize(data))) throw new Error('file differs from tag ' + tag + ': ' + name);
        }
        count++;
      }
    })(out, '');
    console.error(`verified ${count} files against ${tag} (${local})`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

(async () => {
  const release = await (await api(`https://api.github.com/repos/${repo}/releases/tags/${encodeURIComponent(tag)}`)).json();
  const zip = release.assets.find((a) => a.name === 'open-kritt-hebrew-update.zip');
  if (!zip) throw new Error('the release has no open-kritt-hebrew-update.zip');
  if (release.assets.some((a) => a.name === NAME)) throw new Error(`${NAME} already exists on this release; nothing to do`);
  // Download the exact file users will download, and hash it here.
  const bytes = Buffer.from(await (await api(zip.url, { headers: { Accept: 'application/octet-stream' } })).arrayBuffer());
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  await verifyAgainstTag(bytes);
  const manifest = { distribution: 'open-kritt-hebrew', format: 2, version: tag, sha256 };
  manifest.signature = signManifest(manifest, fs.readFileSync(keyFile, 'utf8'));
  if (dryRun) { console.log(JSON.stringify({ tag, repo, sha256, verified: true, uploaded: false })); return; }
  const upload = release.upload_url.replace(/\{.*\}$/, '') + '?name=' + encodeURIComponent(NAME);
  await api(upload, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(manifest, null, 2) });
  console.log(JSON.stringify({ tag, repo, sha256, signed: true, uploaded: NAME }));
})().catch((e) => { console.error('sign-release failed:', e.message); process.exit(1); });
