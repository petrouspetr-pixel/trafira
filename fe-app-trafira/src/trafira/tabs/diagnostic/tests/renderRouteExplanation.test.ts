import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRouteExplanationResult } from '../renderRouteExplanation';
import { ExplainReport } from '../routeExplanation';
import { parseRouteExplanationResult } from '../routeExplanation';
import { routerRouteReport } from './routeRouterReport.fixture';

interface NodeView {
  tag: string;
  attributes: Record<string, unknown>;
  children: Array<NodeView | string>;
}
let output: Array<NodeView | string>;
const text = (nodes: Array<NodeView | string>): string =>
  nodes
    .map((node) => (typeof node === 'string' ? node : text(node.children)))
    .join(' ');
beforeEach(() => {
  vi.stubGlobal('_', (value: string) => value);
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attributes: Record<string, unknown>,
      children: Array<NodeView | string> | string = [],
    ) => ({
      tag,
      attributes,
      children: Array.isArray(children) ? children : [children],
    }),
  );
  vi.stubGlobal('document', {
    getElementById: () => ({
      replaceChildren: (...nodes: Array<NodeView | string>) => {
        output = nodes;
      },
    }),
  });
});
afterEach(() => vi.unstubAllGlobals());
describe('route diagnostic output', () => {
  it('renders the full router CLI response with partially available saved lists', () => {
    const report = parseRouteExplanationResult({
      code: 0,
      stdout: JSON.stringify(routerRouteReport),
    });
    expect(() => renderRouteExplanationResult(report, '', false)).not.toThrow();
    expect(text(output)).toContain('could not be determined automatically');
    expect(text(output)).toContain(
      'lists exceed the diagnostic size or time limits',
    );
    expect(text(output)).toContain('DNS policy (A query)');
    expect(text(output)).not.toContain('Could not explain route');
    expect(text(output)).not.toContain('rule_set:');
  });
  it('shows useful grouped hints and saved-copy basis instead of raw internal codes', () => {
    const report: ExplainReport = {
      success: true,
      decision: {
        status: 'indeterminate',
        missing: ['rule_set:one', 'rule_set:two'],
        trace: [],
      },
      dns_policy: {
        status: 'indeterminate',
        missing: ['legacy_router_output_rules'],
        trace: [],
      },
      rule_sets: {
        basis: 'saved_snapshots',
        live_verified: false,
        available: 2,
        unavailable: 0,
      },
      limitations: ['remote_rule_sets_not_exported_by_running_core'],
    };
    renderRouteExplanationResult(report, '', false);
    const result = text(output);
    expect(result).toContain('running sing-box may have newer lists');
    expect(result).toContain('Download or update copies');
    expect(result).toContain('Select a LAN device');
    expect(result).not.toContain('rule_set:');
    expect(result).not.toContain('legacy_router_output_rules');
    expect(result).not.toContain('remote_rule_sets_not_exported');
    expect(result.match(/A required saved list/g)).toHaveLength(1);
    const details = output.find(
      (node) => typeof node !== 'string' && node.tag === 'details',
    ) as NodeView;
    expect(details.attributes).not.toHaveProperty('open');
  });
  it('renders a successful route and current selector as plain text', () => {
    renderRouteExplanationResult(
      {
        success: true,
        decision: {
          status: 'matched',
          outbound: '<script>section</script>',
          missing: [],
          trace: [],
        },
        selector: { tag: 'select', current: 'AWG' },
        limitations: [],
      },
      '',
      false,
    );
    expect(text(output)).toContain('Via <script>section</script>');
    expect(text(output)).toContain('Current selected node: AWG');
    expect(
      output.every((node) => typeof node === 'string' || node.tag !== 'script'),
    ).toBe(true);
  });
  it('keeps rule internals collapsed and shows per-address differences plainly', () => {
    const a = {
      status: 'direct' as const,
      outbound: 'direct-out',
      missing: [],
      trace: [],
    };
    const b = { ...a, status: 'matched' as const, outbound: 'vpn-out' };
    renderRouteExplanationResult(
      {
        success: true,
        decision: {
          status: 'indeterminate',
          missing: ['multiple_destination_routes'],
          trace: [],
        },
        destinations: [
          { ip: '203.0.113.1', decision: a },
          {
            ip: '203.0.113.2',
            decision: b,
            connection: { label: 'AWG', type: 'wireguard' },
          },
        ],
        dns_query: {
          performed: true,
          origin: 'trafira_main_dns',
          status: 'resolved',
          addresses: ['203.0.113.1', '203.0.113.2'],
        },
        limitations: [],
      },
      '',
      false,
    );
    expect(text(output)).toContain('The route depends on the server address');
    expect(text(output)).toContain('Direct connection');
    expect(text(output)).toContain('Via AWG');
    expect(text(output)).toContain(
      'A device using its own DNS may receive different addresses',
    );
    const details = output.find(
      (node) => typeof node !== 'string' && node.tag === 'details',
    ) as NodeView;
    expect(details.children[0]).toMatchObject({
      tag: 'summary',
      children: ['Technical details'],
    });
    expect(details.attributes).not.toHaveProperty('open');
  });
});
