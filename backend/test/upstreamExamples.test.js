import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ensureDefaultWorkflows, isDefaultWorkflowName } from '../src/lib/defaultWorkflows.js';
import { ensureDefaultSeverityRankers, isDefaultSeverityRankerName } from '../src/lib/defaultSeverityRankers.js';

test('the Hebrew edition neither creates nor protects the upstream examples', async () => {
  const previous = process.env.OPEN_KRITT_UPSTREAM_EXAMPLES;
  process.env.OPEN_KRITT_UPSTREAM_EXAMPLES = '0';
  try {
    const untouched = {
      $transaction: () => {
        throw new Error('no database access expected');
      },
    };
    assert.deepEqual(await ensureDefaultWorkflows(untouched), []);
    assert.deepEqual(await ensureDefaultSeverityRankers(untouched), []);
    assert.equal(isDefaultWorkflowName('Cosmos ABCI Panic Halt Review'), false);
    assert.equal(isDefaultSeverityRankerName('Blockchain security triage'), false);
  } finally {
    if (previous === undefined) delete process.env.OPEN_KRITT_UPSTREAM_EXAMPLES;
    else process.env.OPEN_KRITT_UPSTREAM_EXAMPLES = previous;
  }
});
