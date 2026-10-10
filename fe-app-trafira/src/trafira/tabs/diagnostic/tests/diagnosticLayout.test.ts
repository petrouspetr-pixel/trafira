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
function textOf(node: NodeView): string {
  return node.children
    .map((child) => (typeof child === 'string' ? child : textOf(child)))
    .join(' ');
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
      // LuCI passes non-null attributes to setAttribute; false becomes "false".
      attributes: Object.fromEntries(
        Object.entries(attributes)
          .filter(([, value]) => value != null)
          .map(([name, value]) => [
            name,
            typeof value === 'function' ? value : String(value),
          ]),
      ),
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
  it('keeps configuration management outside diagnostics', () => {
    const page = render() as unknown as NodeView;
    const sidebar = find(
      page,
      (node) => node.attributes.class === 'fkp_diagnostic-page__right-bar',
    )!;
    for (const id of [
      'fkp_diagnostic-page-snapshots',
      'trafira-profiles',
      'trafira-gaming-presets',
    ]) {
      expect(
        find(sidebar, (node) => node.attributes.id === id),
      ).toBeUndefined();
      expect(find(page, (node) => node.attributes.id === id)).toBeUndefined();
    }
  });
  function button(label: string) {
    return find(
      output,
      (node) => node.tag === 'button' && node.children[0] === label,
    )!;
  }
  it('allows read-only inventory refresh but disables downloads without write access', async () => {
    await snapshots.mount(false);
    expect(button('Download / update list copies').attributes.disabled).toBe(
      'true',
    );
    expect(button('Refresh status').attributes).not.toHaveProperty('disabled');
    const calls = vi.mocked(executeShellCommand).mock.calls.length;
    await snapshots.prepare();
    expect(executeShellCommand).toHaveBeenCalledTimes(calls);
  });
  it('enables both snapshot buttons while idle under LuCI attribute semantics', async () => {
    await snapshots.mount();
    expect(
      button('Download / update list copies').attributes,
    ).not.toHaveProperty('disabled');
    expect(button('Refresh status').attributes).not.toHaveProperty('disabled');
  });
  it('disables both buttons during start, then enables them after completion', async () => {
    await snapshots.mount();
    let finish!: (value: {
      code: number;
      stdout: string;
      stderr: string;
    }) => void;
    vi.mocked(executeShellCommand).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const pending = snapshots.prepare();
    expect(button('Download / update list copies').attributes).toHaveProperty(
      'disabled',
    );
    expect(button('Refresh status').attributes).toHaveProperty('disabled');
    finish({ code: 0, stdout: JSON.stringify({ success: true }), stderr: '' });
    await pending;
    expect(
      button('Download / update list copies').attributes,
    ).not.toHaveProperty('disabled');
    expect(button('Refresh status').attributes).not.toHaveProperty('disabled');
  });
  it.each([
    { supported: false },
    { available: false },
    { preparable: false },
    { entries: [] },
    { job: { running: true, success: false, message: '' } },
  ])('keeps preparation disabled when report blocks it: %j', async (patch) => {
    const result = await executeShellCommand({
      command: '/usr/bin/trafira',
      args: [],
    });
    vi.mocked(executeShellCommand).mockResolvedValue({
      ...result,
      stdout: JSON.stringify({ ...JSON.parse(result.stdout), ...patch }),
    });
    await snapshots.mount();
    expect(button('Download / update list copies').attributes).toHaveProperty(
      'disabled',
    );
    expect(button('Refresh status').attributes).not.toHaveProperty('disabled');
  });
  it('collapses the full rule list initially, exposes counts, and preserves expansion on refresh', async () => {
    await snapshots.mount();
    const details = find(output, (node) => node.tag === 'details')!;
    expect(details.attributes).not.toHaveProperty('open');
    expect(find(details, (node) => node.tag === 'summary')?.children).toEqual([
      'Show saved lists and storage (22)',
    ]);
    expect(
      find(
        output,
        (node) =>
          node.tag === 'p' &&
          String(node.children[0]).includes('Copies stored on router: 20 / 22'),
      ),
    ).toBeDefined();
    expanded = true;
    await snapshots.refresh();
    expect(
      find(output, (node) => node.tag === 'details')?.attributes,
    ).toHaveProperty('open');
  });
  it.each([
    {
      running: false,
      success: false,
      message: 'Another lists update is already running',
      shown:
        'Another list update is already running. Wait for it to finish, then download the copies again.',
    },
    {
      running: false,
      success: false,
      message: 'Snapshot preparation failed; previous copies preserved',
      shown:
        'Some copies could not be downloaded or saved. Previous copies were preserved for failed lists. Check the internet connection, list-download proxy and router storage.',
    },
    {
      running: false,
      success: false,
      message: 'Snapshot worker exited unexpectedly',
      shown: 'Downloading copies was interrupted. Download the copies again.',
    },
    {
      running: false,
      success: true,
      message: 'Snapshot preparation completed',
      shown:
        'Copies were downloaded and checked. They will be checked again before the next startup.',
    },
  ])('explains the actual download result: $message', async (job) => {
    const result = await executeShellCommand({
      command: '/usr/bin/trafira',
      args: [],
    });
    vi.mocked(executeShellCommand).mockResolvedValue({
      ...result,
      stdout: JSON.stringify({ ...JSON.parse(result.stdout), job }),
    });
    await snapshots.mount();
    expect(textOf(output)).toContain(job.shown);
  });
  it('shows a safe fallback for unknown backend failure details', async () => {
    const result = await executeShellCommand({
      command: '/usr/bin/trafira',
      args: [],
    });
    const rawMessage =
      'Failed https://user:secret@example.org/list?token=secret';
    vi.mocked(executeShellCommand).mockResolvedValue({
      ...result,
      stdout: JSON.stringify({
        ...JSON.parse(result.stdout),
        job: { running: false, success: false, message: rawMessage },
      }),
    });
    await snapshots.mount();
    expect(textOf(output)).not.toContain(rawMessage);
    expect(textOf(output)).toContain(
      'Could not download copies. Check the internet connection, list-download proxy and router storage.',
    );
  });
  it('explains a storage failure when the download could not start', async () => {
    await snapshots.mount();
    vi.mocked(executeShellCommand).mockResolvedValueOnce({
      code: 0,
      stdout: JSON.stringify({
        success: false,
        message: 'Failed to write snapshot job',
      }),
      stderr: '',
    });
    await snapshots.prepare();
    expect(textOf(output)).toContain(
      'Could not save the download task. Check free storage on the router.',
    );
  });
});
