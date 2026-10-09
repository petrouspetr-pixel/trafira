export interface ProfileRequest {
  action: string;
  id?: string;
  name?: string;
  digest?: string;
}
export interface ProfileState {
  busy: boolean;
  running: boolean;
  digest: string;
  canRestore: boolean;
  entries: Array<{ id: string; name: string; invalid: boolean }>;
  preview: {
    id: string;
    applicable: boolean;
    digest: string;
    changes: Array<{ section: string; option: string; change: string }>;
  } | null;
  jobId: string;
  error: string;
  restored: boolean;
}
const initial = (): ProfileState => ({
  busy: false,
  running: false,
  digest: '',
  canRestore: false,
  entries: [],
  preview: null,
  jobId: '',
  error: '',
  restored: false,
});
const text = (value: unknown): string =>
  typeof value === 'string' ? value : '';
const errors: Record<string, string> = {
  conflict: 'Configuration changed. Review the differences again.',
  busy: 'Another configuration operation is already running.',
  recovery_required: 'Restore the interrupted operation before continuing.',
  candidate_check_failed:
    'The profile cannot be used with the current configuration and components.',
  invalid_profile: 'The profile format is invalid or unsupported.',
  profile_limit: 'A maximum of eight profiles can be saved.',
};
export class ProfilePanelController {
  private active = false;
  private generation = 0;
  private state = initial();
  constructor(
    private call: (request: ProfileRequest) => Promise<object>,
    private render: (state: ProfileState) => void,
  ) {}
  mount() {
    this.active = true;
    this.generation++;
    this.state = initial();
    this.render(this.state);
  }
  unmount() {
    this.active = false;
    this.generation++;
  }
  async submit(request: ProfileRequest) {
    if (!this.active || this.state.busy) return;
    if (this.state.running && !['status', 'list'].includes(request.action))
      return;
    const generation = ++this.generation;
    this.state = { ...this.state, busy: true, error: '', restored: false };
    this.render(this.state);
    try {
      const result = (await this.call(request)) as Record<string, unknown>;
      if (!this.active || generation !== this.generation) return;
      if (typeof result.running === 'boolean')
        this.state = { ...this.state, running: result.running };
      if (typeof result.digest === 'string')
        this.state = { ...this.state, digest: result.digest };
      if (typeof result.can_restore === 'boolean')
        this.state = { ...this.state, canRestore: result.can_restore };
      if (result.success === false || result.rollback_error) {
        this.state = {
          ...this.state,
          preview: null,
          error: result.rollback_error
            ? 'Restoration failed. Check the service before continuing.'
            : errors[text(result.error)] || 'The profile operation failed.',
          restored: result.restored === true,
        };
      } else {
        if (Array.isArray(result.entries)) {
          this.state = {
            ...this.state,
            entries: result.entries
              .filter((item) => item && typeof item === 'object')
              .map((item: Record<string, unknown>) => ({
                id: text(item.id),
                name: text(item.name),
                invalid: item.invalid === true,
              })),
          };
        }
        if (request.action === 'preview') {
          const changes = Array.isArray(result.changes) ? result.changes : [];
          this.state = {
            ...this.state,
            preview: {
              id: request.id || '',
              applicable: result.applicable !== false,
              digest: text(result.digest),
              changes: changes
                .filter((item) => item && typeof item === 'object')
                .map((item: Record<string, unknown>) => ({
                  section: text(item.section),
                  option: text(item.option),
                  change: text(item.change),
                })),
            },
          };
        }
        if (result.job_id)
          this.state = { ...this.state, jobId: text(result.job_id) };
        if (['apply', 'restore', 'remove'].includes(request.action))
          this.state = { ...this.state, preview: null };
        this.state = { ...this.state, restored: result.restored === true };
      }
    } catch {
      if (!this.active || generation !== this.generation) return;
      this.state = {
        ...this.state,
        error: 'The profile operation failed.',
        preview: null,
      };
    }
    if (this.active && generation === this.generation) {
      this.state = { ...this.state, busy: false };
      this.render(this.state);
    }
  }
}
