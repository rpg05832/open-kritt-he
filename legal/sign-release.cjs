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
    // Read the zip with the same reader the maintenance agent uses (.NET ZipFile),
    // entry by entry, so what is verified is exactly what gets installed.
    const ps = [
      'Add-Type -AssemblyName System.IO.Compression.FileSystem',
      '$z=[IO.Compression.ZipFile]::OpenRead($env:K_ZIP); $list=@(); $i=0',
      'try { foreach($e in $z.Entries){ if($e.FullName.EndsWith([string][char]47) -and $e.Length -eq 0){continue}',
      ' $f=Join-Path $env:K_OUT ([string]$i); $s=$e.Open(); $o=[IO.File]::Create($f); try{$s.CopyTo($o)}finally{$o.Dispose();$s.Dispose()}',
      ' $list+=[pscustomobject]@{name=$e.FullName;file=[string]$i}; $i++ } } finally { $z.Dispose() }',
      '[IO.File]::WriteAllText((Join-Path $env:K_OUT "list.json"),(ConvertTo-Json -InputObject $list -Compress),(New-Object Text.UTF8Encoding $false))',
    ].join('; ');
    cp.execFileSync(process.platform === 'win32' ? 'powershell.exe' : 'pwsh', ['-NoProfile', '-Command', ps], { env: { ...process.env, K_ZIP: path.join(dir, 'u.zip'), K_OUT: out }, stdio: ['ignore', 'ignore', 'inherit'] });
    const entries = JSON.parse(fs.readFileSync(path.join(out, 'list.json'), 'utf8'));
    // Line endings may differ (CI checkout on Windows): drop only CR bytes that
    // directly precede LF; every other byte must match.
    const normalize = (data) => { const keep = []; for (let i = 0; i < data.length; i++) if (!(data[i] === 13 && data[i + 1] === 10)) keep.push(data[i]); return Buffer.from(keep); };
    const seen = new Set();
    let count = 0;
    for (const { name, file } of entries) {
      if (!/^app\/[A-Za-z0-9._@()+\-\/ ]+$/.test(name) || name.split('/').some((p) => p === '' || p === '.' || p === '..')) throw new Error('unexpected path in update package: ' + name);
      if (seen.has(name.toLowerCase())) throw new Error('duplicate entry in update package: ' + name);
      seen.add(name.toLowerCase());
      const data = fs.readFileSync(path.join(out, file));
      if (name === 'app/images.json' || name === 'app/legal/images.json') {
        const images = JSON.parse(data.toString('utf8').replace(/^﻿/, ''));
        const pin = new RegExp(`^ghcr\\.io/${repo.split('/')[0].toLowerCase()}/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$`);
        if (images.version !== tag || !Object.values(images.images || {}).every((v) => pin.test(v))) throw new Error(`images.json does not pin this repository's images for ${tag}`);
      } else {
        let expected;
        try { expected = gitQuiet('show', `${local}:${name.slice(4)}`); } catch { throw new Error('file not in tag ' + tag + ': ' + name); }
        if (!normalize(expected).equals(normalize(data))) throw new Error('file differs from tag ' + tag + ': ' + name);
      }
      count++;
    }
    console.error(`verified ${count} files against ${tag} (${local})`);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

(async () => {
  const release = await (await api(`https://api.github.com/repos/${repo}/releases/tags/${encodeURIComponent(tag)}`)).json();
  const zip = release.assets.find((a) => a.name === 'open-kritt-hebrew-update.zip');
  if (!zip) throw new Error('the release has no open-kritt-hebrew-update.zip');
  if (!dryRun && release.assets.some((a) => a.name === NAME)) throw new Error(`${NAME} already exists on this release; nothing to do`);
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
