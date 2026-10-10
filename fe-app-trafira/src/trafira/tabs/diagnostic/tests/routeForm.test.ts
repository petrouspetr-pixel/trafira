import { afterEach, beforeEach, expect, it, vi } from 'vitest';
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
  listeners: Record<string, () => void> = {};
  constructor(
    public tag: string,
    public attributes: Record<string, unknown>,
  ) {
    Object.assign(this, attributes);
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
