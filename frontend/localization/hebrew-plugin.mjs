/* global URL */
import { parse } from '@babel/parser';
import { readFileSync } from 'node:fs';
const displayKeys = new Set([
  'label',
  'title',
  'description',
  'placeholder',
  'sub',
  'unit',
  'enabledDescription',
  'disabledDescription',
  'emptyLabel',
  'searchPlaceholder',
  'aria-label',
]);
const normalize = (text) => text.replace(/\s+/g, ' ').trim();

// Ancestors between the node and its nearest JSX expression container. A string is
// rendered only if nothing in this range turns it into a key, an argument or part of
// a computed value; JSX nested inside .map() callbacks still counts as rendered.
function betweenContainer(ancestors) {
  const index = ancestors.map((n) => n.type).lastIndexOf('JSXExpressionContainer');
  return index < 0 ? ancestors : ancestors.slice(index + 1);
}

export function translateSource(source, dictionary) {
  const ast = parse(source, { sourceType: 'module', plugins: ['jsx'] });
  const edits = [];
  function visit(node, ancestors = []) {
    if (!node || typeof node !== 'object') return;
    const parent = ancestors.at(-1);
    const jsxParent = [...ancestors].reverse().find((n) => n.type === 'JSXElement');
    const inCode = ancestors.some(
      (n) =>
        n.type === 'JSXElement' &&
        ['code', 'pre', 'textarea', 'PromptEditor', 'Markdown'].includes(n.openingElement.name.name)
    );
    if ((node.type === 'JSXText' || node.type === 'StringLiteral') && !inCode) {
      const text = normalize(node.value);
      const translated = dictionary[text];
      // The nearest attribute only counts when no JSX element sits in between (render props such as renderTrigger={() => <span>Text</span>} contain rendered text).
      const nearest = [...ancestors].reverse().find((n) => n.type === 'JSXAttribute' || n.type === 'JSXElement');
      const attr = nearest?.type === 'JSXAttribute' ? nearest : undefined;
      // Look through a ? 'x' : 'y' and a || 'x' to the place where the value is used.
      let level = ancestors.length - 1;
      while (level >= 0 && ['ConditionalExpression', 'LogicalExpression'].includes(ancestors[level].type)) level--;
      const owner = ancestors[level];
      const property = owner?.type === 'ObjectProperty' && owner.value === (ancestors[level + 1] || node);
      const key = property ? owner.key.name || owner.key.value : '';
      const isDisplayProp = property && displayKeys.has(key);
      const isDisplayAttr = attr && displayKeys.has(attr.name.name);
      const isRenderedExpression =
        !attr &&
        jsxParent &&
        ancestors.some((n) => n.type === 'JSXExpressionContainer') &&
        !betweenContainer(ancestors).some((n) =>
          ['ObjectProperty', 'CallExpression', 'BinaryExpression'].includes(n.type)
        );
      const isDisplayDefault = parent?.type === 'AssignmentPattern' && displayKeys.has(parent.left.name);
      // These objects contain labels only; their keys are internal IDs and stay unchanged.
      const inLabels =
        property &&
        ancestors.some((n) => n.type === 'VariableDeclarator' && /(?:LABELS|STATUS_META)$/.test(n.id?.name || ''));
      if (
        translated &&
        translated !== text &&
        (node.type === 'JSXText' ||
          isDisplayProp ||
          isDisplayAttr ||
          isRenderedExpression ||
          isDisplayDefault ||
          inLabels)
      ) {
        const leading = node.value.startsWith(' ') && !node.value.includes('\n') ? ' ' : '';
        const trailing = node.value.endsWith(' ') && !node.value.includes('\n') ? ' ' : '';
        const value = JSON.stringify(leading + translated + trailing);
        edits.push([node.start, node.end, node.type === 'JSXText' ? `{${value}}` : value]);
      }
    }
    for (const [key, value] of Object.entries(node)) {
      if (['loc', 'extra', 'comments', 'tokens'].includes(key)) continue;
      if (Array.isArray(value)) value.forEach((child) => visit(child, [...ancestors, node]));
      else if (value && typeof value === 'object') visit(value, [...ancestors, node]);
    }
  }
  visit(ast);
  for (const [start, end, text] of edits.sort((a, b) => b[0] - a[0]))
    source = source.slice(0, start) + text + source.slice(end);
  return source;
}

export default function hebrewPlugin(enabled) {
  let dictionary;
  return {
    name: 'open-kritt-local-hebrew',
    enforce: 'pre',
    transform(code, id) {
      if (!enabled || !/[\\/]src[\\/].*\.(jsx|js)$/.test(id) || id.includes('.test.')) return null;
      dictionary ||= Object.assign(
        {},
        ...['he-a.json', 'he-b.json', 'he-extra.json'].map((file) =>
          JSON.parse(readFileSync(new URL(file, import.meta.url), 'utf8'))
        )
      );
      return { code: translateSource(code, dictionary), map: null };
    },
  };
}
