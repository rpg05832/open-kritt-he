// Signs a published release's update package on the publisher's computer and
// uploads the signed manifest (like Tzevet's `release.mjs --publish`).
// The private key never leaves this computer.
//
// Usage: node legal/sign-release.cjs <tag> [owner/repo]
// Needs: the private key (OPEN_KRITT_UPDATE_PRIVATE_KEY_FILE, default
//        <installation root>/keys/update-private.pem) and a GitHub token with
//        contents:write (GITHUB_TOKEN, or GITHUB_TOKEN_FILE).
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const { signManifest } = require('./update-signing.cjs');

const [tag, repoArg] = process.argv.slice(2);
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

(async () => {
  const release = await (await api(`https://api.github.com/repos/${repo}/releases/tags/${encodeURIComponent(tag)}`)).json();
  const zip = release.assets.find((a) => a.name === 'open-kritt-hebrew-update.zip');
  if (!zip) throw new Error('the release has no open-kritt-hebrew-update.zip');
  if (release.assets.some((a) => a.name === NAME)) throw new Error(`${NAME} already exists on this release; nothing to do`);
  // Download the exact file users will download, and hash it here.
  const bytes = Buffer.from(await (await api(zip.url, { headers: { Accept: 'application/octet-stream' } })).arrayBuffer());
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const manifest = { distribution: 'open-kritt-hebrew', format: 2, version: tag, sha256 };
  manifest.signature = signManifest(manifest, fs.readFileSync(keyFile, 'utf8'));
  const upload = release.upload_url.replace(/\{.*\}$/, '') + '?name=' + encodeURIComponent(NAME);
  await api(upload, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(manifest, null, 2) });
  console.log(JSON.stringify({ tag, repo, sha256, signed: true, uploaded: NAME }));
})().catch((e) => { console.error('sign-release failed:', e.message); process.exit(1); });
