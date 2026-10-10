import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));

class Node {
  children: Array<Node | string> = [];
  value = '';
  disabled = false;
  textContent = '';
  className = '';
  href = '';
  download = '';
  htmlFor = '';
  files: Array<{ size: number; arrayBuffer: () => Promise<ArrayBuffer> }> = [];
  events: Record<string, () => void> = {};
  constructor(
    public tag: string,
    public attrs: Record<string, unknown> = {},
  ) {
    this.value = String(attrs.value || '');
    this.disabled = Object.prototype.hasOwnProperty.call(attrs, 'disabled');
    this.className = String(attrs.class || '');
  }
  get id() {
    return String(this.attrs.id || '');
  }
  replaceChildren(...nodes: Array<Node | string>) {
    this.children = nodes;
    if (this.tag === 'select')
      this.value = String((nodes[0] as Node)?.attrs.value || '');
  }
  append(...nodes: Array<Node | string>) {
    this.children.push(...nodes);
  }
  addEventListener(name: string, callback: () => void) {
    this.events[name] = callback;
  }
  fire(name: string) {
    if (!this.disabled)
      (this.events[name] || (this.attrs[name] as (() => void) | undefined))?.();
  }
  click() {
    downloaded.push(this);
    this.fire('click');
  }
}
function all(node: Node): Node[] {
  return [
    node,
    ...node.children.flatMap((n) => (typeof n === 'string' ? [] : all(n))),
  ];
}
function text(node: Node): string {
  return (
    node.textContent +
    ' ' +
    node.children.map((n) => (typeof n === 'string' ? n : text(n))).join(' ')
  );
}
const drain = async () => {
  for (let i = 0; i < 30; i++) await Promise.resolve();
};
let profilesPanel: typeof import('../renderProfiles').profilesPanel;
let host: Node;
let entries: Array<{ id: string; name: string; invalid?: boolean }>;
let canRestore: boolean;
let running: boolean;
let jobId: string;
let failure: { action: string; result: Record<string, unknown> } | undefined;
let previewResult: Record<string, unknown> | undefined;
let transferBytes: Uint8Array;
const digest = 'a'.repeat(64);
const requests: Record<string, unknown>[] = [];
const downloaded: Node[] = [];
const blobs: Blob[] = [];
const confirm = vi.fn();
const reload = vi.fn();
const revoked = vi.fn();
const button = (label: string) =>
  all(host).find((n) => n.tag === 'button' && text(n).trim() === label)!;
const field = (id: string) => all(host).find((n) => n.attrs.id === id)!;
async function click(label: string) {
  button(label).fire('click');
  await drain();
}
async function select(id: string) {
  const selected = all(host).find((n) => n.tag === 'select')!;
  selected.value = id;
  selected.fire('change');
  await drain();
}
function input(id: string, value: string) {
  field(id).value = value;
  field(id).fire('input');
}

beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  vi.clearAllMocks();
  requests.length = downloaded.length = blobs.length = 0;
  entries = [
    { id: 'p-first', name: 'Home' },
    { id: 'p-second', name: 'Travel' },
  ];
  canRestore = false;
  running = false;
  jobId = '';
  failure = undefined;
  previewResult = undefined;
  transferBytes = new Uint8Array();
  confirm.mockReturnValue(true);
  host = new Node('div');
  vi.stubGlobal('_', (s: string) => s);
  vi.stubGlobal('window', {
    setInterval,
    clearInterval,
    confirm,
    location: { reload },
  });
  vi.stubGlobal('document', {
    getElementById: () => host,
    createElement: (tag: string) => new Node(tag),
  });
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attrs: Record<string, unknown>,
      children: Array<Node | string> | string = [],
    ) => {
      const node = new Node(tag, attrs);
      node.replaceChildren(
        ...(Array.isArray(children) ? children : [children]),
      );
      return node;
    },
  );
  vi.spyOn(URL, 'createObjectURL').mockImplementation((blob) => {
    blobs.push(blob as Blob);
    return 'blob:profile';
  });
  vi.spyOn(URL, 'revokeObjectURL').mockImplementation(revoked);
  vi.mocked(executeShellCommand).mockImplementation(async ({ args }) => {
    const r = JSON.parse(args[1]) as Record<string, unknown>;
    requests.push(r);
    let result: Record<string, unknown>;
    if (failure && failure.action === r.action) {
      result = failure.result;
      failure = undefined;
    } else if (r.action === 'list') {
      result = {
        success: true,
        entries: entries.map((e) => ({ ...e })),
        digest,
        can_restore: canRestore,
      };
    } else if (r.action === 'status') {
      result = { success: true, running, ...(jobId ? { job_id: jobId } : {}) };
    } else if (r.action === 'create') {
      entries.push({ id: 'p-created', name: String(r.name) });
      result = { success: true, id: 'p-created' };
    } else if (r.action === 'rename') {
      entries.find((e) => e.id === r.id)!.name = String(r.name);
      result = { success: true, id: r.id };
    } else if (r.action === 'remove') {
      entries = entries.filter((e) => e.id !== r.id);
      result = { success: true };
    } else if (r.action === 'preview') {
      result = previewResult || {
        success: true,
        applicable: true,
        digest,
        changes: [
          {
            section: 'connection',
            option: 'server',
            change: 'changed',
            before: 'private-old',
            after: 'private-new',
          },
        ],
      };
    } else if (r.action === 'apply' || r.action === 'restore') {
      running = true;
      jobId = 'j-own';
      result = { success: true, running: true, job_id: jobId };
    } else if (r.action === 'import_begin') {
      transferBytes = new Uint8Array();
      result = { success: true, id: 'import-1' };
    } else if (r.action === 'import_chunk') {
      const chunk = Uint8Array.from(atob(String(r.data)), (c) =>
        c.charCodeAt(0),
      );
      if (r.offset !== transferBytes.length)
        throw new Error('Wrong import offset');
      const bytes = new Uint8Array(transferBytes.length + chunk.length);
      bytes.set(transferBytes);
      bytes.set(chunk, transferBytes.length);
      transferBytes = bytes;
      result = { success: true };
    } else if (r.action === 'import_finish') {
      const document = JSON.parse(new TextDecoder().decode(transferBytes));
      entries.push({ id: 'p-imported', name: document.name });
      result = { success: true, id: 'p-imported' };
    } else if (r.action === 'export_begin') {
      transferBytes = new TextEncoder().encode(
        JSON.stringify({
          schema: 1,
          name: entries.find((e) => e.id === r.id)!.name,
          config: { token: 'private'.repeat(4000) },
        }),
      );
      result = { success: true, id: 'export-1' };
    } else if (r.action === 'export_read') {
      const offset = Number(r.offset),
        chunk = transferBytes.slice(offset, offset + 12288);
      result = {
        success: true,
        data: btoa(Array.from(chunk, (b) => String.fromCharCode(b)).join('')),
        done: offset + chunk.length === transferBytes.length,
      };
    } else if (r.action === 'transfer_cancel') result = { success: true };
    else throw new Error('Unexpected profile action');
    return { code: 0, stdout: JSON.stringify(result), stderr: '' };
  });
  ({ profilesPanel } = await import('../renderProfiles'));
});
afterEach(() => {
  profilesPanel.unmount();
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

it('keeps management and transfer visible and separates creation from renaming', async () => {
  profilesPanel.mount();
  await drain();
  expect(all(host).filter((n) => n.tag === 'details')).toHaveLength(0);
  expect(
    all(host).filter((n) => n.tag === 'input' && n.attrs.type === 'text'),
  ).toHaveLength(2);
  expect(button('Import profile')).toBeDefined();
  expect(button('Export profile')).toBeDefined();
  expect(button('Rename profile')).toBeDefined();
  expect(button('Delete profile')).toBeDefined();
  for (const option of all(host).filter((n) => n.tag === 'option')) {
    expect(option.attrs).not.toHaveProperty('disabled');
    expect(option.disabled).toBe(false);
  }
  for (const id of [
    'trafira-profile-create-name',
    'trafira-profile-rename-name',
    'trafira-profile-selected',
    'trafira-profile-import',
  ])
    expect(all(host).some((n) => n.tag === 'label' && n.htmlFor === id)).toBe(
      true,
    );
});

it('aligns controls with native LuCI fields and keeps gaps around every action', async () => {
  profilesPanel.mount();
  await drain();
  for (const control of all(host).filter((n) =>
    ['button', 'input', 'select'].includes(n.tag),
  )) {
    const row = all(host).find(
      (n) => n.className === 'cbi-value' && all(n).includes(control),
    );
    expect(row).toBeDefined();
    expect(
      row?.children.some(
        (n) =>
          typeof n !== 'string' &&
          n.tag === 'label' &&
          n.className === 'cbi-value-title',
      ),
    ).toBe(true);
    expect(
      all(row!).some(
        (n) =>
          n.className === 'cbi-value-field' &&
          n.children.some(
            (c) =>
              typeof c !== 'string' &&
              c.className === 'trafira-profile-controls' &&
              all(c).includes(control),
          ),
      ),
    ).toBe(true);
  }
});

it('creates, selects, renames and deletes the intended profile with separate name fields', async () => {
  profilesPanel.mount();
  await drain();
  input('trafira-profile-create-name', 'Work');
  await click('Create profile from saved settings');
  expect(requests.find((r) => r.action === 'create')).toMatchObject({
    name: 'Work',
  });
  expect(all(host).find((n) => n.tag === 'select')!.value).toBe('p-created');
  expect(field('trafira-profile-create-name').value).toBe('');
  input('trafira-profile-rename-name', 'Office');
  await click('Rename profile');
  expect(requests.find((r) => r.action === 'rename')).toMatchObject({
    id: 'p-created',
    name: 'Office',
  });
  expect(text(host)).toContain('Office');
  await click('Delete profile');
  expect(requests.find((r) => r.action === 'remove')).toMatchObject({
    id: 'p-created',
  });
  expect(entries.some((e) => e.id === 'p-created')).toBe(false);
  expect(all(host).find((n) => n.tag === 'select')!.value).toBe('');
});

it('requires successful review for the selected profile and drops it when the selection changes', async () => {
  profilesPanel.mount();
  await drain();
  await select('p-first');
  expect(button('Apply profile').disabled).toBe(true);
  await click('Show differences');
  expect(text(host)).toContain('server');
  expect(text(host)).not.toContain('private-old');
  expect(button('Apply profile').disabled).toBe(false);
  await select('p-second');
  expect(button('Apply profile').disabled).toBe(true);
  expect(text(host)).not.toContain('server');
  await select('p-first');
  expect(button('Apply profile').disabled).toBe(true);
  await click('Show differences');
  confirm.mockReturnValueOnce(false);
  await click('Apply profile');
  expect(requests.some((r) => r.action === 'apply')).toBe(false);
  await click('Apply profile');
  expect(requests.find((r) => r.action === 'apply')).toMatchObject({
    id: 'p-first',
    digest,
  });
  expect(reload).not.toHaveBeenCalled();
  running = false;
  await vi.advanceTimersByTimeAsync(2000);
  await drain();
  expect(reload).toHaveBeenCalledTimes(1);
});

it.each([
  { success: true, digest, changes: [] },
  { success: true, applicable: true, changes: [] },
  { success: false, error: 'candidate_check_failed' },
])(
  'does not enable application from an incomplete or unsuccessful preview: %j',
  async (result) => {
    previewResult = result;
    profilesPanel.mount();
    await drain();
    await select('p-first');
    await click('Show differences');
    expect(button('Apply profile').disabled).toBe(true);
    expect(requests.some((r) => r.action === 'apply')).toBe(false);
    expect(text(host)).toContain(
      result.success === false
        ? 'The profile cannot be used with the current configuration and components.'
        : 'The profile operation failed.',
    );
  },
);

it('allows deleting an invalid saved profile while preventing preview and export', async () => {
  entries = [{ id: 'p-invalid', name: 'Damaged', invalid: true }];
  profilesPanel.mount();
  await drain();
  expect(
    all(host).find((n) => n.tag === 'option' && n.attrs.value === 'p-invalid')!
      .disabled,
  ).toBe(false);
  await select('p-invalid');
  expect(button('Show differences').disabled).toBe(true);
  expect(button('Export profile').disabled).toBe(true);
  expect(button('Delete profile').disabled).toBe(false);
  await click('Delete profile');
  expect(entries).toHaveLength(0);
});

it('restores only an available previous configuration after confirmation and confirmed completion', async () => {
  profilesPanel.mount();
  await drain();
  expect(button('Restore previous settings').disabled).toBe(true);
  profilesPanel.unmount();
  canRestore = true;
  profilesPanel.mount();
  await drain();
  confirm.mockReturnValueOnce(false);
  await click('Restore previous settings');
  expect(requests.some((r) => r.action === 'restore')).toBe(false);
  await click('Restore previous settings');
  expect(requests.find((r) => r.action === 'restore')).toMatchObject({
    digest,
  });
  expect(reload).not.toHaveBeenCalled();
  running = false;
  await vi.advanceTimersByTimeAsync(2000);
  await drain();
  expect(reload).toHaveBeenCalledTimes(1);
});

it('imports all file chunks, refreshes the new profile and closes the transfer', async () => {
  profilesPanel.mount();
  await drain();
  const document = {
    schema: 1,
    name: 'Imported',
    config: { value: 'x'.repeat(25000) },
  };
  const bytes = new TextEncoder().encode(JSON.stringify(document));
  const file = all(host).find((n) => n.attrs.type === 'file')!;
  expect(button('Import profile').disabled).toBe(true);
  file.files = [{ size: bytes.length, arrayBuffer: async () => bytes.buffer }];
  file.fire('change');
  await click('Import profile');
  expect(JSON.parse(new TextDecoder().decode(transferBytes))).toEqual(document);
  expect(requests.filter((r) => r.action === 'import_chunk')).toHaveLength(3);
  expect(requests.some((r) => r.action === 'import_finish')).toBe(true);
  expect(requests.find((r) => r.action === 'transfer_cancel')).toMatchObject({
    id: 'import-1',
  });
  expect(all(host).find((n) => n.tag === 'select')!.value).toBe('p-imported');
});

it('exports the selected profile in chunks into a complete downloaded JSON file', async () => {
  profilesPanel.mount();
  await drain();
  await select('p-second');
  await click('Export profile');
  expect(requests.find((r) => r.action === 'export_begin')).toMatchObject({
    id: 'p-second',
  });
  expect(
    requests.filter((r) => r.action === 'export_read').length,
  ).toBeGreaterThan(1);
  expect(JSON.parse(await blobs[0].text())).toEqual(
    JSON.parse(new TextDecoder().decode(transferBytes)),
  );
  expect(downloaded[0].download).toBe('trafira-profile.json');
  expect(revoked).toHaveBeenCalledWith('blob:profile');
  expect(requests.find((r) => r.action === 'transfer_cancel')).toMatchObject({
    id: 'export-1',
  });
  expect(text(host)).not.toContain('privateprivate');
});

it('keeps backend transfer failures distinct from invalid-file failures', async () => {
  profilesPanel.mount();
  await drain();
  const file = all(host).find((n) => n.attrs.type === 'file')!;
  const bytes = new TextEncoder().encode(
    '{"schema":1,"name":"Imported","config":{}}',
  );
  file.files = [{ size: bytes.length, arrayBuffer: async () => bytes.buffer }];
  file.fire('change');
  failure = {
    action: 'import_finish',
    result: { success: false, error: 'profile_limit' },
  };
  await click('Import profile');
  expect(text(host)).toContain('A maximum of eight profiles can be saved.');
  expect(requests.some((r) => r.action === 'transfer_cancel')).toBe(true);
});

it('clears stale review and shows a configuration conflict without reloading', async () => {
  profilesPanel.mount();
  await drain();
  await select('p-first');
  await click('Show differences');
  failure = { action: 'apply', result: { success: false, error: 'conflict' } };
  await click('Apply profile');
  expect(text(host)).toContain(
    'Configuration changed. Review the differences again.',
  );
  expect(button('Apply profile').disabled).toBe(true);
  expect(reload).not.toHaveBeenCalled();
});

it('keeps a failed list visible and allows an explicit retry', async () => {
  failure = {
    action: 'list',
    result: { success: false, error: 'storage_unavailable' },
  };
  profilesPanel.mount();
  await drain();
  expect(text(host)).toContain('The profile operation failed.');
  expect(button('Refresh profiles').disabled).toBe(false);
  await click('Refresh profiles');
  expect(text(host)).not.toContain('The profile operation failed.');
  expect(text(host)).toContain('Home');
});

it('rejects an oversized import before opening a transfer', async () => {
  profilesPanel.mount();
  await drain();
  const file = all(host).find((n) => n.attrs.type === 'file')!;
  file.files = [{ size: 1048577, arrayBuffer: async () => new ArrayBuffer(0) }];
  file.fire('change');
  expect(button('Import profile').disabled).toBe(true);
  expect(text(host)).toContain('Select a valid JSON file of up to 1 MiB.');
  await click('Import profile');
  expect(requests.some((r) => String(r.action).startsWith('import_'))).toBe(
    false,
  );
});

it('closes a failed export without producing an empty download', async () => {
  profilesPanel.mount();
  await drain();
  await select('p-first');
  failure = {
    action: 'export_read',
    result: { success: true, data: '', done: false },
  };
  await click('Export profile');
  expect(downloaded).toHaveLength(0);
  expect(blobs).toHaveLength(0);
  expect(text(host)).toContain('The profile operation failed.');
  expect(requests.some((r) => r.action === 'transfer_cancel')).toBe(true);
});

it('permits read-only list and review but no creation, restoration, transfer or selected-profile mutation', async () => {
  canRestore = true;
  profilesPanel.mount(false);
  await drain();
  await select('p-first');
  await click('Show differences');
  expect(requests.some((r) => r.action === 'preview')).toBe(true);
  for (const label of [
    'Create profile from saved settings',
    'Rename profile',
    'Delete profile',
    'Apply profile',
    'Restore previous settings',
    'Import profile',
    'Export profile',
  ]) {
    expect(button(label).disabled).toBe(true);
    (button(label).attrs.click as () => void)();
  }
  await drain();
  expect(
    requests.every((r) =>
      ['list', 'status', 'preview'].includes(String(r.action)),
    ),
  ).toBe(true);
});
