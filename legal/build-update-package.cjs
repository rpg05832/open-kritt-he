// Builds the automatic-update package read by maintenance-agent.ps1:
//   open-kritt-hebrew-update.zip  (only paths the agent's Source-Allowed accepts, plus app/images.json)
//   open-kritt-hebrew-update.json (distribution, format 1, version, SHA-256 of the zip)
// Usage: node legal/build-update-package.cjs <version> <outputFolder>
const fs = require('fs'), path = require('path'), crypto = require('crypto'), cp = require('child_process');
const root = path.resolve(__dirname, '..');
const [version, outputArg] = process.argv.slice(2);
if (!version || !outputArg) throw new Error('usage: build-update-package.cjs <version> <outputFolder>');
const output = path.resolve(outputArg);
fs.mkdirSync(output, { recursive: true });

// Same allow-list as Source-Allowed in windows/maintenance-agent.ps1 (keep in sync).
const forbidden = /(^|\/)(node_modules|\.git|\.data|local_repos|local-certs|local-tools|vendor-cache|\.env)(\/|$)|\.env/;
const allowed = [
  /^app\/(LICENSE$|NOTICE\.md$|OWNERSHIP\.md$|THIRD_PARTY_NOTICES\.md$|images\.json$|legal\/|windows\/|frontend\/public\/legal\/)/,
  /^app\/(frontend\/(src\/|localization\/|package(-lock)?\.json$|vite\.config\.js$|index\.html$|Dockerfile$)|backend\/(src\/|prisma\/|package(-lock)?\.json$|Dockerfile$|runtime-env\.sh$)|engine\/(open_kritt_engine\/|requirements\.txt$|Dockerfile$|security-tools\.json$|install_security_tools\.py$|runtime-env\.sh$)|executor-view\/(src\/|package(-lock)?\.json$|Dockerfile$|runtime-env\.sh$)|database\/(init\/|Dockerfile$)|docker-compose\.yml$)/,
];
const files = [];
(function walk(folder, rel) {
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const relative = rel + '/' + entry.name;
    if (entry.isSymbolicLink() || forbidden.test(relative)) continue;
    if (entry.isDirectory()) walk(path.join(folder, entry.name), relative);
    else if (allowed.some((pattern) => pattern.test(relative)) && fs.statSync(path.join(folder, entry.name)).size <= 20 * 1024 * 1024) files.push(relative);
  }
})(root, 'app');
const images = path.join(root, 'legal', 'images.json');
if (fs.existsSync(images)) files.push('app/images.json');

const stage = fs.mkdtempSync(path.join(output, 'update-stage-'));
for (const relative of files) {
  const source = relative === 'app/images.json' ? images : path.join(root, relative.slice(4));
  let data = fs.readFileSync(source);
  if (!data.includes(0) && !/\.(ps1|cmd)$/.test(relative)) data = Buffer.from(data.toString('utf8').replace(/\r\n/g, '\n'), 'utf8');
  const target = path.join(stage, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, data);
}
const zip = path.join(output, 'open-kritt-hebrew-update.zip');
fs.rmSync(zip, { force: true });
// Entry names with forward slashes, exactly as the agent validates them.
// The base path is resolved the same way as the files' FullName (an 8.3 short
// path and its long form have different lengths).
const script = 'Add-Type -AssemblyName System.IO.Compression.FileSystem; $base=(Get-Item -LiteralPath $env:K_STAGE).FullName.TrimEnd([char]92); $z=[IO.Compression.ZipFile]::Open($env:K_ZIP,"Create"); try { Get-ChildItem -LiteralPath $base -Recurse -File | ForEach-Object { $name=$_.FullName.Substring($base.Length+1).Replace([char]92,[char]47); [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z,$_.FullName,$name,"Optimal") } } finally { $z.Dispose() }';
cp.execFileSync(process.platform === 'win32' ? 'powershell.exe' : 'pwsh', ['-NoProfile', '-Command', script], { env: { ...process.env, K_ZIP: zip, K_STAGE: stage }, stdio: 'inherit' });
fs.rmSync(stage, { recursive: true, force: true });
const sha256 = crypto.createHash('sha256').update(fs.readFileSync(zip)).digest('hex');
fs.writeFileSync(path.join(output, 'open-kritt-hebrew-update.json'), JSON.stringify({ distribution: 'open-kritt-hebrew', format: 1, version, sha256 }, null, 2));
console.log(JSON.stringify({ zip, files: files.length, sha256 }));
