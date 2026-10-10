import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import { snapshots } from '../renderSnapshots';
import { render } from '../renderDiagnostic';

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));

interface NodeView {
  tag: string;
  attributes: Record<string, unknown>;
  children: Array<NodeView | string>;
}
function find(
  node: NodeView,
  match: (node: NodeView) => boolean,
): NodeView | undefined {
  if (match(node)) return node;
  for (const child of node.children) {
    if (typeof child === 'string') continue;
    const found = find(child, match);
    if (found) return found;
  }
}
let output: NodeView;
let expanded = false;
beforeEach(() => {
  expanded = false;
  vi.stubGlobal('_', (text: string) => text);
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attributes: Record<string, unknown>,
      children: NodeView[] | string = [],
    ) => ({
      tag,
      attributes,
      children: Array.isArray(children) ? children : [children],
    }),
  );
  vi.stubGlobal('document', {
    getElementById: () => ({
      replaceChildren: (node: NodeView) => {
        output = node;
      },
      querySelector: () => ({ open: expanded }),
    }),
  });
  vi.mocked(executeShellCommand).mockResolvedValue({
    code: 0,
    stdout: JSON.stringify({
      supported: true,
      available: true,
      preparable: true,
      entries: Array.from({ length: 22 }, (_, i) => ({
        tag: `rule-${i}`,
        present: i < 20,
        bytes: 1024,
        mtime: null,
        configured_initial: false,
      })),
      total_bytes: 20480,
      quota_bytes: 8388608,
      job: null,
    }),
    stderr: '',
  });
});
afterEach(() => {
  snapshots.unmount();
  vi.unstubAllGlobals();
});

describe('diagnostics layout', () => {
  it('keeps long management panels outside the short sidebar', () => {
    const page = render() as unknown as NodeView;
    const sidebar = find(
      page,
      (node) => node.attributes.class === 'fkp_diagnostic-page__right-bar',
    )!;
    const lower = find(
      page,
      (node) => node.attributes.class === 'fkp_diagnostic-page__lower',
    )!;
    for (const id of [
      'fkp_diagnostic-page-snapshots',
      'trafira-profiles',
      'trafira-gaming-presets',
    ]) {
      expect(
        find(sidebar, (node) => node.attributes.id === id),
      ).toBeUndefined();
      expect(find(lower, (node) => node.attributes.id === id)).toBeDefined();
    }
  });
  it('collapses the full rule list initially, exposes counts, and preserves expansion on refresh', async () => {
    await snapshots.mount();
    const details = find(output, (node) => node.tag === 'details')!;
    expect(details.attributes).not.toHaveProperty('open');
    expect(find(details, (node) => node.tag === 'summary')?.children).toEqual([
      'Saved rule sets (22)',
    ]);
    expect(
      find(
        output,
        (node) =>
          node.tag === 'p' &&
          String(node.children[0]).includes('Copy present: 20 / 22'),
      ),
    ).toBeDefined();
    expanded = true;
    await snapshots.refresh();
    expect(
      find(output, (node) => node.tag === 'details')?.attributes,
    ).toHaveProperty('open');
  });
});
