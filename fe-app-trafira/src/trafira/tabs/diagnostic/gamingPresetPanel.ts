import {
  isTrackedConfigurationCommit,
  observeConfigurationCommit,
  trackConfigurationCommit,
} from '../../helpers/configurationSync';

export interface GamingSelection {
  preset?: string;
  device_ips?: string[];
  proxy_section?: string;
  placement?: string;
  enable_device?: boolean;
  replace_edited?: boolean;
  owner?: string;
  mode?: string;
  confirm?: boolean;
}
export interface GamingState {
  busy: boolean;
  running: boolean;
  jobId: string;
  error: string;
  preview: Record<string, unknown> | null;
  committed: boolean;
}
export class GamingPresetController {
  private active = false;
  private generation = 0;
  private reviewed: Record<string, unknown> | null = null;
  private state: GamingState = {
    busy: false,
    running: false,
    jobId: '',
    error: '',
    preview: null,
    committed: false,
  };
  constructor(
    private call: (
      request: Record<string, unknown>,
    ) => Promise<Record<string, unknown>>,
    private render: (state: GamingState) => void,
  ) {}
  mount() {
    this.active = true;
    this.generation++;
    this.render(this.state);
  }
  unmount() {
    this.active = false;
    this.generation++;
  }
  invalidate() {
    this.reviewed = null;
    this.state.preview = null;
    this.render({ ...this.state });
  }
  async preview(selection: GamingSelection, digest: string) {
    if (
      !selection.owner &&
      (!selection.preset ||
        !selection.device_ips?.length ||
        !selection.proxy_section ||
        !['before-device-routes', 'after-device-routes'].includes(
          selection.placement || '',
        ))
    )
      return;
    if (!digest) return;
    await this.submit({
      ...selection,
      action: selection.owner ? 'preview_remove' : 'preview',
      expected_digest: digest,
    });
  }
  async apply() {
    if (!this.reviewed || !this.state.preview?.applicable) return;
    await this.submit({
      ...this.reviewed,
      action: this.reviewed.owner ? 'remove' : 'apply',
    });
  }
  async poll() {
    await this.submit({ action: 'status' });
  }
  private async submit(request: Record<string, unknown>) {
    if (
      !this.active ||
      this.state.busy ||
      (this.state.running && request.action !== 'status')
    )
      return;
    const generation = ++this.generation;
    this.state = {
      ...this.state,
      busy: true,
      error: request.action === 'status' ? this.state.error : '',
      committed: request.action === 'status' ? this.state.committed : false,
    };
    this.render(this.state);
    try {
      const result = await this.call(request);
      if (
        ['apply', 'remove'].includes(String(request.action)) &&
        result.success === true &&
        result.running === true &&
        typeof result.job_id === 'string'
      )
        trackConfigurationCommit(result.job_id, () =>
          this.call({ action: 'status' }),
        );
      if (!this.active || generation !== this.generation) return;
      const ownStatus =
        request.action === 'status' &&
        isTrackedConfigurationCommit(result.job_id);
      const committed =
        request.action === 'status' && observeConfigurationCommit(result);
      // Profiles and presets share a durable last-job record. A finished job
      // observed before this page's current work must not invalidate its preview.
      // An unfinished recovery remains actionable even after reconnecting.
      if (
        request.action === 'status' &&
        result.running === false &&
        !this.state.running &&
        !ownStatus &&
        !result.recovery_pending
      )
        return;
      if (committed) this.state.committed = true;
      if (typeof result.running === 'boolean')
        this.state.running = result.running;
      if (typeof result.job_id === 'string') this.state.jobId = result.job_id;
      if (result.success === false || result.rollback_error) {
        this.reviewed = null;
        this.state.preview = null;
        this.state.error = result.rollback_error
          ? 'rollback_failed'
          : String(result.error || 'operation_failed');
      } else if (
        request.action === 'preview' ||
        request.action === 'preview_remove'
      ) {
        this.state.preview = result;
        this.reviewed =
          result.applicable === true
            ? {
                ...request,
                device_ips: Array.isArray(request.device_ips)
                  ? [...request.device_ips]
                  : undefined,
              }
            : null;
      } else if (request.action !== 'status') {
        this.reviewed = null;
        this.state.preview = null;
      }
    } catch {
      if (this.active && generation === this.generation) {
        this.state.error = 'request_failed';
        this.reviewed = null;
        this.state.preview = null;
      }
    } finally {
      if (this.active && generation === this.generation) {
        this.state = { ...this.state, busy: false };
        this.render(this.state);
      }
    }
  }
}
