// Builds the Hebrew source-install distribution into a NEW empty folder.
// Usage: node legal/build-distribution.cjs [outputFolder] [--zip]
// Nothing in the source tree is modified. app/windows is the source of truth for
// the Windows scripts that are placed next to the app folder.
const fs = require('fs'), path = require('path'), crypto = require('crypto'), cp = require('child_process');
const root = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const makeZip = args.includes('--zip');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim().split(' ')[0]; // the file may carry a release-please comment
const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, '.');
const releaseName = `סריקת-אבטחה-${stamp}-v${version}-he`;
const output = path.resolve(args.find((a) => !a.startsWith('--')) || path.join(root, '..', 'distribution', releaseName));
if (fs.existsSync(output) && fs.readdirSync(output).length) throw new Error('Choose a new empty output directory: ' + output);
fs.mkdirSync(path.join(output, 'app'), { recursive: true });

const excluded = new Set(['.git', '.github', '.data', 'node_modules', 'local_repos', 'local-certs', 'local-tools', '__pycache__', '.pytest_cache', 'dist', 'build', 'coverage', '.vite', '.ruff_cache', '.mypy_cache']);
const allowedRoots = new Set(['frontend', 'backend', 'engine', 'executor-view', 'database', 'legal', 'windows', 'assets', 'scripts', 'docs', 'docs-site']);
const rootFiles = new Set(['LICENSE', 'NOTICE.md', 'OWNERSHIP.md', 'CONTRIBUTION_TERMS.md', 'THIRD_PARTY_NOTICES.md', 'README.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'CHANGELOG.md', 'VERSION', '.env.example', '.gitignore', '.gitattributes', '.editorconfig', '.prettierrc.json', '.prettierignore', 'docker-compose.yml', 'docker-compose.dev.yml', 'kritt', 'kritt-headless']);
const rejected = /\.(exe|dll|so|node|whl|dump|sqlite\d*|db|zip|tar|gz|tgz|crt|cer|pem|key|p12|pfx|log|pyc)$/i;
// Local helper scripts of the previous session; not part of the product.
const skipped = new Set(['backend/audit-scan.mjs', 'backend/upgrade-current-preset.mjs', 'frontend/extract-ui.mjs', 'frontend/ui-strings.json']);

// Text files go out with LF (Linux containers run them) except Windows scripts,
// which get CRLF and a UTF-8 BOM (Windows PowerShell 5.1 needs the BOM for Hebrew).
function normalize(rel, buffer) {
  if (buffer.includes(0)) return buffer; // binary
  let text = buffer.toString('utf8').replace(/^﻿/, '');
  if (/\.(ps1|cmd|bat)$/i.test(rel)) {
    text = text.replace(/\r?\n/g, '\r\n');
    return Buffer.from((/\.ps1$/i.test(rel) ? '﻿' : '') + text, 'utf8');
  }
  const hadBom = buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf;
  return Buffer.from((hadBom ? '﻿' : '') + text.replace(/\r\n/g, '\n'), 'utf8');
}
function put(rel, buffer) {
  const destination = path.join(output, rel);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, normalize(rel, buffer));
}
function walk(folder, relative = '') {
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const rel = relative ? relative + '/' + entry.name : entry.name;
    if (entry.isSymbolicLink() || excluded.has(entry.name)) continue;
    if (entry.isDirectory()) {
      if (!relative && !allowedRoots.has(entry.name)) continue;
      walk(path.join(folder, entry.name), rel);
      continue;
    }
    if (!relative && !rootFiles.has(entry.name)) continue;
    if ((entry.name.startsWith('.env') && rel !== '.env.example') || rejected.test(entry.name) || skipped.has(rel) || !entry.isFile()) continue;
    put('app/' + rel, fs.readFileSync(path.join(folder, entry.name)));
  }
}
walk(root);

// Empty build-context folders: certificates are only added by the user's own approval.
for (const component of ['frontend', 'backend', 'engine', 'database', 'executor-view']) put(`app/${component}/local-certs/.gitkeep`, Buffer.alloc(0));
put('app/local_repos/.gitkeep', Buffer.alloc(0));
// Verified vendor files (Cursor/Grok) stay on the publishing computer; only the empty folder ships.
put('app/vendor-cache/.gitkeep', Buffer.alloc(0));
put('app/vendor-cache/README.txt', fs.readFileSync(path.join(root, 'vendor-cache', 'README.txt')));
put('certificates/README.txt', Buffer.from('﻿תיקייה זו מיועדת לתעודות רשות (CA) של הרשת שלכם בלבד, שאישרתם באשף ההתקנה.\r\nהאשף מציג את פרטי התעודה ומבקש אישור לפני שמירה. אין להוסיף קובץ עם מפתח פרטי.\r\nכדי לבטל אישור: מחקו את הקובץ ובנו מחדש את רכיבי התוכנה מהאשף.\r\n', 'utf8'));

