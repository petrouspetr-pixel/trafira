export interface SnapshotReport {
  supported: boolean;
  available: boolean;
  preparable: boolean;
  entries: Array<{
    tag: string;
    present: boolean;
    bytes: number;
    mtime: number | null;
    configured_initial: boolean;
  }>;
  total_bytes: number;
  quota_bytes: number;
  max_file_bytes: number;
  job: { running: boolean; success: boolean; message: string } | null;
}

export interface SnapshotStartResult {
  success: boolean;
  message?: string;
}

export class SnapshotController {
  private active = false;
  private generation = 0;
  private failures = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private report: SnapshotReport | null = null;
  private starting = false;

  constructor(
    private read: () => Promise<SnapshotReport>,
    private start: () => Promise<SnapshotStartResult>,
    private render: (
      report: SnapshotReport | null,
      error: string,
      starting: boolean,
    ) => void,
  ) {}

  async mount() {
    this.unmount();
    this.active = true;
    this.failures = 0;
    await this.refresh();
  }

  unmount() {
    this.active = false;
    this.starting = false;
    this.generation++;
    clearTimeout(this.timer);
  }

  async refresh() {
    clearTimeout(this.timer);
    const generation = this.generation;
    try {
      const report = await this.read();
      if (!this.active || generation !== this.generation) return;
      this.report = report;
      this.failures = 0;
      this.render(report, '', this.starting);
    } catch {
      if (!this.active || generation !== this.generation) return;
      this.failures++;
      this.render(this.report, 'Could not read snapshot status', this.starting);
    }
    if (this.report?.job?.running && this.failures < 3) {
      this.timer = setTimeout(() => void this.refresh(), 3000);
    }
  }

  async prepare() {
    if (this.starting) return;
    const generation = this.generation;
    this.starting = true;
    this.render(this.report, '', true);
    try {
      const result = await this.start();
      if (!this.active || generation !== this.generation) return;
      this.starting = false;
      if (!result.success) {
        this.render(
          this.report,
          result.message || 'Could not start snapshot preparation',
          false,
        );
        return;
      }
      await this.refresh();
    } catch {
      if (this.active && generation === this.generation) {
        this.render(this.report, 'Could not start snapshot preparation', false);
      }
    } finally {
      if (generation === this.generation) this.starting = false;
    }
  }
}
