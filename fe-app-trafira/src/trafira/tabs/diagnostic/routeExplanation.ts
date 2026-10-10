export interface ExplainRequest {
  domain: string;
  source: {
    kind: 'device' | 'router';
    ip?: string;
    mac?: string;
    interface?: string;
  };
  destination_ip?: string;
  port: number;
  network: 'tcp' | 'udp';
  protocol?: string;
}
export interface ExplainDecision {
  status: 'matched' | 'direct' | 'blocked' | 'indeterminate';
  rule_index?: number | null;
  outbound?: string | null;
  missing: string[];
  trace: Array<{
    index: number;
    match: string;
    action: string;
    shadowed: boolean;
    origin?: { kind?: string; section?: string; list_tag?: string } | null;
    missing: string[];
  }>;
  trace_truncated?: boolean;
}
export interface ExplainReport {
  success: boolean;
  error?: string;
  generated_at?: number;
  config_digest?: string;
  decision: ExplainDecision;
  dns_policy?: ExplainDecision;
  dns_query?: { performed: boolean; origin: string };
  selector?: { tag: string; current: string } | null;
  rule_sets?: {
    basis: 'saved_snapshots' | 'local';
    live_verified: boolean;
    available: number;
    unavailable: number;
    unavailable_reasons?: Array<{ tag: string; reason: string }>;
  };
  limitations: string[];
}
type RouteFailure =
  | 'timeout'
  | 'permission_denied'
  | 'command_failed'
  | 'rpc_failed'
  | 'invalid_response'
  | 'render_failed';
export class RouteExplanationError extends Error {
  constructor(public readonly category: RouteFailure) {
    super(category);
  }
}
function record(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
function strings(value: unknown): value is string[] {
  return (
    Array.isArray(value) && value.every((item) => typeof item === 'string')
  );
}
function decision(value: unknown): boolean {
  return (
    record(value) &&
    ['matched', 'direct', 'blocked', 'indeterminate'].includes(
      String(value.status),
    ) &&
    (value.outbound == null || typeof value.outbound === 'string') &&
    strings(value.missing) &&
    Array.isArray(value.trace) &&
    value.trace.length <= 200 &&
    value.trace.every(
      (row) =>
        record(row) &&
        Number.isInteger(row.index) &&
        Number(row.index) >= 0 &&
        ['yes', 'no', 'unknown'].includes(String(row.match)) &&
        typeof row.action === 'string' &&
        typeof row.shadowed === 'boolean' &&
        strings(row.missing) &&
        (row.origin == null ||
          (record(row.origin) &&
            (row.origin.section == null ||
              typeof row.origin.section === 'string'))),
    )
  );
}
// Inspect only the bounded JSON contract; stderr can contain private paths,
// URLs or credentials and must never become a user-facing diagnostic.
export function parseRouteExplanationResult(result: {
  stdout: string;
  code?: number;
  failure?: string;
}): ExplainReport {
  if (result.failure)
    throw new RouteExplanationError(
      result.failure === 'timeout'
        ? 'timeout'
        : result.failure === 'permission_denied'
          ? 'permission_denied'
          : 'rpc_failed',
    );
  let report: unknown;
  if (typeof result.stdout === 'string' && result.stdout.length <= 262144) {
    try {
      report = JSON.parse(result.stdout);
    } catch {
      /* Classified below. */
    }
  }
  if (
    record(report) &&
    report.success === false &&
    report.error === 'permission_denied'
  )
    throw new RouteExplanationError('permission_denied');
  if (result.code) throw new RouteExplanationError('command_failed');
  if (!record(report) || typeof report.success !== 'boolean')
    throw new RouteExplanationError('invalid_response');
  if (!report.success) {
    if (
      ![
        'invalid_request',
        'configuration_changed_retry',
        'configuration_unavailable',
      ].includes(String(report.error))
    )
      throw new RouteExplanationError('command_failed');
    return report as unknown as ExplainReport;
  }
  if (
    !decision(report.decision) ||
    !strings(report.limitations) ||
    (report.dns_policy != null && !decision(report.dns_policy)) ||
    (report.generated_at != null &&
      (typeof report.generated_at !== 'number' ||
        !Number.isFinite(report.generated_at))) ||
    (report.selector != null &&
      (!record(report.selector) ||
        typeof report.selector.current !== 'string')) ||
    (report.rule_sets != null &&
      (!record(report.rule_sets) ||
        (report.rule_sets.unavailable_reasons != null &&
          (!Array.isArray(report.rule_sets.unavailable_reasons) ||
            !report.rule_sets.unavailable_reasons.every(
              (entry) =>
                record(entry) &&
                typeof entry.tag === 'string' &&
                typeof entry.reason === 'string',
            )))))
  )
    throw new RouteExplanationError('invalid_response');
  return report as unknown as ExplainReport;
}
export class RouteExplanationController {
  private active = false;
  private generation = 0;
  constructor(
    private read: (request: ExplainRequest) => Promise<ExplainReport>,
    private render: (
      report: ExplainReport | null,
      error: string,
      busy: boolean,
    ) => void,
  ) {}
  mount() {
    this.active = true;
    this.generation++;
    this.render(null, '', false);
  }
  unmount() {
    this.active = false;
    this.generation++;
  }
  async submit(request: ExplainRequest) {
    if (!this.active) return;
    const generation = ++this.generation;
    this.render(null, '', true);
    let report: ExplainReport;
    try {
      report = await this.read(request);
    } catch (error) {
      if (this.active && this.generation === generation)
        this.render(
          null,
          error instanceof RouteExplanationError
            ? error.category
            : 'Could not explain route',
          false,
        );
      return;
    }
    if (!this.active || this.generation !== generation) return;
    if (!report.success) {
      const error = [
        'invalid_request',
        'configuration_changed_retry',
        'configuration_unavailable',
      ].includes(report.error || '')
        ? report.error!
        : 'Could not explain route';
      this.render(null, error, false);
      return;
    }
    try {
      this.render(report, '', false);
    } catch {
      this.render(null, 'render_failed', false);
    }
  }
}
