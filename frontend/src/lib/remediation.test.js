import { describe, it, expect } from 'vitest';
import { prioritizeFindings } from './remediation.js';
describe('remediation priority', () => {
  it('sorts severity before exploitability without changing stored findings', () => {
    const items = [{ id: '1', severity: 'low', exploitable: true }, { id: '2', severity: 'CRITICAL' }, { id: '3' }];
    expect(prioritizeFindings(items).map((f) => f.id)).toEqual(['2', '1', '3']);
    expect(items[0].id).toBe('1');
  });
});
