import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import type { GamingSection } from '../../configuration/gamingDraft';
import { gamingDraft } from '../../configuration/gamingDraft.service';
import { gamingPresetsPanel } from '../renderGamingPresets';
vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));
vi.mock('../../../helpers/configurationSync', () => ({
  confirmAction: vi.fn(async () => true),
}));
class Node {
  children: Array<Node | string> = [];
  value = '';
  disabled = false;
  checked = false;
  hidden = false;
  private ownText = '';
  get textContent() {
    return this.ownText;
  }
  set textContent(value: string) {
    this.ownText = value;
    this.children = [];
  }
  events: Record<string, () => void> = {};
  constructor(
    public tag: string,
    public attrs: Record<string, unknown> = {},
  ) {
    this.value = String(attrs.value || '');
  }
  append(...nodes: Array<Node | string>) {
    this.children.push(...nodes);
  }
  replaceChildren(...nodes: Array<Node | string>) {
    this.children = nodes;
    if (this.tag === 'select')
      this.value = String((nodes[0] as Node)?.attrs.value || '');
  }
  addEventListener(name: string, callback: () => void) {
    this.events[name] = callback;
  }
  querySelectorAll(selector: string): Node[] {
    return all(this).filter(
      (n) =>
        n !== this &&
        (selector === 'input:checked'
          ? n.tag === 'input' && n.checked
          : n.tag === selector),
    );
  }
  fire(name: string) {
    if (this.disabled) return;
    (this.events[name] || (this.attrs[name] as (() => void) | undefined))?.();
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
let host: Node;
let saved: GamingSection[];
const write = vi.fn();
const requests: Array<Record<string, unknown>> = [];
const drain = async () => {
  for (let i = 0; i < 30; i++) await Promise.resolve();
};
const button = (label: string) =>
  all(host).find((n) => n.tag === 'button' && text(n).trim() === label)!;
function select(id: string, value: string) {
  const n = all(host).find((n) => n.attrs.id === id)!;
  n.value = value;
  n.fire('change');
}
function fill(platform = 'steam') {
  select('trafira-game-platform', platform);
  select('trafira-game-device', '0');
  select('trafira-game-proxy', 'vpn');
}
beforeEach(() => {
  vi.clearAllMocks();
  requests.length = 0;

  host = new Node('div');
  vi.stubGlobal('_', (s: string) => s);
  vi.stubGlobal('document', { getElementById: () => host });
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attrs: Record<string, unknown>,
      children: Array<Node | string> | string = [],
    ) => {
      const n = new Node(tag, attrs);
      n.replaceChildren(...(Array.isArray(children) ? children : [children]));
      return n;
    },
  );
  saved = [
    { '.name': 'settings', '.type': 'settings', gaming_presets_enabled: '0' },
    {
      '.name': 'vpn',
      '.type': 'section',
      enabled: '1',
      action: 'connection',
      label: 'My VPN',
    },
  ];
  gamingDraft.bind({ read: () => saved, write });
  vi.mocked(executeShellCommand).mockImplementation(async ({ args }) => {
    const r = JSON.parse(args[1]);
    requests.push(r);
    const config = structuredClone(r.sections || []);
    for (const op of r.operations || []) {
      if (op.action === 'remove') {
        for (let i = config.length - 1; i >= 0; i--)
          if (config[i].preset_owner === op.owner) config.splice(i, 1);
      } else {
        const owner =
          'game_' +
          op.preset +
          '_30323a30303a30303a30303a30303a30314062722d6c616e';
        config.push({
          '.name': owner + '_store',
          '.type': 'section',
          preset_owner: owner,
          preset_platform: op.preset,
          source_ip_cidr: op.device_ips,
          outbound_detour_section: op.proxy_section,
        });
      }
    }
    const result =
      r.action === 'catalog'
        ? {
            success: true,
            presets: [{ id: 'steam' }, { id: 'epic' }],
            devices: [
              {
                name: 'PC',
                mac: '02:00:00:00:00:01',
                interface: 'br-lan',
                ips: ['192.0.2.5'],
              },
            ],
          }
        : { success: true, config };
    return { code: 0, stdout: JSON.stringify(result), stderr: '' };
  });
});
afterEach(() => {
  vi.useRealTimers();
  gamingPresetsPanel.unmount();
  vi.unstubAllGlobals();
});
it('stages multiple platforms and deletion without persistence or service operations', async () => {
  gamingPresetsPanel.mount();
  await drain();
  expect(button('Add to list').disabled).toBe(true);
  fill();
  button('Add to list').fire('click');
  await drain();
  fill('epic');
  button('Add to list').fire('click');
  await drain();
  expect(text(host)).toContain('Epic Games');
  expect(text(host)).toContain('My VPN');
  button('Delete').fire('click');
  await drain();
  expect(gamingDraft.pending).toBe(3);
  expect(write).not.toHaveBeenCalled();
  expect(
    requests.every((r) => ['catalog', 'plan'].includes(String(r.action))),
  ).toBe(true);
  expect(text(host)).not.toContain('Apply reviewed changes');
  expect(text(host)).not.toContain('Preview gaming rules');
  expect(text(host)).toContain('Save & Apply');
});
it('retains editor across tabs and discards queued changes on native Reset', async () => {
  gamingPresetsPanel.mount();
  await drain();
  fill();
  gamingPresetsPanel.unmount();
  gamingPresetsPanel.mount();
  expect(button('Add to list').disabled).toBe(false);
  button('Add to list').fire('click');
  await drain();
  expect(gamingDraft.pending).toBe(1);
  gamingDraft.reset();
  expect(gamingDraft.pending).toBe(0);
  expect(text(host)).toContain('No gaming presets in the list yet.');
  expect(button('Add to list').disabled).toBe(true);
});
it('native Save includes a ready editor and blocks incomplete input', async () => {
  gamingPresetsPanel.mount();
  await drain();
  select('trafira-game-platform', 'steam');
  const persist = vi.fn(async () => {
    await gamingDraft.flush();
  });
  await expect(gamingDraft.save(persist)).rejects.toThrow('incomplete_editor');
  expect(persist).not.toHaveBeenCalled();
  fill();
  await gamingDraft.save(persist);
  expect(write).toHaveBeenCalledTimes(1);
  expect(persist).toHaveBeenCalledTimes(1);
  expect(gamingDraft.pending).toBe(0);
});
it('editing keeps platform/device stable and read-only controls disabled', async () => {
  gamingPresetsPanel.mount();
  await drain();
  fill();
  button('Add to list').fire('click');
  await drain();
  button('Edit').fire('click');
  expect(
    all(host).find((n) => n.attrs.id === 'trafira-game-platform')!.disabled,
  ).toBe(true);
  expect(
    all(host).find((n) => n.attrs.id === 'trafira-game-device')!.disabled,
  ).toBe(true);
  button('Cancel editing').fire('click');
  gamingPresetsPanel.mount(false);
  expect(button('Delete').disabled).toBe(true);
  expect(button('Add to list').disabled).toBe(true);
});
it('allows immediate draft editing while the saved switch is off', async () => {
  gamingPresetsPanel.mount();
  await drain();
  fill();
  expect(button('Add to list').disabled).toBe(false);
  expect(requests.map((r) => r.action)).toEqual(['catalog']);
  expect(write).not.toHaveBeenCalled();
});

