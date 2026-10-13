import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import { routeExplanationPanel } from '../renderRouteExplanation';

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(async () => ({
    code: 0,
    stdout: '{"devices":[]}',
  })),
}));

class Element {
  value = '';
  required = false;
  disabled = false;
  readOnly = false;
  hidden = false;
  textContent = '';
  children: Array<Element | string> = [];
  listeners: Record<string, (...args: unknown[]) => void> = {};
  constructor(
    public tag: string,
    public attributes: Record<string, unknown>,
  ) {
    Object.assign(this, attributes);
    // LuCI E serializes boolean attributes; required="false" is still required.
    this.required = attributes.required != null;
  }
  addEventListener(event: string, listener: () => void) {
    this.listeners[event] = listener;
  }
  replaceChildren(...children: Array<Element | string>) {
    this.children = children;
  }
  append(...children: Array<Element | string>) {
    this.children.push(...children);
  }
}
let nodes: Element[];
beforeEach(() => {
  vi.mocked(executeShellCommand).mockResolvedValue({
    code: 0,
    stderr: '',
    stdout: JSON.stringify({
      enabled: true,
      source_interfaces: ['br-lan'],
      devices: [
        {
          name: 'DESKTOP',
          ips: ['192.168.10.234'],
          mac: 'aa:bb:cc:dd:ee:ff',
          interface: 'br-lan',
        },
      ],
    }),
  });
  nodes = [];
  vi.stubGlobal('_', (value: string) => value);
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attributes: Record<string, unknown>,
      children: Array<Element | string> | string = [],
    ) => {
      const node = new Element(tag, attributes);
      node.children = Array.isArray(children) ? children : [children];
      nodes.push(node);
      return node;
    },
  );
  vi.stubGlobal('document', { getElementById: () => new Element('div', {}) });
  routeExplanationPanel.mount();
});
afterEach(() => {
  routeExplanationPanel.unmount();
  vi.unstubAllGlobals();
});

it('requires a visible destination address for the router and restores optional input for a device', () => {
  const source = nodes.find((node) => node.tag === 'select')!;
  const destination = nodes.find(
    (node) => node.attributes.id === 'trafira-route-destination',
  )!;
  expect(destination).toBeDefined();
  expect(destination.required).toBe(false);
  source.value = 'router';
  source.listeners.change();
  expect(destination.required).toBe(true);
  const contains = (node: Element, target: Element): boolean =>
    node.children.some(
      (child) =>
        child === target ||
        (child instanceof Element && contains(child, target)),
    );
  expect(
    nodes.some((node) => node.tag === 'details' && contains(node, destination)),
  ).toBe(false);
  const deviceField = nodes.find(
    (node) =>
      node.tag === 'label' &&
      node.children.some(
        (child) =>
          child instanceof Element &&
          child.children.includes('Device IP address'),
      ),
  )!;
  expect(deviceField.hidden).toBe(true);
  source.value = 'device';
  source.listeners.change();
  expect(destination.required).toBe(false);
  expect(deviceField.hidden).toBe(false);
});

it('explains the configuration check before the first request', () => {
  expect(
    nodes.some(
      (node) =>
        node.tag === 'p' &&
        node.children.some(
          (child) =>
            typeof child === 'string' &&
            child.includes('not test whether the website opens'),
        ),
    ),
  ).toBe(true);
});

it('discovers devices independently of Alice Mode and fills all routing context', async () => {
  await vi.waitFor(() =>
    expect(
      nodes.some(
        (n) =>
          n.tag === 'option' &&
          n.children.some(
            (c) => typeof c === 'string' && c.includes('DESKTOP'),
          ),
      ),
    ).toBe(true),
  );
  expect(executeShellCommand).toHaveBeenCalledWith(
    expect.objectContaining({ args: ['get_known_devices'] }),
  );
  const picker = nodes.find((n) => n.attributes.id === 'trafira-route-device')!;
  picker.value = '0';
  picker.listeners.change();
  expect(
    nodes.find((n) => n.attributes.placeholder === 'Device IP address')!.value,
  ).toBe('192.168.10.234');
  expect(
    nodes.find((n) => n.attributes.placeholder === 'Device MAC (optional)')!
      .value,
  ).toBe('aa:bb:cc:dd:ee:ff');
  expect(
    nodes.find(
      (n) => n.attributes.placeholder === 'Incoming interface (optional)',
    )!.value,
  ).toBe('br-lan');
});

it('includes detected MAC and interface when a known IP is entered manually', async () => {
  await vi.waitFor(() =>
    expect(
      nodes.some(
        (n) =>
          n.tag === 'option' &&
          n.children.some(
            (c) => typeof c === 'string' && c.includes('DESKTOP'),
          ),
      ),
    ).toBe(true),
  );
  nodes.find((n) => n.attributes.placeholder === 'Device IP address')!.value =
    '192.168.10.234';
  nodes.find((n) => n.attributes.placeholder === 'example.com')!.value =
    'ya.ru';
  nodes.find((n) => n.attributes.type === 'number')!.value = '443';
  const protocol = nodes
    .filter((n) => n.tag === 'select')
    .find((n) =>
      n.children.some(
        (c) => c instanceof Element && c.attributes.value === 'tls',
      ),
    )!;
  protocol.value = 'tls';
  nodes
    .find((n) => n.tag === 'form')!
    .listeners.submit({ preventDefault() {} });
  const call = vi
    .mocked(executeShellCommand)
    .mock.calls.filter(([request]) => request.args[0] === 'route_explain')
    .pop()!;
  expect(JSON.parse(call[0].args[1]).source).toEqual({
    kind: 'device',
    ip: '192.168.10.234',
    mac: 'aa:bb:cc:dd:ee:ff',
    interface: 'br-lan',
  });
});
