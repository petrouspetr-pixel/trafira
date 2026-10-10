import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import {
  confirmConfigurationReplacement,
  observeConfigurationCommit,
  reloadAfterConfigurationCommit,
} from '../../../helpers/configurationSync';
import { gamingPresetsPanel } from '../renderGamingPresets';
vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));
vi.mock('../../../helpers/configurationSync', () => ({
  confirmConfigurationReplacement: vi.fn(() => true),
  reloadAfterConfigurationCommit: vi.fn(),
  observeConfigurationCommit: vi.fn(() => false),
  trackConfigurationCommit: vi.fn(),
  isTrackedConfigurationCommit: vi.fn(() => false),
}));
class Node {
  children: Array<Node | string> = [];
  value = '';
  disabled = false;
  checked = false;
  textContent = '';
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
let running: boolean;
let empty: boolean;
const requests: string[] = [];
const drain = async () => {
  for (let i = 0; i < 15; i++) await Promise.resolve();
};
const button = (label: string) =>
  all(host).find((n) => n.tag === 'button' && text(n).trim() === label)!;
function completeSelection() {
  const selects = all(host).filter((n) => n.tag === 'select');
  for (const [i, value] of [
    'steam',
    '0',
    'vpn',
    'before-device-routes',
  ].entries()) {
    selects[i].value = value;
    selects[i].fire('change');
  }
  const ip = all(host).find(
    (n) => n.tag === 'input' && n.value === '192.0.2.5',
  )!;
  ip.checked = true;
  ip.fire('change');
}
beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  requests.length = 0;
  running = false;
  empty = false;
  host = new Node('div');
  vi.stubGlobal('_', (s: string) => s);
  vi.stubGlobal('document', { getElementById: () => host });
  vi.stubGlobal('window', { setInterval, clearInterval, confirm: () => true });
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
  vi.mocked(executeShellCommand).mockImplementation(async ({ args }) => {
    const r = JSON.parse(args[1]);
    requests.push(r.action);
    const result =
      r.action === 'catalog'
        ? {
            success: true,
            digest: 'd',
            presets: [{ id: 'steam', revision: 1, checked_at: '2026-10-09' }],
            devices: empty
              ? []
              : [
                  {
                    name: 'Console',
                    interface: 'br-lan',
                    mac: '02:00:00:00:00:01',
                    ips: ['192.0.2.5'],
                  },
                ],
            proxies: empty ? [] : [{ id: 'vpn', label: 'My VPN' }],
            owners: [
              { owner: 'game_steam_x', platform: 'steam', edited: false },
            ],
          }
        : r.action === 'preview'
          ? {
              success: true,
              applicable: true,
              routes: [
                {
                  name: 'store',
                  source: ['192.0.2.5/32'],
                  domain: ['store.example'],
                  domain_suffix: [],
                  target: 'vpn',
                },
                { name: 'direct', source: ['192.0.2.5/32'], target: 'direct' },
              ],
              changes: [{ section: 'store', change: 'added' }],
              conflicts: ['existing_device_routes:old-rule'],
              checks: [
                { status: 'indeterminate', missing: ['rule_set:remote'] },
              ],
            }
          : r.action === 'apply'
            ? { success: true, running: true, job_id: 'j-new' }
            : { success: true, running, job_id: 'j-new' };
    return { code: 0, stdout: JSON.stringify(result), stderr: '' };
  });
});
afterEach(() => {
  gamingPresetsPanel.unmount();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
it('requires every selection and shows readable routes with collapsed technical details', async () => {
  gamingPresetsPanel.mount();
  await drain();
  expect(button('Preview gaming rules').disabled).toBe(true);
  expect(text(host)).toContain('Steam');
  completeSelection();
  expect(button('Preview gaming rules').disabled).toBe(false);
  button('Preview gaming rules').fire('click');
  await drain();
  expect(text(host)).toContain('My VPN');
  expect(text(host)).toContain('store.example');
  expect(text(host)).toContain('Other traffic');
  expect(text(host)).toContain('old-rule');
  expect(
    host
      .querySelectorAll('details')
      .some((n) => !n.attrs.open && n.querySelectorAll('pre').length > 0),
  ).toBe(true);
  expect(all(host).filter((n) => n.tag === 'pre')).toHaveLength(1);
});
it('does not poll idle jobs and synchronizes LuCI only after confirmed application finishes', async () => {
  gamingPresetsPanel.mount();
  await drain();
  await vi.advanceTimersByTimeAsync(6000);
  expect(requests.filter((a) => a === 'status')).toHaveLength(1);
  completeSelection();
  button('Preview gaming rules').fire('click');
  await drain();
  vi.mocked(confirmConfigurationReplacement).mockReturnValueOnce(false);
  button('Apply reviewed changes').fire('click');
  await drain();
  expect(requests).not.toContain('apply');
  button('Apply reviewed changes').fire('click');
  await drain();
  expect(reloadAfterConfigurationCommit).not.toHaveBeenCalled();
  vi.mocked(observeConfigurationCommit).mockReturnValueOnce(true);
  await vi.advanceTimersByTimeAsync(2000);
  await drain();
  expect(reloadAfterConfigurationCommit).toHaveBeenCalledTimes(1);
});
it('refreshes after another running job finishes without reloading LuCI', async () => {
  running = true;
  gamingPresetsPanel.mount();
  await drain();
  running = false;
  await vi.advanceTimersByTimeAsync(2000);
  await drain();
  expect(reloadAfterConfigurationCommit).not.toHaveBeenCalled();
  expect(requests).toContain('catalog');
});
it('permits read-only preview but never configuration replacement', async () => {
  gamingPresetsPanel.mount(false);
  await drain();
  completeSelection();
  button('Preview gaming rules').fire('click');
  await drain();
  expect(button('Apply reviewed changes').disabled).toBe(true);
  button('Apply reviewed changes').fire('click');
  expect(requests).not.toContain('apply');
  expect(button('Refresh devices').disabled).toBe(false);
});
it('explains missing known devices and connection rules', async () => {
  empty = true;
  gamingPresetsPanel.mount();
  await drain();
  expect(text(host)).toContain('No known devices');
  expect(text(host)).toContain('No enabled connection');
  expect(button('Preview gaming rules').disabled).toBe(true);
});
it('does not retain detached owner controls after refreshing the catalog', async () => {
  gamingPresetsPanel.mount();
  await drain();
  const detached = button('Keep as ordinary rules');
  button('Refresh devices').fire('click');
  await drain();
  expect(button('Keep as ordinary rules')).not.toBe(detached);
  expect(button('Keep as ordinary rules').disabled).toBe(false);
  expect(detached.disabled).toBe(true);
});
it.each([0, 1, 2, 3])(
  'disables preview again when required selector %i is cleared',
  async (index) => {
    gamingPresetsPanel.mount();
    await drain();
    completeSelection();
    const select = all(host).filter((n) => n.tag === 'select')[index];
    select.value = '';
    select.fire('change');
    expect(button('Preview gaming rules').disabled).toBe(true);
  },
);
