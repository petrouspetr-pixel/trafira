export type GamingSection = Record<string, unknown>;
export interface GamingOperation {
  action: 'upsert' | 'remove';
  preset?: string;
  device_ips?: string[];
  proxy_section?: string;
  placement?: string;
  enable_device?: boolean;
  replace_edited?: boolean;
  owner?: string;
  mode?: 'delete' | 'keep';
  confirm?: boolean;
}
export interface GamingAdapter {
  read(): GamingSection[];
  write(before: GamingSection[], after: GamingSection[]): void;
}
export interface GamingPlan {
  success: boolean;
  error?: string;
  config?: GamingSection[];
  conflicts?: string[];
}
// The planner needs no DNS credentials, server keys or unrelated outbound JSON.
// Managed rules remain complete so their manual-edit fingerprints are checked.
export function projectGamingSections(sections: GamingSection[]) {
  return sections.map((section) => {
    const fields =
      section['.type'] === 'settings'
        ? [
            'gaming_presets_enabled',
            'alice_mode_enabled',
            'alice_list_mode',
            'alice_ips',
            'alice_macs',
            'alice_interfaces',
          ]
        : ['enabled', 'action', 'label', 'source_ip_cidr', 'fully_routed_ips'];
    return structuredClone(
      Object.fromEntries(
        Object.entries(section).filter(
          ([key]) =>
            ['.name', '.type'].includes(key) ||
            (!key.startsWith('.') &&
              (Boolean(section.preset_owner) || fields.includes(key))),
        ),
      ),
    );
  });
}
export function gamingUciChanges(
  before: GamingSection[],
  after: GamingSection[],
) {
  const old = new Map(before.map((s) => [String(s['.name']), s]));
  const next = new Map(after.map((s) => [String(s['.name']), s]));
  const removed: string[] = [],
    added: GamingSection[] = [];
  const edits: Array<{ section: string; option: string; value?: unknown }> = [];
  for (const [name, section] of old)
    if (!next.has(name)) {
      if (!section.preset_owner) throw Error('invalid_plan');
      removed.push(name);
    }
  for (const [name, section] of next) {
    const prior = old.get(name);
    if (!prior) {
      if (!section.preset_owner) throw Error('invalid_plan');
      added.push(section);
      continue;
    }
    for (const key of new Set([
      ...Object.keys(prior),
      ...Object.keys(section),
    ])) {
      if (key.startsWith('.')) continue;
      if (JSON.stringify(prior[key]) !== JSON.stringify(section[key]))
        edits.push({ section: name, option: key, value: section[key] });
    }
  }
  return { removed, added, edits, order: after.map((s) => String(s['.name'])) };
}
export class GamingDraft {
  private adapter: GamingAdapter | null = null;
  private operations: GamingOperation[] = [];
  private result: GamingPlan | null = null;
  private revision = 0;
  private work: Promise<void> | null = null;
  private saving = false;
  private saveRequested = false;
  private flushed: { before: GamingSection[]; after: GamingSection[] } | null =
    null;
  private prepare: (() => Promise<void>) | null = null;
  private listeners = new Set<() => void>();
  constructor(
    private plan: (
      sections: GamingSection[],
      operations: GamingOperation[],
    ) => Promise<unknown>,
  ) {}
  bind(adapter: GamingAdapter) {
    if (adapter === this.adapter) return;
    this.adapter = adapter;
    this.reset();
  }
  get pending() {
    return this.operations.length;
  }
  get epoch() {
    return this.revision;
  }
  setPrepare(prepare: () => Promise<void>) {
    this.prepare = prepare;
    return () => {
      if (this.prepare === prepare) this.prepare = null;
    };
  }
  get busy() {
    return Boolean(this.work) || this.saving;
  }
  get conflicts() {
    return this.result?.conflicts || [];
  }
  savedOwner(owner: string) {
    return this.snapshot().some((s) => s.preset_owner === owner);
  }
  sections() {
    return structuredClone(this.result?.config || this.snapshot());
  }
  subscribe(listener: () => void) {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
  private emit() {
    for (const listener of this.listeners) listener();
  }
  private snapshot() {
    if (!this.adapter) throw Error('draft_unavailable');
    return projectGamingSections(this.adapter.read());
  }
  private async calculate(operations: GamingOperation[]) {
    const before = this.snapshot();
    const result = (await this.plan(
      before,
      structuredClone(operations),
    )) as GamingPlan;
    if (result?.success !== true) throw Error(result?.error || 'invalid_plan');
    if (
      !Array.isArray(result.config) ||
      !result.config.every(
        (s) =>
          s &&
          typeof s === 'object' &&
          typeof s['.name'] === 'string' &&
          typeof s['.type'] === 'string',
      )
    )
      throw Error('invalid_plan');
    gamingUciChanges(before, result.config);
    return { before, result };
  }
  async stage(operation: GamingOperation) {
    if (this.busy) throw Error('busy');
    const revision = this.revision;
    const operations = [...this.operations, structuredClone(operation)];
    const work = (async () => {
      const { result } = await this.calculate(operations);
      if (revision !== this.revision) return;
      this.operations = operations;
      this.result = result;
    })();
    this.work = work;
    this.emit();
    try {
      await work;
    } finally {
      if (this.work === work) this.work = null;
      this.emit();
    }
  }
  reset() {
    this.revision++;
    this.operations = [];
    this.result = null;
    this.work = null;
    this.emit();
  }
  async flush() {
    if (!this.saving) throw Error('invalid_save');
    if (!this.pending) return;
    const { before, result } = await this.calculate(this.operations);
    this.flushed = { before, after: result.config! };
    this.adapter!.write(before, result.config!);
  }
  async save<T>(persist: () => Promise<T>): Promise<T> {
    if (this.saveRequested) throw Error('busy');
    this.saveRequested = true;
    try {
      if (this.work) await this.work;
      if (this.prepare) await this.prepare();
      this.saving = true;
      this.emit();
      const result = await persist();
      this.flushed = null;
      this.reset();
      return result;
    } catch (error) {
      if (this.flushed) {
        const { before, after } = this.flushed;
        this.flushed = null;
        this.adapter!.write(after, before);
      }
      throw error;
    } finally {
      this.saving = false;
      this.saveRequested = false;
      this.emit();
    }
  }
}
