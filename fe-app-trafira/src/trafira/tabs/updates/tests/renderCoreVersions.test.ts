import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import { coreVersionsPanel } from '../renderCoreVersions';
import { profilesPanel } from '../../diagnostic/renderProfiles';

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));

class ElementView {
  children: Array<ElementView | string> = [];
  value = '';
  disabled = false;
  checked = false;
  textContent = '';
  htmlFor = '';
  constructor(
    public tag: string,
    public attributes: Record<string, unknown>,
  ) {}
  replaceChildren(...children: Array<ElementView | string>) {
    this.children = children;
  }
  addEventListener() {}
  setAttribute(name: string, value: string) {
    this.attributes[name] = value;
  }
}
function find(
  node: ElementView,
  predicate: (node: ElementView) => boolean,
): ElementView | undefined {
  if (predicate(node)) return node;
  for (const child of node.children) {
    if (typeof child === 'string') continue;
    const found = find(child, predicate);
    if (found) return found;
  }
}
let host: ElementView;
beforeEach(() => {
  vi.mocked(executeShellCommand).mockClear();
  host = new ElementView('div', { id: 'trafira-core-versions' });
  vi.stubGlobal('document', { getElementById: () => host });
  vi.stubGlobal('window', { setInterval: () => 1, clearInterval() {} });
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attrs: Record<string, unknown>,
      children: ElementView[] | string = [],
    ) => {
      // LuCI applies attributes via setAttribute: disabled="false" still disables
      // an HTML option. Preserve that contract to exercise the actual renderer.
      const element = new ElementView(
        tag,
        Object.fromEntries(
          Object.entries(attrs).filter(([, value]) => value != null),
        ),
      );
      element.children = Array.isArray(children) ? children : [children];
      return element;
    },
  );
});
afterEach(() => {
  coreVersionsPanel.unmount();
  profilesPanel.unmount();
  vi.unstubAllGlobals();
});

it('keeps valid saved profiles selectable under LuCI boolean attribute semantics', async () => {
  vi.mocked(executeShellCommand).mockImplementation(async ({ args }) => ({
    code: 0,
    stderr: '',
    stdout: JSON.stringify(
      JSON.parse(args[1]).action === 'list'
        ? {
            success: true,
            entries: [
              { id: 'valid-profile', name: 'Home', invalid: false },
              { id: 'invalid-profile', name: 'Broken', invalid: true },
            ],
          }
        : { success: true, running: false },
    ),
  }));
  profilesPanel.mount();
  await vi.waitFor(() =>
    expect(
      find(host, (node) => node.attributes.value === 'valid-profile'),
    ).toBeDefined(),
  );
  expect(
    find(host, (node) => node.attributes.value === 'valid-profile')!
      .attributes.disabled,
  ).toBeUndefined();
  expect(
    find(host, (node) => node.attributes.value === 'invalid-profile')!
      .attributes.disabled,
  ).toBe(true);
});

it('renders compatible versions as selectable under LuCI boolean attribute semantics', async () => {
  vi.mocked(executeShellCommand).mockImplementation(async ({ args }) => ({
    code: 0,
    stderr: '',
    stdout: JSON.stringify(
      JSON.parse(args[1]).action === 'catalog'
        ? {
            success: true,
            current_version: '1.14.1-extended-2.7.2',
            pin: null,
            cached_at: 100,
            entries: [
              {
                id: 'compatible',
                version: '1.14.0-extended-2.7.1',
                available: true,
                reason: '',
              },
              {
                id: 'wrong',
                version: '1.13.0',
                available: false,
                reason: 'wrong_architecture',
              },
            ],
          }
        : { success: true, running: false, job_id: '' },
    ),
  }));
  coreVersionsPanel.mount();
  await vi.waitFor(() =>
    expect(
      find(
        host,
        (node) =>
          node.tag === 'option' && node.attributes.value === 'compatible',
      ),
    ).toBeDefined(),
  );
  const compatible = find(
    host,
    (node) => node.tag === 'option' && node.attributes.value === 'compatible',
  )!;
  const incompatible = find(
    host,
    (node) => node.tag === 'option' && node.attributes.value === 'wrong',
  )!;
  expect(compatible.attributes).not.toHaveProperty('disabled');
  expect(incompatible.attributes).toHaveProperty('disabled');
  expect(
    find(host, (node) => node.tag === 'select')!.attributes,
  ).toHaveProperty('id', 'trafira-core-version-select');
  expect(
    find(
      host,
      (node) =>
        node.tag === 'label' && node.htmlFor === 'trafira-core-version-select',
    ),
  ).toBeDefined();
});

it('keeps a catalog error visible after the mount status check', async () => {
  vi.mocked(executeShellCommand).mockImplementation(async ({ args }) => ({
    code: 0,
    stderr: '',
    stdout: JSON.stringify(
      JSON.parse(args[1]).action === 'catalog'
        ? {
            success: false,
            error: 'catalog_fetch_failed',
            current_version: '1.14.1',
            pin: null,
            entries: [],
          }
        : { success: true, running: false, job_id: '' },
    ),
  }));
  coreVersionsPanel.mount();
  await vi.waitFor(() =>
    expect(vi.mocked(executeShellCommand)).toHaveBeenCalledTimes(2),
  );
  expect(
    find(host, (node) => node.attributes.role === 'status')!.textContent,
  ).toContain('Could not load available versions');
  expect(find(host, (node) => node.tag === 'select')!.disabled).toBe(true);
});
