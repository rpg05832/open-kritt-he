function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object')
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, stable(value[key])])
    );
  return typeof value === 'bigint' ? value.toString() : value;
}
export function compatibleScanSettings(previous, { configuration, dependencies, skills }) {
  const normalize = (config) =>
    Object.fromEntries(
      Object.entries(config || {}).filter(
        ([key]) => !['scan_mode', 'incremental_baseline_id', 'dependency_audit'].includes(key)
      )
    );
  return (
    JSON.stringify(
      stable({
        configuration: normalize(previous.configuration),
        dependencies: previous.dependenciesDetail || [],
        skills: (previous.agentSkillIds || []).map(String).sort(),
      })
    ) ===
    JSON.stringify(stable({ configuration: normalize(configuration), dependencies, skills: skills.map(String).sort() }))
  );
}