it('recovers a briefly busy catalog automatically without discarding the draft', async () => {
  vi.useFakeTimers();
  gamingPresetsPanel.mount();
  await drain();
  fill();
  button('Add to list').fire('click');
  await drain();
  fill('epic');
  vi.mocked(executeShellCommand).mockResolvedValueOnce({
    code: 0,
    stdout: JSON.stringify({ success: false, error: 'busy' }),
    stderr: '',
  });
  button('Refresh devices').fire('click');
  await drain();
  expect(text(host)).not.toContain(
    'Another configuration operation is already running.',
  );
  expect(gamingDraft.pending).toBe(1);
  await vi.runAllTimersAsync();
  await drain();
  expect(text(host)).not.toContain(
    'Another configuration operation is already running.',
  );
  expect(gamingDraft.pending).toBe(1);
  expect(
    all(host).find((n) => n.attrs.id === 'trafira-game-platform')!.value,
  ).toBe('epic');
  expect(button('Add to list').disabled).toBe(false);
  expect(write).not.toHaveBeenCalled();
});

it('keeps the error visible when refreshing the catalog fails again', async () => {
  vi.useFakeTimers();
  vi.mocked(executeShellCommand).mockResolvedValue({
    code: 0,
    stdout: JSON.stringify({ success: false, error: 'busy' }),
    stderr: '',
  });
  gamingPresetsPanel.mount();
  await drain();
  await vi.runAllTimersAsync();
  button('Refresh devices').fire('click');
  await drain();
  await vi.runAllTimersAsync();
  expect(text(host)).toContain(
    'Another configuration operation is already running.',
  );
  expect(write).not.toHaveBeenCalled();
});

