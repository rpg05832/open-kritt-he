import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { QualityCoverage } from './SecurityCoverage.jsx';
import { AUTOMATIC_SCAN_KINDS } from '../pages/CreateScan.jsx';
import automaticSkills from '../lib/automaticSkills.json';

describe('code quality coverage', () => {
  it('summarises tool status, duplication and languages without tests', () => {
    const html = renderToStaticMarkup(
      <QualityCoverage
        quality={{
          lint_python: { status: 'completed', candidates: [{}, {}] },
          duplication: { status: 'completed', candidates: [{}], duplication_percentage: 12.4 },
          complexity: { status: 'unavailable', candidates: [] },
          tests: {
            languages: { Python: { source_files: 10, test_files: 2 }, JavaScript: { source_files: 5, test_files: 0 } },
            languages_without_tests: ['JavaScript'],
          },
        }}
      />
    );
    expect(html).toContain('2 חשדות');
    expect(html).toContain('12% מהשורות כפולות');
    expect(html).toContain('אינו מותקן');
    expect(html).toContain('אין בדיקות כלל ל: JavaScript');
  });
});

describe('automatic scan kinds', () => {
  it('uses three distinct two-level workflows with the shared finding fields', () => {
    const names = Object.values(AUTOMATIC_SCAN_KINDS).map((kind) => kind.workflow.name);
    expect(new Set(names).size).toBe(3);
    for (const { workflow } of Object.values(AUTOMATIC_SCAN_KINDS)) {
      expect(workflow.levels.map((level) => level.depth)).toEqual([0, 1]);
      expect(Object.keys(workflow.levels[1].outputFormat)).toContain('vulnerability_type');
    }
  });

  it('uses the quality follow-up script only for quality scans', () => {
    expect(AUTOMATIC_SCAN_KINDS.quality.postScript.name).toBe('אימות ותיקון — תקינות קוד');
    expect(AUTOMATIC_SCAN_KINDS.security.postScript.name).toBe(AUTOMATIC_SCAN_KINDS.both.postScript.name);
    expect(AUTOMATIC_SCAN_KINDS.quality.postScript.outputFormat).toEqual({ review_report: 'string' });
  });

  it('selects quality skills only for quality scans', () => {
    const slugs = automaticSkills.map((skill) => skill.slug);
    const quality = slugs.filter(AUTOMATIC_SCAN_KINDS.quality.skill);
    const security = slugs.filter(AUTOMATIC_SCAN_KINDS.security.skill);
    expect(quality.every((slug) => slug.startsWith('he-quality-') || slug === 'he-verify-coverage')).toBe(true);
    expect(security.some((slug) => slug.startsWith('he-quality-'))).toBe(false);
    expect(slugs.filter(AUTOMATIC_SCAN_KINDS.both.skill)).toHaveLength(slugs.length);
  });
});
