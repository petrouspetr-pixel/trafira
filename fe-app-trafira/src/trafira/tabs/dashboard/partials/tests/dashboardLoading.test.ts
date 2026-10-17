import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { render } from '../../render';
import { renderWidget } from '../renderWidget';

vi.mock('../renderSections', () => ({ renderSections: () => '' }));
vi.mock('../renderAliceDevices', () => ({ renderAliceDevices: () => '' }));

type Node = {
  tag: string;
  attrs: Record<string, unknown>;
  children: Array<Node | string>;
};
function text(node: Node | string): string {
  return typeof node === 'string' ? node : node.children.map(text).join(' ');
}
function find(node: Node, id: string): Node | undefined {
  if (node.attrs.id === id) return node;
  for (const child of node.children) {
    if (typeof child !== 'string') {
      const found = find(child, id);
      if (found) return found;
    }
  }
}
beforeEach(() => {
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attrs = {},
      children: Node | string | Array<Node | string> = [],
    ) => ({
      tag,
      attrs,
      children: Array.isArray(children) ? children : [children],
    }),
  );
});
afterEach(() => vi.unstubAllGlobals());

it('shows traffic cards and labels in the initial dashboard before any network response', () => {
  const root = render() as unknown as Node;
  for (const [id, title] of [
    ['dashboard-widget-traffic', 'Traffic'],
    ['dashboard-widget-traffic-total', 'Traffic Total'],
  ]) {
    const card = find(root, id)!;
    expect(text(card)).toContain(title);
    expect(text(card)).toContain('Uplink');
    expect(text(card)).toContain('Downlink');
    expect(text(card)).toContain('Loading...');
    expect(text(card)).not.toContain('0 B');
  }
});

const items = [
  { key: 'Uplink', value: '12 KB/s' },
  { key: 'Downlink', value: '3 MB/s' },
];
it('keeps a stable labelled card while the first traffic frame is pending', () => {
  const waiting = renderWidget({
    title: 'Traffic',
    loading: true,
    failed: false,
    items,
  }) as unknown as Node;
  const ready = renderWidget({
    title: 'Traffic',
    loading: false,
    failed: false,
    items,
  }) as unknown as Node;
  expect(text(waiting)).toContain('Traffic');
  expect(text(waiting)).toContain('Loading...');
  expect(text(waiting)).not.toContain('12 KB/s');
  expect(waiting.children).toHaveLength(ready.children.length);
  expect(waiting.attrs['aria-busy']).toBe('true');
  expect(text(ready)).toContain('12 KB/s');
  expect(text(ready)).toContain('3 MB/s');
});

it('keeps the traffic title on failure instead of an anonymous replacement box', () => {
  const failed = renderWidget({
    title: 'Traffic',
    loading: false,
    failed: true,
    items,
  }) as unknown as Node;
  expect(text(failed)).toContain('Traffic');
  expect(text(failed)).toContain('Currently unavailable');
  expect(text(failed)).not.toContain('3 MB/s');
});
