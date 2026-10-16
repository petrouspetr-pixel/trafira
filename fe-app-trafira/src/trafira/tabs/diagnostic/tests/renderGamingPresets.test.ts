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
