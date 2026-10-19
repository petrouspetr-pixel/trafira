import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { renderSections } from '../renderSections';
import { Trafira } from '../../../../types';

vi.mock('../../../../../helpers', () => ({
  isCopyableProxyLink: () => false,
  svgEl: () => '',
}));
vi.mock('../../../../../icons', () => ({
  renderLoaderCircleIcon24: () => '',
  renderCopyIcon24: () => '',
  renderLinkIcon24: () => '',
  renderInfoIcon24: () => '',
}));
type Node = {
  tag: string;
  attrs: Record<string, unknown>;
  children: Array<Node | string>;
};
function text(node: Node | string): string {
  return typeof node === 'string' ? node : node.children.map(text).join(' ');
}
function cards(node: Node | string): Node[] {
  if (typeof node === 'string') return [];
  return [
    ...(String(node.attrs.class)
      .split(' ')
      .includes('fkp_dashboard-page__outbound-grid__item')
      ? [node]
      : []),
    ...node.children.flatMap(cards),
  ];
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
      children: (Array.isArray(children) ? children : [children]).filter(
        (value) => value != null,
      ),
    }),
  );
});
afterEach(() => vi.unstubAllGlobals());
function render(outbounds: Trafira.Outbound[], choose = vi.fn()) {
  return renderSections({
    loading: false,
    failed: false,
    section: {
      code: 'main-out',
      sectionName: 'main',
      displayName: 'Main',
      withTagSelect: true,
      outbounds,
    },
    onChooseOutbound: choose,
    onCopyOutbound: vi.fn(),
    onShowUrlTestInfo: vi.fn(),
    onShowPriorityInfo: vi.fn(),
    onUpdateSubscription: vi.fn(),
    onTestLatency: vi.fn(),
    latencyFetching: false,
    subscriptionUpdating: false,
  }) as unknown as Node;
}
it('shows the active node name even when its separate card is hidden', () => {
  const root = render([
    {
      code: 'main-urltest',
      displayName: 'Fastest',
      type: 'URLTest',
      selected: true,
      latency: 15,
      activeNode: { code: 'hidden-node', displayName: 'Netherlands' },
    },
  ]);
  expect(text(root)).toContain('Active node: Netherlands');
});
it('highlights the used node without changing the manual selector choice', () => {
  const choose = vi.fn();
  const root = render(
    [
      {
        code: 'main-1',
        displayName: 'Netherlands',
        type: 'VLESS',
        selected: false,
        active: true,
        latency: 15,
      },
      {
        code: 'main-2',
        displayName: 'Germany',
        type: 'VLESS',
        selected: false,
        active: false,
        latency: 10,
      },
    ],
    choose,
  );
  const nodes = cards(root);
  expect(nodes[0].attrs.class).toContain(
    'fkp_dashboard-page__outbound-grid__item--in-use',
  );
  expect(text(nodes[0])).toContain('Currently used');
  expect(nodes[1].attrs.class).not.toContain('--in-use');
  (nodes[0].attrs.click as () => void)();
  expect(choose).toHaveBeenCalledWith('main', 'main-out', 'main-1');
});

it('distinguishes unavailable, unmeasured and recovered node cards', () => {
  const node: Trafira.Outbound = {
    code: 'node',
    displayName: 'Node',
    latency: 0,
    type: 'VLESS',
    selected: false,
  };
  const failed = cards(render([{ ...node, latencyStatus: 'unavailable' }]))[0];
  expect(text(failed)).toContain('Unavailable');
  expect(text(failed)).not.toContain('No measurement');
  const footer = failed.children.find(
    (c) => typeof c !== 'string' && String(c.attrs.class).endsWith('__footer'),
  ) as Node;
  expect(
    footer.children.some(
      (c) => typeof c !== 'string' && String(c.attrs.class).endsWith('--red'),
    ),
  ).toBe(true);
  expect(text(render([{ ...node, latencyStatus: 'unmeasured' }]))).toContain(
    'No measurement',
  );
  expect(
    text(render([{ ...node, latency: 25, latencyStatus: 'available' }])),
  ).toContain('25ms');
});
