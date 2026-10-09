export interface FailurePolicyRow {
  section: string;
  policy: string;
  state:
    | 'primary'
    | 'reserve'
    | 'direct'
    | 'blocked'
    | 'monitor-error'
    | 'unknown';
  changedAgo: number | null;
}
export function failurePolicyRows(value: unknown): FailurePolicyRow[] {
  if (!value || typeof value !== 'object') return [];
  const report = value as Record<string, unknown>;
  if (report.enabled !== true || !Array.isArray(report.sections)) return [];
  return report.sections
    .slice(0, 128)
    .filter(
      (item) =>
        item && typeof item === 'object' && typeof item.section === 'string',
    )
    .map((item: Record<string, unknown>) => {
      const age = Number(item.age_seconds);
      const validState = ['primary', 'reserve', 'direct', 'blocked'].includes(
        String(item.state),
      );
      return {
        section: String(item.section).slice(0, 64),
        policy: ['block', 'reserve', 'direct'].includes(String(item.policy))
          ? String(item.policy)
          : 'unknown',
        state:
          !Number.isFinite(age) || age < 0 || age > 120 || !validState
            ? 'unknown'
            : report.guarded === true || item.monitor_error === true
              ? 'monitor-error'
              : (item.state as FailurePolicyRow['state']),
        changedAgo:
          typeof item.changed_ago_seconds === 'number' &&
          Number.isFinite(item.changed_ago_seconds) &&
          item.changed_ago_seconds >= 0
            ? Math.floor(item.changed_ago_seconds)
            : null,
      };
    });
}
