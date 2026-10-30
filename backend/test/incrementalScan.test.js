import test from 'node:test';
import assert from 'node:assert/strict';
import { compatibleScanSettings } from '../src/lib/incrementalScan.js';
test('baseline requires matching scope settings, dependencies and skills', () => {
  const previous = {
    configuration: { max_files: 4000, scan_mode: 'full', dependency_audit: false },
    dependenciesDetail: [],
    agentSkillIds: [2n, 1n],
  };
  const next = {
    configuration: { dependency_audit: true, scan_mode: 'changes', max_files: 4000 },
    dependencies: [],
    skills: ['1', '2'],
  };
  assert.equal(compatibleScanSettings(previous, next), true);
  assert.equal(compatibleScanSettings(previous, { ...next, dependencies: [{ repo_full: 'other' }] }), false);
  assert.equal(compatibleScanSettings(previous, { ...next, configuration: { max_files: 20 } }), false);
});
