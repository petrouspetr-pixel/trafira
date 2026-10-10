import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRouteExplanationResult } from '../renderRouteExplanation';
import { ExplainReport } from '../routeExplanation';

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
    expect(text(output)).toContain('Matched route: <script>section</script>');
    expect(text(output)).toContain('Current selected node: AWG');
    expect(
      output.every((node) => typeof node === 'string' || node.tag !== 'script'),
    ).toBe(true);
  });
});
