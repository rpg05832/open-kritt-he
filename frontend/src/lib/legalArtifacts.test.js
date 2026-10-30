import { describe, it, expect } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const base = fileURLToPath(new URL('../../public/legal/', import.meta.url));
const inventory = JSON.parse(readFileSync(base + 'inventory.json', 'utf8'));
describe('distributed legal notices', () => {
  it('retains the requested credit and separates proprietary tools from the app license', () => {
    expect(inventory.credit.profile).toBe('https://mitmachim.top/user/%D7%90%D7%A8%D7%99');
    expect(inventory.credit.email).toBe('rpg05832@gmail.com');
    expect(inventory.packages.find((p) => p.name === 'Cursor Agent').review).toBe('vendor-terms');
    expect(inventory.packages.find((p) => p.name === '@anthropic-ai/claude-code').review).toBe('vendor-terms');
    expect(inventory.auditStatus).not.toBe('APPROVED');
    expect(inventory.summary.unresolved).toBe(0);
  });
  it('ships each referenced notice unchanged under its recorded content hash', () => {
    for (const hash of new Set(inventory.packages.flatMap((p) => p.notices.map((n) => n.hash)))) {
      const file = base + 'texts/' + hash + '.txt';
      expect(existsSync(file)).toBe(true);
      expect(createHash('sha256').update(readFileSync(file)).digest('hex')).toBe(hash);
    }
    expect(
      createHash('sha256')
        // Same normalisation as legal/build-notices.cjs (no BOM, LF line endings).
        .update(
          readFileSync(base + 'LICENSE', 'utf8')
            .replace(new RegExp('^' + String.fromCharCode(0xfeff)), '')
            .replace(/\r\n/g, '\n'),
          'utf8'
        )
        .digest('hex')
    ).toBe(inventory.inputHashes.LICENSE);
  });
});
