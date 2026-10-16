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
  dns_query?: {
    performed: boolean;
    origin: string;
    status?: string;
    addresses?: string[];
    truncated?: boolean;
    partial?: boolean;
    family?: string;
  };
  connection?: RouteConnection | null;
  destinations?: Array<{
    ip: string;
    decision: ExplainDecision;
    connection?: RouteConnection | null;
  }>;
  selector?: { tag: string; current: string } | null;
  rule_sets?: {
    basis: 'saved_snapshots' | 'local';
    live_verified: boolean;
    available: number;
    unavailable: number;
    cached?: number;
    unavailable_reasons?: Array<{ tag: string; reason: string }>;
  };
  limitations: string[];
}
export interface RouteConnection {
  label: string;
  type: string;
}
type RouteFailure =
  | 'timeout'
  | 'permission_denied'
  | 'command_failed'
  | 'rpc_failed'
  | 'invalid_response'
  | 'render_failed'
  | 'invalid_request'
  | 'invalid_job'
  | 'busy'
  | 'worker_timeout'
  | 'worker_interrupted'
  | 'storage_unavailable';
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
        'resource_limit',
      ].includes(String(report.error))
    )
      throw new RouteExplanationError('command_failed');
    return report as unknown as ExplainReport;
  }
  if (
    !decision(report.decision) ||
    !strings(report.limitations) ||
    (report.connection != null && !connection(report.connection)) ||
    (report.dns_query != null &&
      (!record(report.dns_query) ||
        typeof report.dns_query.performed !== 'boolean' ||
        typeof report.dns_query.origin !== 'string' ||
        (report.dns_query.status != null &&
          ![
            'resolved',
            'provided',
            'unavailable',
            'no_address',
            'fakeip',
            'failed',
            'timeout',
          ].includes(String(report.dns_query.status))) ||
        (report.dns_query.truncated != null &&
          typeof report.dns_query.truncated !== 'boolean') ||
        (report.dns_query.partial != null &&
          typeof report.dns_query.partial !== 'boolean') ||
        (report.dns_query.addresses != null &&
          (!strings(report.dns_query.addresses) ||
            report.dns_query.addresses.length > 4 ||
            report.dns_query.addresses.some(
              (address) => address.length > 45,
            ))))) ||
    (report.destinations != null &&
      (!Array.isArray(report.destinations) ||
        report.destinations.length > 4 ||
        !report.destinations.every(
          (item) =>
            record(item) &&
            typeof item.ip === 'string' &&
            item.ip.length <= 45 &&
            decision(item.decision) &&
            (item.connection == null || connection(item.connection)),
        ))) ||
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
function connection(value: unknown): boolean {
  return (
    record(value) &&
    typeof value.label === 'string' &&
    value.label.length <= 256 &&
    typeof value.type === 'string' &&
    value.type.length <= 64
  );
}
export interface PreparationProgress {
  completed: number;
  total: number;
  phase?: 'preparing' | 'evaluating' | 'finishing';
}
export interface RouteJobStatus {
  success: boolean;
  running: boolean;
  job_id?: string;
  progress?: PreparationProgress;
  report?: unknown;
  error?: string;
}
export function parseRouteJobCommandResult(result: {
  stdout: string;
  code?: number;
  failure?: string;
}): RouteJobStatus {
  if (result.failure)
    throw new RouteExplanationError(
      result.failure === 'timeout'
        ? 'timeout'
        : result.failure === 'permission_denied'
          ? 'permission_denied'
          : 'rpc_failed',
    );
  let value: unknown;
  try {
    value = JSON.parse(result.stdout);
  } catch {
    throw new RouteExplanationError('invalid_response');
  }
  if (
    !record(value) ||
    typeof value.success !== 'boolean' ||
    typeof value.running !== 'boolean'
  )
    throw new RouteExplanationError('invalid_response');
  if (!value.success) {
    const allowed = [
      'invalid_request',
      'invalid_job',
      'busy',
      'worker_timeout',
      'worker_interrupted',
      'resource_limit',
      'storage_unavailable',
    ];
    if (allowed.includes(String(value.error)))
      throw new RouteExplanationError(value.error as RouteFailure);
    throw new RouteExplanationError('command_failed');
  }
  if (
    result.code ||
    typeof value.job_id !== 'string' ||
    !/^r-[a-f0-9-]{1,60}$/.test(value.job_id)
  )
    throw new RouteExplanationError('invalid_response');
  const progress = value.progress;
  if (
    progress != null &&
    (!record(progress) ||
      !Number.isInteger(progress.completed) ||
      !Number.isInteger(progress.total) ||
      Number(progress.completed) < 0 ||
      Number(progress.total) < Number(progress.completed) ||
      Number(progress.total) > 256 ||
      !['preparing', 'evaluating', 'finishing'].includes(
        String(progress.phase),
      ))
  )
    throw new RouteExplanationError('invalid_response');
  return value as unknown as RouteJobStatus;
}
export async function runRoutePreparation(
  invoke: (name: string, args: string[]) => Promise<RouteJobStatus>,
  request: ExplainRequest,
  notify: (progress: PreparationProgress) => void,
  active: () => boolean,
  wait: () => Promise<void> = () =>
    new Promise((resolve) => setTimeout(resolve, 500)),
  resumeId?: string,
): Promise<ExplainReport> {
  let state: RouteJobStatus;
  if (resumeId && /^r-[a-f0-9-]{1,60}$/.test(resumeId)) {
    try {
      state = await invoke('route_explain_status', [resumeId]);
      if (state.job_id !== resumeId)
        throw new RouteExplanationError('invalid_response');
    } catch (error) {
      if (
        !(error instanceof RouteExplanationError) ||
        error.category !== 'invalid_job'
      )
        throw error;
      state = await invoke('route_explain_start', [JSON.stringify(request)]);
    }
  } else state = await invoke('route_explain_start', [JSON.stringify(request)]);
  const id = state.job_id,
    deadline = Date.now() + 150000;
  for (let polls = 0; polls < 300; polls++) {
    if (!active()) throw new Error('Route view no longer active');
    if (state.job_id !== id)
      throw new RouteExplanationError('invalid_response');
    if (!state.running)
      return parseRouteExplanationResult({
        stdout: JSON.stringify(state.report),
        code: 0,
      });
    if (state.progress) notify(state.progress);
    if (Date.now() >= deadline) break;
    await wait();
    if (!active()) throw new Error('Route view no longer active');
    try {
      state = await invoke('route_explain_status', [id!]);
    } catch (error) {
      // A lost status response does not stop the server job. Keep polling the
      // same ID within the original bounded deadline instead of starting again.
      if (
        !(error instanceof RouteExplanationError) ||
        !['timeout', 'rpc_failed'].includes(error.category)
      )
        throw error;
    }
  }
  throw new RouteExplanationError('worker_timeout');
}
export class RouteExplanationController {
  private active = false;
  private generation = 0;
  private pending = false;
  constructor(
    private read: (
      request: ExplainRequest,
      progress?: (value: PreparationProgress) => void,
      active?: () => boolean,
    ) => Promise<ExplainReport>,
    private render: (
      report: ExplainReport | null,
      error: string,
      busy: boolean,
      progress?: PreparationProgress,
    ) => void,
  ) {}
  mount() {
    this.active = true;
    this.pending = false;
    this.generation++;
    this.render(null, '', false);
  }
  unmount() {
    this.active = false;
    this.generation++;
  }
  async submit(request: ExplainRequest) {
    if (!this.active || this.pending) return;
    this.pending = true;
    const generation = ++this.generation;
    this.render(null, '', true);
    let report: ExplainReport;
    try {
      const active = () => this.active && this.generation === generation;
      report = await this.read(
        request,
        (progress) => {
          if (active()) this.render(null, '', true, progress);
        },
        active,
      );
    } catch (error) {
      if (this.generation === generation) this.pending = false;
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
    this.pending = false;
    if (!report.success) {
      const error = [
        'invalid_request',
        'configuration_changed_retry',
        'configuration_unavailable',
        'resource_limit',
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
