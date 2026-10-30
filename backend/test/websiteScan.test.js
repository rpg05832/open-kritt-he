import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeWebsiteUrl, websiteHostClass, validateScan, ValidationError } from '../src/lib/validation.js';
import { repoDisplayName } from '../src/lib/serialize.js';

const base = {
  workflowId: '1',
  postScriptId: '1',
  repo_kind: 'url',
  repo_full: 'https://shop.example.com/store#top',
  model: 'test-model',
  model_provider: 'codex',
  harness: 'codex',
  thinking_effort: 'high',
  severity_ranker: 'Rank by impact.',
  configuration: { website: { authorized: true, mode: 'passive' } },
};

const fields = (fn) => {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof ValidationError);
    return error.errors.map((e) => e.field);
  }
  assert.fail('expected a validation error');
};

test('a website scan stores the normalized address and has no commit', () => {
  const valid = validateScan(base);
  assert.equal(valid.repoKind, 'url');
  assert.equal(valid.repoFull, 'https://shop.example.com/store');
  assert.equal(valid.commitSha, 'LIVE_SITE');
  assert.equal(repoDisplayName(valid.repoFull, 'url'), 'shop.example.com/store');
});

test('a website scan requires explicit authorization and a known mode', () => {
  assert.deepEqual(
    fields(() => validateScan({ ...base, configuration: { website: { mode: 'passive' } } })),
    ['configuration.website.authorized']
  );
  assert.deepEqual(
    fields(() => validateScan({ ...base, configuration: { website: { authorized: true, mode: 'nuke' } } })),
    ['configuration.website.mode']
  );
  for (const mode of ['passive', 'active', 'full']) {
    assert.equal(validateScan({ ...base, configuration: { website: { authorized: true, mode } } }).repoKind, 'url');
  }
  assert.ok(
    fields(() => validateScan({ ...base, configuration: { ...base.configuration, scan_mode: 'changes' } })).includes(
      'configuration.scan_mode'
    )
  );
});

test('internal and private addresses are blocked unless local-site scanning is on', () => {
  for (const host of ['localhost', '127.0.0.1', '10.0.0.5', '192.168.1.1', '172.16.9.9', 'db', 'host.docker.internal', '169.254.1.1', '::1', '[fe80::1]', 'app.local']) {
    assert.equal(websiteHostClass(host), 'internal', host);
  }
  for (const host of ['example.com', '8.8.8.8', 'shop.example.co.il', '[2606:4700::1111]']) {
    assert.equal(websiteHostClass(host), 'public', host);
  }
  assert.deepEqual(
    fields(() => validateScan({ ...base, repo_full: 'http://192.168.1.10/admin' })),
    ['configuration.website.allow_local']
  );
  assert.equal(
    validateScan({
      ...base,
      repo_full: 'http://192.168.1.10/admin',
      configuration: { website: { authorized: true, mode: 'active', allow_local: true } },
    }).repoKind,
    'url'
  );
});

test('only plain http(s) addresses are accepted, and never as a dependency', () => {
  for (const bad of ['ftp://example.com', 'javascript:alert(1)', 'https://user:pass@example.com', 'example.com', '']) {
    assert.equal(normalizeWebsiteUrl(bad), null, bad);
  }
  assert.deepEqual(
    fields(() => validateScan({ ...base, dependencies: [{ kind: 'url', repo_full: 'https://x.example' }] })),
    ['dependencies[0].kind', 'dependencies']
  );
});
