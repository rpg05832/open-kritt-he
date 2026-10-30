import { describe, it, expect } from 'vitest';
import { compareFindings } from './compareFindings.js';
describe('finding comparison', () => {
  it('pairs shifted lines without treating missing results as fixed', () => {
    const old = [
      { id: '1', file_path: 'app.js', summary: 'Unsafe input', line: 1 },
      { id: '2', file_path: 'b.js', summary: 'Old' },
    ];
    const next = [
      { id: '3', file_path: 'app.js', summary: 'Unsafe input', line: 10 },
      { id: '4', file_path: 'c.js', summary: 'New' },
    ];
    const result = compareFindings(old, next);
    expect(result.persistent[0].before.id).toBe('1');
    expect(result.added[0].id).toBe('4');
    expect(result.notDetected[0].id).toBe('2');
    expect(old).toHaveLength(2);
  });
});
