import { describe, expect, it } from 'vitest';
import { AUTOMATIC_SCAN_KINDS } from '../pages/CreateScan.jsx';
import securityRanker from './automaticSecurityRanker.json';
import qualityRanker from './automaticQualityRanker.json';

describe('automatic severity rankers', () => {
  it('uses the matching saved ranker for every automatic scan kind', () => {
    expect(AUTOMATIC_SCAN_KINDS.security.rankers).toEqual([securityRanker]);
    expect(AUTOMATIC_SCAN_KINDS.quality.rankers).toEqual([qualityRanker]);
    expect(AUTOMATIC_SCAN_KINDS.both.rankers).toEqual([securityRanker, qualityRanker]);
  });

  it('defines every severity level, in Hebrew, with code quality kept apart from security', () => {
    for (const ranker of [securityRanker, qualityRanker]) {
      expect(ranker.name).toMatch(/[א-ת]/);
      for (const level of ['Critical', 'High', 'Medium', 'Low', 'Informational']) {
        expect(ranker.content).toContain(`- ${level} (`);
      }
    }
    expect(qualityRanker.content).toContain('תקינות קוד');
    expect(qualityRanker.content).toContain('reward');
    expect(securityRanker.name).not.toBe(qualityRanker.name);
  });
});
