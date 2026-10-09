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
  outbound?: string;
  missing: string[];
  trace: Array<{
    index: number;
    match: string;
    action: string;
    shadowed: boolean;
    origin?: { kind?: string; section?: string };
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
  limitations: string[];
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
    try {
      const report = await this.read(request);
      if (!report.success) throw new Error('rejected');
      if (this.active && this.generation === generation)
        this.render(report, '', false);
    } catch {
      if (this.active && this.generation === generation)
        this.render(null, 'Could not explain route', false);
    }
  }
}
