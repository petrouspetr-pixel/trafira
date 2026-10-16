import { afterEach, expect, it, vi } from 'vitest';
import type { store as Store } from '../../../services/store.service';
let store: typeof Store;

const mocks = vi.hoisted(() => ({
  cache: vi.fn(),
  start: vi.fn(),
  wait: vi.fn(),
  toast: vi.fn(),
}));
vi.mock('../../../../helpers', () => ({
  onMount: async () => undefined,
  preserveScrollForPage: (render: () => void) => render(),
}));
vi.mock('../../../../helpers/showToast', () => ({ showToast: mocks.toast }));
vi.mock('../../../../icons', () => ({
  renderDownloadIcon24() {},
  renderRotateCcwIcon24() {},
  renderSearchIcon24() {},
  renderXIcon24() {},
}));
vi.mock('../../../../partials', () => ({
  renderButton: (props: unknown) => props,
}));
vi.mock('../../../methods', () => ({
  TrafiraShellMethods: {
    componentUpdateCheckCache: mocks.cache,
    componentActionStart: mocks.start,
    waitComponentActionJob: mocks.wait,
    uiActionAck: async () => ({ success: true }),
  },
}));
vi.mock('../../../services', async () => ({
  ...(await import('../../../services/store.service')),
  logger: { debug() {}, error() {} },
  markUiActionOwned() {},
  setLocalComponentAction() {},
  shouldNotifyOwnedUiAction: () => true,
}));
vi.mock('../../../services/systemInfo.service', () => ({
  ensureSystemInfo() {},
}));
vi.mock('../../../services/runtimeUiState.service', () => ({
  getCachedRuntimeUiState: () => undefined,
  refreshRuntimeUiState: async () => undefined,
  subscribeRuntimeUiState: () => () => {},
}));
vi.mock('../renderCoreVersions', () => ({
  coreVersionsPanel: { mount() {}, unmount() {} },
}));

interface ElementView {
  tag?: string;
  attributes?: Record<string, unknown>;
  children?: ElementView[] | string;
  text?: string;
  onClick?: () => void;
}
function find(
  node: ElementView,
  predicate: (node: ElementView) => boolean,
): ElementView | undefined {
  if (predicate(node)) return node;
  for (const child of Array.isArray(node.children) ? node.children : []) {
    if (child && typeof child === 'object') {
      const result = find(child, predicate);
      if (result) return result;
    }
  }
}
const flush = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};
afterEach(() => {
  store.set({ tabService: { current: 'dashboard', all: [] } });
  store.reset();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  vi.resetModules();
});

it.each(['sing_box'] as const)(
  'shows %s update immediately and does not replace it with a late cached result',
  async (component) => {
    store = (await import('../../../services/store.service')).store;
    const container = {
      children: [] as ElementView[],
      replaceChildren(...children: ElementView[]) {
        this.children = children;
      },
    };
    vi.stubGlobal('_', (text: string) => text);
    vi.stubGlobal('window', { addEventListener() {} });
    vi.stubGlobal('document', {
      getElementById: (id: string) =>
        id === 'fkp_updates-components' ? container : null,
      createTextNode: (text: string) => ({ text }),
    });
    vi.stubGlobal(
      'E',
      (
        tag: string,
        attributes: Record<string, unknown>,
        children: ElementView[] = [],
      ) => ({
        tag,
        attributes,
        children,
        querySelectorAll: () => [],
      }),
    );
    let resolveCache!: (value: unknown) => void;
    mocks.cache.mockReturnValue(
      new Promise((resolve) => {
        resolveCache = resolve;
      }),
    );
    mocks.start.mockResolvedValue({
      success: true,
      data: { job_id: 'new-check' },
    });
    mocks.wait.mockResolvedValue({
      success: true,
      data: {
        success: true,
        component,
        action: 'check_update',
        status: 'outdated',
        latest_version: '9.0.0',
      },
    });
    store.set({
      tabService: { current: 'updates', all: [] },
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        loaded: true,
        loading: false,
        zapret2_installed: 1,
        sing_box_version: '1.0.0',
      },
    });
    // Exercise the real controller and store, with deferred backend responses.
    const { initController } = await import('../initController');
    await initController();
    await flush();
    const check = find(container, (node) => node.text === 'Check update');
    expect(check).toBeDefined();
    // Select the component's own check button (card ordering is not relevant).
    const title = {
      trafira: 'Trafira',
      sing_box: 'Sing-box',
      zapret2: 'Zapret2',
    }[component];
    const card = find(
      container,
      (node) =>
        node.attributes?.class === 'fkp_updates-page__component' &&
        Boolean(find(node, (child) => child.children === title)),
    );
    expect(card).toBeDefined();
    find(card!, (node) => node.text === 'Check update')!.onClick!();
    await flush();
    expect(mocks.toast).toHaveBeenCalledWith('Update is available', 'success');
    expect(find(container, (node) => node.text === 'Update')).toBeDefined();
    resolveCache({
      success: true,
      data: {
        enabled: true,
        results: [
          {
            component,
            status: 'latest',
            latest_version: '1.0.0',
          },
        ],
      },
    });
    await flush();
    expect(find(container, (node) => node.text === 'Update')).toBeDefined();
  },
);
