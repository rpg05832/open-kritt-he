// Signs the auto-update manifest the way maintenance-agent.ps1 verifies it:
// RSA PKCS#1 v1.5 / SHA-256 over "distribution\nformat\nversion\nsha256", so a
// signature cannot be reused for another version or another file.
const crypto = require('crypto');

function manifestMessage(manifest) {
  return [manifest.distribution, manifest.format, manifest.version, manifest.sha256].join('\n');
}

function signManifest(manifest, privateKeyPem) {
  return crypto
    .sign('sha256', Buffer.from(manifestMessage(manifest), 'utf8'), crypto.createPrivateKey(privateKeyPem))
    .toString('base64');
}

module.exports = { manifestMessage, signManifest };