for (const file of ['install.ps1', 'prepare.ps1', 'prepare-lib.ps1', 'manage.ps1', 'maintenance-agent.ps1', 'prepare-computer.ps1', 'docker-host.ps1', 'wsl-engine.ps1']) {
  put(file, fs.readFileSync(path.join(root, 'windows', file)));
}
put('README-he.md', fs.readFileSync(path.join(root, 'windows', 'DISTRIBUTION-README-he.md')));
put('SETUP-INFO-he.txt', fs.readFileSync(path.join(root, 'windows', 'SETUP-INFO-he.txt')));
const launchers = {
  'Install.cmd': ['prepare.ps1', ''],
  'Prepare.cmd': ['prepare.ps1', '-Mode Repair'],
  'Start.cmd': ['manage.ps1', '-Action Start'],
  'Stop.cmd': ['manage.ps1', '-Action Stop'],
  'Manage.cmd': ['manage.ps1', '-Action Menu'],
};
for (const [file, [script, extra]] of Object.entries(launchers)) {
  put(file, Buffer.from(`@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0${script}" ${extra}\r\nif errorlevel 1 pause\r\n`));
}
// Safe portable defaults; no machine-specific override is copied.
put('app/docker-compose.override.yml', fs.readFileSync(path.join(root, 'windows', 'docker-compose.distribution.yml')));
// Prebuilt-image mode: used when images.json from a GitHub release is present.
put('app/docker-compose.images.yml', fs.readFileSync(path.join(root, 'windows', 'docker-compose.images.yml')));
if (fs.existsSync(path.join(root, 'legal', 'images.json'))) put('images.json', fs.readFileSync(path.join(root, 'legal', 'images.json')));

// ---------- privacy and secret scan (build fails on any hit) ----------
const forbidden = [
  [/-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----/, 'private key'],
  [/-----BEGIN CERTIFICATE-----/, 'embedded certificate'],
  [/\bsk-ant-[A-Za-z0-9_-]{20,}/, 'Anthropic key'],
  [/\bsk-(?:proj-)?[A-Za-z0-9]{32,}/, 'OpenAI key'],
  [/\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}/, 'GitHub token'],
  [/\bAKIA[0-9A-Z]{16}\b/, 'AWS key'],
  [/\bxox[abposr]-[A-Za-z0-9-]{10,}/, 'Slack token'],
  [/427A~1|OpenKritt[\\/]|תיקיית פרויקטים בAI/, 'personal path of the publishing computer'],
  [/[A-Za-z]:\\\\?Users\\\\?(?!Public|Default|<|%|\$|USERNAME|you|user\b|name\b)[^\\\s"'<>]{2,}/i, 'Windows user profile path'],
];
// Files that legitimately contain such patterns as detection rules, tests or this scanner.
const scanAllow = [/^app\/(engine\/open_kritt_engine\/security_rules\.json|engine\/tests\/|backend\/test\/|frontend\/src\/.*\.test\.jsx?$|legal\/raw\/|frontend\/public\/legal\/texts\/|windows\/prepare-lib\.ps1|windows\/prepare\.ps1|legal\/build-distribution\.cjs|legal\/test-distribution\.ps1)|^(prepare|prepare-lib)\.ps1$/];
const findings = [];
const files = [];
(function index(folder, prefix = '') {
  for (const item of fs.readdirSync(folder, { withFileTypes: true })) {
    const rel = prefix ? prefix + '/' + item.name : item.name;
    if (item.isDirectory()) index(path.join(folder, item.name), rel);
    else files.push(rel);
  }
})(output);
for (const rel of files) {
  if (scanAllow.some((r) => r.test(rel))) continue;
  const buffer = fs.readFileSync(path.join(output, rel));
  if (buffer.includes(0)) continue;
  const text = buffer.toString('utf8');
  for (const [pattern, label] of forbidden) if (pattern.test(text)) findings.push(`${rel}: ${label}`);
}
if (findings.length) {
  fs.rmSync(output, { recursive: true, force: true });
  throw new Error('Privacy/secret scan failed; nothing was published:\n' + findings.join('\n'));
}

// ---------- manifest and SHA-256 list ----------
const manifest = {
  distribution: 'open-kritt-hebrew-source-install', format: 2, version, createdAt: new Date().toISOString(),
  credit: 'הגרסה העברית, התוספות והשיפורים בוצעו על ידי @ארי ממתמחים טופ',
  profile: 'https://mitmachim.top/user/%D7%90%D7%A8%D7%99', email: 'rpg05832@gmail.com',
  upstream: { name: 'open·kritt', url: 'https://github.com/Kritt-ai/open-kritt', owners: ['Harel Rom', 'Gabriel Balko'], license: 'AGPL-3.0-only' },
  baseCommit: cp.execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(),
  includesUncommittedChanges: cp.execFileSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' }).trim().length > 0,
  containsVendorBinaries: false, containsCertificates: false, requiresInternet: true, files: [],
};
const sums = [];
for (const rel of files.sort()) {
  const sha256 = crypto.createHash('sha256').update(fs.readFileSync(path.join(output, rel))).digest('hex');
  manifest.files.push({ path: rel, sha256 });
  sums.push(`${sha256} *${rel}`);
}
fs.writeFileSync(path.join(output, 'SOURCE-MANIFEST.json'), JSON.stringify(manifest, null, 2));
fs.writeFileSync(path.join(output, 'SHA256SUMS.txt'), sums.join('\n') + '\n');

let zip = null;
if (makeZip) {
  zip = output + '.zip';
  if (fs.existsSync(zip)) throw new Error('ZIP already exists: ' + zip);
  cp.execFileSync('powershell.exe', ['-NoProfile', '-Command', 'Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory($env:KRITT_SRC, $env:KRITT_ZIP, [IO.Compression.CompressionLevel]::Optimal, $true)'], { env: { ...process.env, KRITT_SRC: output, KRITT_ZIP: zip }, stdio: 'inherit' });
  const zipHash = crypto.createHash('sha256').update(fs.readFileSync(zip)).digest('hex');
  fs.writeFileSync(zip + '.sha256', `${zipHash} *${path.basename(zip)}\n`);
}
console.log(JSON.stringify({ output, files: files.length, zip }));