it('editing an existing preset preserves its before-device priority and sends replacement once', async () => {
  const owner = 'game_steam_30323a30303a30303a30303a30303a30314062722d6c616e';
  saved.splice(1, 0, {
    '.name': owner + '_store',
    '.type': 'section',
    preset_owner: owner,
    preset_platform: 'steam',
    source_ip_cidr: ['192.0.2.5'],
    outbound_detour_section: 'vpn',
  });
  gamingPresetsPanel.mount();
  await drain();
  button('Edit').fire('click');
  const priority = all(host).find(
    (n) => n.attrs.id === 'trafira-game-priority',
  )!;
  expect(priority.value).toBe('before-device-routes');
  select('trafira-game-proxy', 'vpn');
  button('Update in list').fire('click');
  await drain();
  const planned = requests.find((r) => r.action === 'plan')!;
  expect(planned.operations).toEqual([
    expect.objectContaining({
      preset: 'steam',
      placement: 'before-device-routes',
    }),
  ]);
  expect(write).not.toHaveBeenCalled();
});

it.each(['success', 'failure'])(
  'loads choices after native Save rerenders the form while still busy (%s)',
  async (outcome) => {
    gamingPresetsPanel.mount();
    await drain();
    expect(requests.filter((r) => r.action === 'catalog')).toHaveLength(1);
    const save = gamingDraft.save(async () => {
      // form.Map.save() renders the replacement host before its promise resolves.
      gamingPresetsPanel.unmount();
      host = new Node('div');
      gamingPresetsPanel.mount();
      expect(requests.filter((r) => r.action === 'catalog')).toHaveLength(1);
      expect(
        all(host).find((n) => n.attrs.id === 'trafira-game-platform')!.disabled,
      ).toBe(true);
      if (outcome === 'failure') throw Error('offline');
    });
    if (outcome === 'failure') await expect(save).rejects.toThrow('offline');
    else await save;
    await drain();
    expect(requests.filter((r) => r.action === 'catalog')).toHaveLength(2);
    for (const [id, label] of [
      ['platform', 'Steam'],
      ['device', 'PC'],
      ['proxy', 'My VPN'],
    ]) {
      const input = all(host).find((n) => n.attrs.id === 'trafira-game-' + id)!;
      expect(input.disabled).toBe(false);
      expect(text(input)).toContain(label);
    }
    gamingPresetsPanel.mount();
    await drain();
    expect(requests.filter((r) => r.action === 'catalog')).toHaveLength(2);
    fill();
    expect(button('Add to list').disabled).toBe(false);
  },
);

it('does not load a disposed replacement host or repeat catalog loads on idle updates', async () => {
  gamingPresetsPanel.mount();
  await drain();
  let obsolete!: Node;
  await gamingDraft.save(async () => {
    host = new Node('div');
    gamingPresetsPanel.mount();
    obsolete = host;
    host = new Node('div');
    gamingPresetsPanel.mount();
  });
  await drain();
  expect(requests.filter((r) => r.action === 'catalog')).toHaveLength(2);
  expect(
    all(obsolete).find((n) => n.attrs.id === 'trafira-game-platform')!.children,
  ).toHaveLength(0);
  expect(
    text(all(host).find((n) => n.attrs.id === 'trafira-game-platform')!),
  ).toContain('Steam');
  gamingDraft.reset();
  gamingPresetsPanel.mount();
  await drain();
  expect(requests.filter((r) => r.action === 'catalog')).toHaveLength(2);
});
it('allows one explicit retry after catalog failure without an automatic retry loop', async () => {
  vi.mocked(executeShellCommand).mockRejectedValueOnce(Error('offline'));
  gamingPresetsPanel.mount();
  await drain();
  expect(vi.mocked(executeShellCommand)).toHaveBeenCalledTimes(1);
  expect(text(host)).toContain('The operation failed.');
  expect(button('Refresh devices').disabled).toBe(false);
  gamingPresetsPanel.mount();
  await drain();
  expect(vi.mocked(executeShellCommand)).toHaveBeenCalledTimes(1);
  button('Refresh devices').fire('click');
  await drain();
  expect(vi.mocked(executeShellCommand)).toHaveBeenCalledTimes(2);
  fill();
  expect(button('Add to list').disabled).toBe(false);
});

it('waits for a long runtime apply and restores the catalog without a page reload', async () => {
  vi.useFakeTimers();
  const call = vi.mocked(executeShellCommand);
  const normal = call.getMockImplementation()!;
  let applying = true;
  call.mockImplementation(async (options) => applying
    ? { code: 0, stdout: JSON.stringify({ success: false, error: 'busy' }), stderr: '' }
    : normal(options));
  gamingPresetsPanel.mount();
  await vi.advanceTimersByTimeAsync(4000);
  expect(text(host)).not.toContain('Another configuration operation is already running.');
  expect(text(host)).toContain('Waiting for configuration changes to finish');
  applying = false;
  await vi.advanceTimersByTimeAsync(6000);
  await drain();
  expect(text(host)).not.toContain('Waiting for configuration changes to finish');
  fill();
  expect(button('Add to list').disabled).toBe(false);
});
