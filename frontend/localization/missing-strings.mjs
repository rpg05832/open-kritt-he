/* global process, console */
// Lists visible English UI strings that have no Hebrew translation yet.
// Usage: node localization/missing-strings.mjs [file-or-folder ...]
// Uses the same rules as hebrew-plugin.mjs (JSX text and display props only).
import { parse } from '@babel/parser';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const dictionary = Object.assign(
  {},
  ...['he-a.json', 'he-b.json', 'he-extra.json'].map((f) => JSON.parse(readFileSync(path.join(here, f), 'utf8')))
);
const displayKeys = new Set([
  'label',
  'title',
  'description',
  'placeholder',
  'sub',
  'unit',
  'aria-label',
  'emptyLabel',
  'searchPlaceholder',
]);
const normalize = (text) => text.replace(/\s+/g, ' ').trim();
const english = /[A-Za-z]{2,}/;

function files(target) {
  if (statSync(target).isDirectory()) return readdirSync(target).flatMap((f) => files(path.join(target, f)));
  return /\.(jsx|js)$/.test(target) && !target.includes('.test.') ? [target] : [];
}

const missing = new Map();
for (const file of process.argv.slice(2).flatMap(files)) {
  const ast = parse(readFileSync(file, 'utf8'), { sourceType: 'module', plugins: ['jsx'] });
  (function visit(node, parent, inAttr) {
    if (!node || typeof node !== 'object') return;
    let text = null;
    if (node.type === 'JSXText') text = normalize(node.value);
    if (
      node.type === 'StringLiteral' &&
      parent?.type === 'ObjectProperty' &&
      displayKeys.has(parent.key?.name || parent.key?.value)
    )
      text = normalize(node.value);
    if (node.type === 'StringLiteral' && inAttr && displayKeys.has(inAttr)) text = normalize(node.value);
    if (text && english.test(text) && !/[֐-׿]/.test(text) && !dictionary[text]) {
      missing.set(text, (missing.get(text) || new Set()).add(path.basename(file)));
    }
    const attr = node.type === 'JSXAttribute' ? node.name.name : inAttr;
    for (const [key, value] of Object.entries(node)) {
      if (['loc', 'extra', 'comments'].includes(key)) continue;
      if (Array.isArray(value)) value.forEach((child) => visit(child, node, attr));
      else if (value && typeof value === 'object') visit(value, node, attr);
    }
  })(ast, null, null);
}
for (const [text, where] of [...missing].sort()) console.log(JSON.stringify(text), '|', [...where].join(','));
console.error(`${missing.size} untranslated strings`);
