import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { renderRouteExplanationResult } from '../renderRouteResult';
import type { ExplainReport } from '../routeExplanation';

interface View {
  tag: string;
  attributes: Record<string, unknown>;
  children: Array<View | string>;
}
let output: Array<View | string>;
const text = (items: Array<View | string>): string =>
  items.map((n) => (typeof n === 'string' ? n : text(n.children))).join(' ');
const nodes = (items = output): View[] =>
  items.flatMap((n) =>
    typeof n === 'string' ? [] : [n, ...nodes(n.children)],
  );
const report = (): ExplainReport => ({
  success: true,
  decision: {
    status: 'matched',
    outbound: 'vpn-out',
    missing: [],
    trace: [
      { index: 0, action: 'sniff', match: 'yes', shadowed: false, missing: [] },
      {
        index: 1,
        action: 'route',
        match: 'no',
        shadowed: false,
        missing: [],
        origin: { section: 'private-internal-name' },
      },
    ],
  },
  connection: { label: 'My VPN', type: 'wireguard' },
  dns_query: {
    performed: true,
    origin: 'trafira_main_dns',
    status: 'resolved',
    addresses: ['203.0.113.1'],
  },
  dns_policy: {
    status: 'indeterminate',
    missing: ['unsupported:internal'],
    trace: [],
  },
  rule_sets: {
    basis: 'saved_snapshots',
    live_verified: false,
    available: 12,
    cached: 8,
    unavailable: 0,
  },
  limitations: [],
});
beforeEach(() => {
  vi.stubGlobal('_', (s: string) => s);
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attributes = {},
      children: Array<View | string> | string = [],
    ) => ({
      tag,
      attributes,
      children: Array.isArray(children) ? children : [children],
    }),
  );
  vi.stubGlobal('document', {
    getElementById: () => ({
      replaceChildren: (...items: Array<View | string>) => {
        output = items;
      },
    }),
  });
});
afterEach(() => vi.unstubAllGlobals());

it('shows the route without technical rule tables or unrelated DNS policy warnings', () => {
  renderRouteExplanationResult(report(), '', false);
  expect(text(output)).toContain('Via My VPN');
  expect(nodes().some((n) => n.tag === 'table')).toBe(false);
  for (const jargon of [
    'sniff',
    'private-internal-name',
    'DNS policy',
    'Technical details',
    'Lists available',
    'Reused from RAM',
    'could not check',
  ])
    expect(text(output)).not.toContain(jargon);
  const addresses = nodes().find((n) => n.tag === 'details')!;
  expect(text(addresses.children)).toContain('203.0.113.1');
  expect(addresses.attributes).not.toHaveProperty('open');
  expect(text(output)).toContain('does not test whether the website opens');
});

it.each(['preparing', 'finishing'] as const)(
  'shows only a simple wait message during %s',
  (phase) => {
    renderRouteExplanationResult(null, '', true, {
      phase,
      total: 12,
      completed: 5,
    });
    expect(text(output)).toContain('Checking routing. Please wait…');
    expect(text(output)).not.toMatch(
      /lists|configuration|addresses|Finishing/i,
    );
    expect(nodes().filter((n) => n.tag === 'p')).toHaveLength(1);
  },
);

it.each(['no_address', 'timeout', 'failed', 'unavailable', 'fakeip'])(
  'a blocked domain needs no address or DNS warning: %s',
  (status) => {
    const r = report();
    r.decision = { status: 'blocked', missing: [], trace: [] };
    r.dns_query = {
      performed: true,
      origin: 'trafira_main_dns',
      status,
      addresses: [],
    };
    renderRouteExplanationResult(r, '', false);
    expect(text(output)).toContain('Connection blocked');
    expect(text(output)).not.toMatch(/Additional settings|DNS|server IP/i);
    expect(nodes().some((n) => n.tag === 'details')).toBe(false);
  },
);

it('explains an incomplete result without presenting it as a connection failure', () => {
  const r = report();
  r.decision = { status: 'indeterminate', missing: ['dns_timeout'], trace: [] };
  r.dns_query = {
    performed: true,
    origin: 'trafira_main_dns',
    status: 'timeout',
    addresses: [],
  };
  renderRouteExplanationResult(r, '', false);
  expect(text(output)).toContain('Cannot determine the route yet');
  expect(text(output).match(/did not respond in time/g)).toHaveLength(1);
  expect(text(output)).not.toContain('See what prevented');
});

it('keeps genuinely different server routes visible', () => {
  const r = report();
  r.decision = {
    status: 'indeterminate',
    missing: ['multiple_destination_routes'],
    trace: [],
  };
  r.destinations = [
    {
      ip: '203.0.113.1',
      decision: { status: 'direct', missing: [], trace: [] },
    },
    {
      ip: '203.0.113.2',
      decision: {
        status: 'matched',
        outbound: 'vpn-out',
        missing: [],
        trace: [],
      },
      connection: { label: 'My VPN', type: 'wireguard' },
    },
  ];
  renderRouteExplanationResult(r, '', false);
  expect(text(output)).toContain('Direct connection');
  expect(text(output)).toContain('Via My VPN');
  expect(nodes().filter((n) => n.tag === 'table')).toHaveLength(1);
});

it('does not repeat the same route for every IP', () => {
  const r = report();
  r.destinations = ['203.0.113.1', '203.0.113.2'].map((ip) => ({
    ip,
    decision: r.decision,
    connection: r.connection,
  }));
  renderRouteExplanationResult(r, '', false);
  expect(nodes().some((n) => n.tag === 'table')).toBe(false);
  expect(text(output)).toContain('203.0.113.2');
});

it('keeps different incomplete reasons visible for each address', () => {
  const r = report();
  r.decision = {
    status: 'indeterminate',
    missing: ['multiple_destination_routes'],
    trace: [],
  };
  r.destinations = [
    {
      ip: '203.0.113.1',
      decision: {
        status: 'indeterminate',
        outbound: null,
        missing: ['dns_timeout'],
        trace: [],
      },
    },
    {
      ip: '203.0.113.2',
      decision: {
        status: 'indeterminate',
        outbound: null,
        missing: ['rule_set:one'],
        trace: [],
      },
    },
  ];
  renderRouteExplanationResult(r, '', false);
  expect(nodes().filter((n) => n.tag === 'table')).toHaveLength(1);
  expect(text(output)).toContain('did not respond in time');
  expect(text(output)).toContain('missing or unreadable');
});

it('keeps errors safe and clears an obsolete result', () => {
  renderRouteExplanationResult(null, 'private_token', false);
  expect(text(output)).not.toContain('private_token');
  renderRouteExplanationResult(null, '', false);
  expect(output).toEqual([]);
});
