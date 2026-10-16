import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import { routeExplanationPanel } from '../renderRouteExplanation';
vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));
class Element {
  value = '';
  required = false;
  disabled = false;
  hidden = false;
  textContent = '';
  id = '';
  children: Array<Element | string> = [];
  listeners: Record<string, (event?: unknown) => void> = {};
  constructor(
    public tag: string,
    public attributes: Record<string, unknown>,
  ) {
    Object.assign(this, attributes);
    this.required = attributes.required != null;
  }
  addEventListener(event: string, listener: (event?: unknown) => void) {
    this.listeners[event] = listener;
  }
  replaceChildren(...children: Array<Element | string>) {
    this.children = children;
  }
  append(...children: Array<Element | string>) {
    this.children.push(...children);
  }
  setAttribute(key: string, value: string) {
    this.attributes[key] = value;
  }
  toggleAttribute(key: string, value: boolean) {
    if (value) this.attributes[key] = '';
    else delete this.attributes[key];
  }
  querySelectorAll() {
    return [];
  }
}
let nodes: Element[], widgets: Record<string, Dropdown>;
class Dropdown {
  node!: Element;
  constructor(
    public value: string,
    public choices: Record<string, string>,
    public options: Record<string, unknown>,
  ) {
    widgets[options.id as string] = this;
  }
  render() {
    return (this.node = E('div', {
      id: this.options.id as string,
    }) as unknown as Element);
  }
  getValue() {
    return this.value;
  }
  setValue(value: string) {
    this.value = value;
    this.node.listeners['cbi-dropdown-change']?.();
  }
  clearChoices() {
    this.choices = {};
    this.value = '';
  }
  addChoices(values: string[], labels: Record<string, string>) {
    for (const value of values) this.choices[value] = labels[value];
  }
}
const widget = (id: string) => widgets['trafira-route-' + id];
const node = (id: string) => nodes.find((n) => n.id === 'trafira-route-' + id)!;
beforeEach(() => {
  nodes = [];
  widgets = {};
  vi.mocked(executeShellCommand).mockClear();
  vi.mocked(executeShellCommand).mockImplementation(async (request) => ({
    code: 0,
    stderr: '',
    stdout: JSON.stringify(
      request.args[0] === 'get_known_devices'
        ? {
            source_interfaces: ['br-lan'],
            available_interfaces: ['br-lan', 'awg0'],
            devices: [
              {
                name: 'DESKTOP',
                ips: ['192.168.10.234', 'fd00::234'],
                mac: 'aa:bb:cc:dd:ee:ff',
                interface: 'br-lan',
              },
            ],
          }
        : {
            success: true,
            running: false,
            job_id: 'r-a',
            report: {
              success: true,
              decision: {
                status: 'direct',
                trace: [],
                missing: [],
                outbound: 'direct-out',
              },
              limitations: [],
            },
          },
    ),
  }));
  vi.stubGlobal('_', (v: string) => v);
  vi.stubGlobal('ui', { Dropdown });
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attributes: Record<string, unknown> = {},
      children: Array<Element | string> | string = [],
    ) => {
      const n = new Element(tag, attributes);
      n.children = Array.isArray(children) ? children : [children];
      nodes.push(n);
      return n;
    },
  );
  vi.stubGlobal('document', {
    getElementById: (id: string) =>
      nodes.find((n) => n.id === id) || new Element('div', {}),
  });
  routeExplanationPanel.mount();
});
afterEach(() => {
  routeExplanationPanel.unmount();
  vi.unstubAllGlobals();
});
it('uses native LuCI choices and no browser datalists', () => {
  for (const name of ['device', 'mac', 'interface', 'source', 'protocol'])
    expect(widget(name)).toBeDefined();
  for (const name of ['device', 'mac', 'interface'])
    expect(widget(name).options.create).toBe(true);
  expect(nodes.some((n) => n.tag === 'datalist')).toBe(false);
  expect(
    nodes.some((n) => n.tag === 'div' && n.attributes.class === 'cbi-value'),
  ).toBe(true);
});
it('resolves a domain for the router without requiring a manual destination', () => {
  widget('source').setValue('router');
  expect(node('destination').required).toBe(false);
  expect(node('device-row').hidden).toBe(true);
  expect(widget('device').node.attributes.disabled).toBeDefined();
  widget('source').setValue('device');
  expect(node('destination').required).toBe(false);
  expect(node('device-row').hidden).toBe(false);
});
it('keeps port, protocol and destination override under additional settings', () => {
  const advanced = nodes.find((n) => n.id === 'trafira-route-advanced');
  expect(advanced?.tag).toBe('details');
  expect(advanced?.attributes.open).toBeUndefined();
});
it('loads named IPv4 and IPv6 choices and autofills device metadata', async () => {
  await vi.waitFor(() =>
    expect(widget('device').choices['192.168.10.234']).toContain('DESKTOP'),
  );
  expect(widget('device').choices['fd00::234']).toContain('DESKTOP');
  widget('device').setValue('192.168.10.234');
  expect(widget('mac').getValue()).toBe('aa:bb:cc:dd:ee:ff');
  expect(widget('interface').getValue()).toBe('br-lan');
  expect(widget('mac').choices['aa:bb:cc:dd:ee:ff']).toContain('DESKTOP');
  expect(widget('interface').choices['br-lan']).toBeDefined();
  expect(widget('interface').choices['awg0']).toBeDefined();
});
it('allows custom values and preserves explicit overrides in the request', async () => {
  await vi.waitFor(() =>
    expect(widget('device').choices['192.168.10.234']).toBeDefined(),
  );
  widget('device').setValue('192.168.10.234');
  widget('mac').setValue('11:22:33:44:55:66');
  widget('interface').setValue('br-guest');
  nodes.find((n) => n.attributes.placeholder === 'example.com')!.value =
    'ya.ru';
  nodes
    .find((n) => n.tag === 'form')!
    .listeners.submit({ preventDefault() {} });
  const call = vi
    .mocked(executeShellCommand)
    .mock.calls.find(([r]) => r.args[0] === 'route_explain_start')!;
  expect(JSON.parse(call[0].args[1]).source).toEqual({
    kind: 'device',
    ip: '192.168.10.234',
    mac: '11:22:33:44:55:66',
    interface: 'br-guest',
  });
  widget('device').setValue('192.168.10.99');
  expect(widget('mac').getValue()).toBe('');
  expect(widget('interface').getValue()).toBe('');
});

