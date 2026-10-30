import { findingSeverity } from './format.js';
const priorities = { critical: 0, high: 1, medium: 2, low: 3, info: 4, informational: 4 };
export function prioritizeFindings(findings) {
  return [...findings].sort(
    (a, b) =>
      (priorities[String(findingSeverity(a)).toLowerCase()] ?? 5) -
        (priorities[String(findingSeverity(b)).toLowerCase()] ?? 5) ||
      Number(Boolean(b.exploitable)) - Number(Boolean(a.exploitable)) ||
      String(a.id).localeCompare(String(b.id), undefined, { numeric: true })
  );
}
