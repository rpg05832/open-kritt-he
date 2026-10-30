// Builds the one-click Windows installer: distribution/SecurityScan-Setup-<version>.exe
// 1. Stages a clean distribution (legal/build-distribution.cjs: privacy scan, SHA-256 list).
// 2. Runs Inno Setup (ISCC) on windows/open-kritt.iss; per-user install, no admin rights.
// 3. Writes a .sha256 file next to the installer.
// Usage: node legal/build-setup.cjs   (needs Inno Setup 6: winget install JRSoftware.InnoSetup)
// Same structure as C:\Tzevet\app\installer\build.mjs.
const fs = require('fs'), path = require('path'), crypto = require('crypto'), cp = require('child_process');
const root = path.resolve(__dirname, '..');
const distribution = path.join(root, '..', 'distribution');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim().split(' ')[0];
const stage = path.join(distribution, `setup-stage-${version}-${Date.now()}`);
const step = (message) => console.log('• ' + message);

function iscc() {
  const candidates = [
    path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Inno Setup 6', 'ISCC.exe'),
    'C:/Program Files (x86)/Inno Setup 6/ISCC.exe',
    'C:/Program Files/Inno Setup 6/ISCC.exe',
  ];
  const found = candidates.find((p) => fs.existsSync(p));
  if (!found) throw new Error('Inno Setup 6 is not installed (winget install JRSoftware.InnoSetup).');
  return found;
}

step(`building version ${version}`);
cp.execFileSync(process.execPath, [path.join(__dirname, 'build-distribution.cjs'), stage], { stdio: 'inherit' });
try {
  step('running Inno Setup');
  cp.execFileSync(iscc(), [`/DAppVersion=${version}`, `/DStage=${stage}`, `/O${distribution}`, '/Q', path.join(root, 'windows', 'open-kritt.iss')], { stdio: 'inherit' });
} finally {
  fs.rmSync(stage, { recursive: true, force: true });
}
const setup = path.join(distribution, `SecurityScan-Setup-${version}.exe`);
const sha256 = crypto.createHash('sha256').update(fs.readFileSync(setup)).digest('hex');
fs.writeFileSync(setup + '.sha256', `${sha256} *${path.basename(setup)}\n`);
step(`ready: ${setup} (${Math.round(fs.statSync(setup).size / 1024 / 1024)} MB, SHA-256 ${sha256.slice(0, 12)}…)`);