it('refreshes labels without losing current custom choices', async () => {
  await vi.waitFor(() =>
    expect(widget('device').choices['192.168.10.234']).toBeDefined(),
  );
  widget('device').setValue('192.168.10.99');
  widget('mac').setValue('11:22:33:44:55:66');
  widget('interface').setValue('br-guest');
  nodes.find((n) => n.children.includes('Refresh devices'))!.listeners.click();
  await vi.waitFor(() =>
    expect(
      vi
        .mocked(executeShellCommand)
        .mock.calls.filter(([r]) => r.args[0] === 'get_known_devices'),
    ).toHaveLength(2),
  );
  expect(widget('device').getValue()).toBe('192.168.10.99');
  expect(widget('mac').getValue()).toBe('11:22:33:44:55:66');
  expect(widget('interface').getValue()).toBe('br-guest');
});
it('keeps manual selection available if discovery fails', async () => {
  await vi.waitFor(() =>
    expect(widget('device').choices['192.168.10.234']).toBeDefined(),
  );
  vi.mocked(executeShellCommand).mockRejectedValueOnce(new Error('offline'));
  nodes.find((n) => n.children.includes('Refresh devices'))!.listeners.click();
  await vi.waitFor(() =>
    expect(
      nodes.some((n) =>
        n.textContent.includes('Could not load detected devices'),
      ),
    ).toBe(true),
  );
  expect(widget('device').options.create).toBe(true);
});
