export function findingIdentity(finding) {
  return [finding.file_path, finding.vulnerability_type, finding.summary]
    .map((value) =>
      String(value || '')
        .trim()
        .toLowerCase()
        .replace(/\s+/g, ' ')
    )
    .join('\u0000');
}
export function compareFindings(before, after) {
  const buckets = new Map();
  for (const finding of before) {
    const key = findingIdentity(finding);
    buckets.set(key, [...(buckets.get(key) || []), finding]);
  }
  const added = [],
    persistent = [];
  for (const finding of after) {
    const match = buckets.get(findingIdentity(finding))?.shift();
    if (match) persistent.push({ before: match, after: finding });
    else added.push(finding);
  }
  return { added, persistent, notDetected: [...buckets.values()].flat() };
}
