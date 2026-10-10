export type VersionStage =
  | 'idle'
  | 'loading'
  | 'selected'
  | 'installing'
  | 'saving'
  | 'done'
  | 'failed';
export interface VersionState {
  stage: VersionStage;
  entries: Array<{
    id: string;
    version: string;
    available: boolean;
    reason: string;
  }>;
  currentVersion: string;
  currentVariant: string;
  cachedAt: number;
  pinnedVersion: string;
  selected: string;
  jobId: string;
  restored: boolean;
  error: string;
  unavailableReason: string;
}
export interface VersionRequest {
  action: 'catalog' | 'install' | 'pin' | 'unpin' | 'status';
  refresh?: boolean;
  candidate_id?: string;
  expected_current_version?: string;
  expected_current_variant?: string;
  pin?: boolean;
  job_id?: string;
}
const text = (value: unknown) => (typeof value === 'string' ? value : '');
const initial = (): VersionState => ({
  stage: 'idle',
  entries: [],
  currentVersion: '',
  currentVariant: '',
  cachedAt: 0,
  pinnedVersion: '',
  selected: '',
  jobId: '',
  restored: false,
  error: '',
  unavailableReason: '',
});
export class CoreVersionPicker {
  private active = false;
  private generation = 0;
  private pending = false;
  private state = initial();
  constructor(
    private call: (request: VersionRequest) => Promise<object>,
    private render: (state: VersionState) => void,
  ) {}
  mount() {
    this.active = true;
    this.generation++;
    this.pending = false;
    this.state = initial();
    this.render(this.state);
  }
  unmount() {
    this.active = false;
    this.generation++;
  }
  select(id: string) {
    if (!this.active || this.pending || this.state.stage === 'installing')
      return;
    if (!this.state.entries.some((entry) => entry.id === id && entry.available))
      return;
    this.state = {
      ...this.state,
      selected: id,
      stage: 'selected',
      error: '',
      restored: false,
    };
    this.render(this.state);
  }
  async load(refresh = false) {
    await this.request({ action: 'catalog', refresh });
  }
  async install(pin: boolean) {
    if (
      !this.state.selected ||
      !this.state.entries.some(
        (entry) => entry.id === this.state.selected && entry.available,
      )
    )
      return;
    await this.request({
      action: 'install',
      candidate_id: this.state.selected,
      expected_current_version: this.state.currentVersion,
      pin,
    });
  }
  async unpin() {
    await this.request({
      action: 'unpin',
      expected_current_version: this.state.currentVersion,
    });
  }
  async pin() {
    if (
      !this.state.currentVersion ||
      this.state.currentVersion === 'not-installed' ||
      !this.state.currentVariant
    )
      return;
    await this.request({
      action: 'pin',
      expected_current_version: this.state.currentVersion,
      expected_current_variant: this.state.currentVariant,
    });
  }
  async poll() {
    await this.request({
      action: 'status',
      ...(this.state.jobId ? { job_id: this.state.jobId } : {}),
    });
  }
  private async request(request: VersionRequest) {
    if (
      !this.active ||
      this.pending ||
      (this.state.stage === 'installing' && request.action !== 'status')
    )
      return;
    this.pending = true;
    const generation = this.generation;
    this.state = {
      ...this.state,
      error: request.action === 'status' ? this.state.error : '',
      stage:
        request.action === 'catalog'
          ? 'loading'
          : request.action === 'status'
            ? this.state.stage
            : request.action === 'pin' || request.action === 'unpin'
              ? 'saving'
              : 'installing',
    };
    this.render(this.state);
    try {
      const result = (await this.call(request)) as Record<string, unknown>;
      if (!this.active || generation !== this.generation) return;
      if (request.action === 'catalog') {
        this.state = {
          ...this.state,
          stage: result.success === true ? 'idle' : 'failed',
          selected: '',
          currentVersion:
            text(result.current_version) || this.state.currentVersion,
          currentVariant:
            text(result.current_variant) || this.state.currentVariant,
          cachedAt: Number(result.cached_at) || 0,
          pinnedVersion:
            result.pin && typeof result.pin === 'object'
              ? text((result.pin as Record<string, unknown>).version)
              : '',
          entries: Array.isArray(result.entries)
            ? result.entries
                .filter((entry) => entry && typeof entry === 'object')
                .map((entry: Record<string, unknown>) => ({
                  id: text(entry.id),
                  version: text(entry.version),
                  available:
                    result.success === true && entry.available === true,
                  reason: text(entry.reason),
                }))
            : [],
          unavailableReason: text(result.unavailable_reason),
          error:
            result.success === true
              ? ''
              : 'Could not load available versions. Check the connection and refresh the list.',
        };
      } else if (
        request.action === 'status' &&
        result.running !== true &&
        !this.state.jobId
      ) {
        // An idle worker is unrelated to the catalog request or current selection.
        return;
      } else if (result.success === false || result.rollback_error) {
        this.state = {
          ...this.state,
          stage: 'failed',
          restored: result.restored === true,
          error: result.rollback_error
            ? 'Restoration failed. Check the service before continuing.'
            : result.error === 'conflict'
              ? 'The installed version changed. Refresh the version list.'
              : 'The sing-box version operation failed.',
        };
      } else if (result.running === true) {
        this.state = {
          ...this.state,
          stage: 'installing',
          jobId: text(result.job_id),
          restored: false,
          error: '',
        };
      } else {
        this.state = {
          ...this.state,
          stage: 'done',
          restored: result.restored === true,
          ...(request.action === 'pin' || request.action === 'unpin'
            ? {
                pinnedVersion:
                  result.pin && typeof result.pin === 'object'
                    ? text((result.pin as Record<string, unknown>).version)
                    : '',
              }
            : {}),
        };
      }
    } catch {
      if (!this.active || generation !== this.generation) return;
      // Losing a status response is not evidence that a background install ended.
      this.state = {
        ...this.state,
        stage: request.action === 'status' ? this.state.stage : 'failed',
        ...(request.action === 'catalog'
          ? {
              selected: '',
              entries: this.state.entries.map((entry) => ({
                ...entry,
                available: false,
                reason: 'stale_catalog',
              })),
            }
          : {}),
        error:
          request.action === 'catalog'
            ? 'Could not load available versions. Check the connection and refresh the list.'
            : 'The sing-box version operation failed.',
      };
    } finally {
      if (this.active && generation === this.generation) {
        this.pending = false;
        this.render(this.state);
      }
    }
  }
}
