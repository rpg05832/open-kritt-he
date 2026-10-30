import { describe, expect, it } from 'vitest';
import { translateSource } from './hebrew-plugin.mjs';

describe('Hebrew presentation translation', () => {
  const dictionary = { Scans: 'בדיקות', Delete: 'מחיקה', 'Hello & goodbye': 'שלום ולהתראות' };
  it('translates visible labels but preserves data keys, routes, and submitted values', () => {
    const source = `const x={Scans: 'Scans', label:'Scans'}; const el=<option value="Scans" title="Delete">Scans</option>; const route=<a href="/Scans">Delete</a>;`;
    const output = translateSource(source, dictionary);
    expect(output).toContain("Scans: 'Scans'");
    expect(output).toContain('label:"בדיקות"');
    expect(output).toContain('value="Scans"');
    expect(output).toContain('title="מחיקה"');
    expect(output).toContain('href="/Scans"');
    expect(output).toContain('{"בדיקות"}');
  });
  it('does not translate arbitrary stored user content or source code strings', () => {
    const source = `const userData = 'Scans'; const code = <code>Scans</code>;`;
    expect(translateSource(source, dictionary)).toBe(source);
  });
  it('decodes JSX entities before matching and emits safe string expressions', () => {
    expect(translateSource('<p>Hello &amp; goodbye</p>', dictionary)).toBe('<p>{"שלום ולהתראות"}</p>');
  });
});
