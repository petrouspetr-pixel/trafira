import { afterEach, expect, it, vi } from 'vitest';
import type { store as Store } from '../../../services/store.service';
import type { Trafira } from '../../../types';
let store: typeof Store;

const mocks = vi.hoisted(() => ({
  cache: vi.fn(),
  start: vi.fn(),
  wait: vi.fn(),
  toast: vi.fn(),
  ack: vi.fn(async () => ({ success: true })),
  systemInfo: vi.fn(),
  runtime: vi.fn(async () => undefined),
  runtimeListener: undefined as undefined | ((state: unknown) => void),
  activeStore: undefined as typeof Store | undefined,
  panel: undefined as undefined | { mount(): unknown; unmount(): void },
}));
vi.mock('../../../../helpers', () => ({
  onMount: async () => undefined,
  preserveScrollForPage: (render: () => void) => render(),
}));
vi.mock('../../../../helpers/showToast', () => ({ showToast: mocks.toast }));
vi.mock('../../../helpers/panelLifecycle', () => ({
  watchPanel: (_id: string, panel: { mount(): unknown; unmount(): void }) => {
    mocks.panel = panel;
    void panel.mount();
  },
}));
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
    uiActionAck: mocks.ack,
  },
}));
vi.mock('../../../services', async () => ({
  get store() {
    return mocks.activeStore;
  },
  logger: { debug() {}, error() {} },
  markUiActionOwned() {},
  setLocalComponentAction() {},
  shouldNotifyOwnedUiAction: () => true,
}));
vi.mock('../../../services/systemInfo.service', () => ({
  ensureSystemInfo: mocks.systemInfo,
}));
vi.mock('../../../services/runtimeUiState.service', () => ({
  getCachedRuntimeUiState: () => undefined,
  refreshRuntimeUiState: mocks.runtime,
  subscribeRuntimeUiState: (listener: (state: unknown) => void) => {
    mocks.runtimeListener = listener;
    return () => {
      mocks.runtimeListener = undefined;
    };
  },
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
  loading?: boolean;
  disabled?: boolean;
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
  mocks.panel?.unmount();
  store.set({ tabService: { current: 'dashboard', all: [] } });
  store.reset();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  vi.resetModules();
  mocks.ack.mockResolvedValue({ success: true });
  mocks.runtime.mockResolvedValue(undefined);
  mocks.systemInfo.mockReset();
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

async function mountComponents(installed = true) {
  store = (await import('../../../services/store.service')).store;
  mocks.activeStore = store;
  const container = {
    children: [] as ElementView[],
    replaceChildren(...children: ElementView[]) {
      this.children = children;
    },
  };
  vi.stubGlobal('_', (text: string) => text);
  vi.stubGlobal('window', { addEventListener() {}, dispatchEvent() {} });
  vi.stubGlobal('CustomEvent', class {});
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
    ) => ({ tag, attributes, children, querySelectorAll: () => [] }),
  );
  store.set({
    tabService: { current: 'updates', all: [] },
    diagnosticsSystemInfo: {
      ...store.get().diagnosticsSystemInfo,
      loaded: true,
      loading: false,
      byedpi_installed: installed ? 1 : 0,
      byedpi_version: installed ? '1.0.0' : 'not installed',
    },
  });
  const { initController } = await import('../initController');
  await initController();
  await flush();
  const card = () =>
    find(
      container,
      (node) =>
        node.attributes?.class === 'fkp_updates-page__component' &&
        Boolean(find(node, (child) => child.children === 'ByeDPI')),
    )!;
  const button = (text: string) => find(card(), (node) => node.text === text)!;
  const version = () =>
    find(
      card(),
      (node) =>
        node.attributes?.class ===
        'fkp_updates-page__component__header-version',
    )!.children;
  return { container, card, button, version };
}

it('loads installed versions while unrelated mount requests remain pending', async () => {
  mocks.cache.mockReturnValue(new Promise(() => {}));
  mocks.runtime.mockReturnValue(new Promise(() => {}));
  mocks.systemInfo.mockImplementation(() => {
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        loaded: true,
        loading: false,
        byedpi_version: '2.0.0',
      },
    });
  });
  const view = await mountComponents();
  expect(view.version()).toBe('2.0.0');
  mocks.systemInfo.mockReset();
});

it.each(['install', 'remove'] as const)(
  'keeps %s visibly pending when runtime capabilities change before completion',
  async (action) => {
    mocks.cache.mockResolvedValue({
      success: true,
      data: { enabled: false, results: [] },
    });
    mocks.start.mockResolvedValue({ success: true, data: { job_id: action } });
    mocks.wait.mockReturnValue(new Promise(() => {}));
    const view = await mountComponents(action === 'remove');
    view.button(action === 'remove' ? 'Remove' : 'Install').onClick!();
    await flush();
    store.set({
      diagnosticsSystemInfo: {
        ...store.get().diagnosticsSystemInfo,
        byedpi_installed: action === 'install' ? 1 : 0,
        byedpi_version: 'not installed',
      },
    });
    expect(view.version()).toBe(
      action === 'remove' ? 'Removing…' : 'Installing…',
    );
    expect(
      view.button(action === 'remove' ? 'Remove' : 'Install')?.loading,
    ).toBe(true);
  },
);

it.each([
  ['zapret', 'Zapret'],
  ['zapret2', 'Zapret2'],
  ['byedpi', 'ByeDPI'],
] as const)(
  'does not claim %s is absent when capabilities confirm installation before the version probe',
  async (component, title) => {
    mocks.cache.mockResolvedValue({
      success: true,
      data: { enabled: false, results: [] },
    });
    const view = await mountComponents();
    vi.stubGlobal('_', (text: string) =>
      text === 'unknown'
        ? 'неизвестна'
        : text === 'Not installed'
          ? 'Не установлен'
          : text,
    );
    for (const version of ['not installed', '']) {
      store.set({
        diagnosticsSystemInfo: {
          ...store.get().diagnosticsSystemInfo,
          [`${component}_installed`]: 1,
          [`${component}_version`]: version,
        },
      });
      const card = find(
        view.container,
        (node) =>
          node.attributes?.class === 'fkp_updates-page__component' &&
          Boolean(find(node, (child) => child.children === title)),
      )!;
      expect(
        find(
          card,
          (node) =>
            node.attributes?.class ===
            'fkp_updates-page__component__header-version',
        )!.children,
      ).toBe('неизвестна');
    }
  },
);

it('unlocks reinstall immediately after removal even while acknowledgement is pending', async () => {
  mocks.cache.mockResolvedValue({
    success: true,
    data: { enabled: false, results: [] },
  });
  mocks.start.mockResolvedValue({ success: true, data: { job_id: 'remove' } });
  mocks.wait.mockResolvedValue({
    success: true,
    data: { success: true, component: 'byedpi', action: 'remove' },
  });
  mocks.ack.mockReturnValue(new Promise(() => {}));
  const view = await mountComponents();
  view.button('Remove').onClick!();
  await flush();
  expect(view.version()).toBe('Not installed');
  expect(view.button('Install')?.disabled).toBe(false);
  expect(store.get().updatesActions.byedpiRemove.loading).toBe(false);
});

it('applies a terminal runtime result without waiting for the original job poll', async () => {
  mocks.cache.mockResolvedValue({
    success: true,
    data: { enabled: false, results: [] },
  });
  mocks.start.mockResolvedValue({ success: true, data: { job_id: 'install' } });
  const wait = deferred<unknown>();
  mocks.wait.mockReturnValue(wait.promise);
  const view = await mountComponents(false);
  view.button('Install').onClick!();
  await flush();
  const result = {
    success: true,
    running: false,
    job_id: 'install',
    component: 'byedpi',
    action: 'install',
    current_version: '2.0.0',
  };
  mocks.runtimeListener!({ actions: { component: [result] } });
  await flush();
  expect(view.version()).toBe('2.0.0');
  expect(store.get().updatesActions.byedpiInstall.loading).toBe(false);
  // A late duplicate from the original poll must not unlock a newer action.
  mocks.start.mockResolvedValue({ success: true, data: { job_id: 'remove' } });
  mocks.wait.mockReturnValue(new Promise(() => {}));
  view.button('Remove').onClick!();
  await flush();
  wait.resolve({ success: true, data: result });
  await flush();
  expect(store.get().updatesActions.byedpiRemove.loading).toBe(true);
  expect(view.version()).toBe('Removing…');
});

it('restores pending progress after leaving and remounting the component panel', async () => {
  mocks.cache.mockResolvedValue({
    success: true,
    data: { enabled: false, results: [] },
  });
  mocks.start.mockResolvedValue({ success: true, data: { job_id: 'install' } });
  const wait = deferred<unknown>();
  mocks.wait.mockReturnValue(wait.promise);
  const view = await mountComponents(false);
  view.button('Install').onClick!();
  await flush();
  mocks.panel!.unmount();
  view.container.replaceChildren();
  await mocks.panel!.mount();
  expect(view.version()).toBe('Installing…');
  wait.resolve({
    success: true,
    data: {
      success: true,
      component: 'byedpi',
      action: 'install',
      current_version: '3.0.0',
    },
  });
  await flush();
  expect(view.version()).toBe('3.0.0');
  expect(view.button('Remove').disabled).toBe(false);
});

it('unlocks retry after an installation error without claiming success', async () => {
  mocks.cache.mockResolvedValue({
    success: true,
    data: { enabled: false, results: [] },
  });
  mocks.start.mockResolvedValue({ success: true, data: { job_id: 'install' } });
  mocks.wait.mockResolvedValue({
    success: true,
    data: {
      success: false,
      component: 'byedpi',
      action: 'install',
      message: 'disk full',
    },
  });
  const view = await mountComponents(false);
  view.button('Install').onClick!();
  await flush();
  expect(view.version()).toBe('Not installed');
  expect(view.button('Install').disabled).toBe(false);
  expect(
    find(
      view.card(),
      (node) => node.children === 'Latest version is installed',
    ),
  ).toBeUndefined();
  expect(mocks.toast).toHaveBeenCalledWith(
    expect.stringContaining('disk full'),
    'error',
  );
});

async function emitRuntimeState(
  byedpiInstalled: 0 | 1,
  componentActions: Trafira.ComponentActionResult[],
) {
  const state: Trafira.UiState = {
    service: {
      trafira: { running: 0, enabled: 0, status: 'stopped', dns_configured: 0 },
      sing_box: { running: 0, enabled: 0, status: 'stopped' },
    },
    capabilities: {
      sing_box_extended: 0,
      sing_box_tiny: 0,
      sing_box_compressed: 0,
      sing_box_tailscale: 1,
      zapret_installed: 0,
      zapret2_installed: 0,
      byedpi_installed: byedpiInstalled,
      server_inbounds_enabled_count: 0,
    },
    actions: {
      component: componentActions,
      service: [],
      subscription: [],
      latency: [],
    },
  };
  const { applyUiStateToStore } = await import(
    '../../../services/uiState.service'
  );
  applyUiStateToStore(state);
  mocks.runtimeListener!(state);
  await flush();
}

it.each(['install', 'remove'] as const)(
  'keeps the confirmed %s result when a delayed runtime response predates completion',
  async (action) => {
    mocks.cache.mockResolvedValue({
      success: true,
      data: { enabled: false, results: [] },
    });
    mocks.start.mockResolvedValue({ success: true, data: { job_id: action } });
    mocks.wait.mockResolvedValue({
      success: true,
      data: {
        success: true,
        component: 'byedpi',
        action,
        current_version: '3.0.0',
      },
    });
    const view = await mountComponents(action === 'remove');
    view.button(action === 'remove' ? 'Remove' : 'Install').onClick!();
    await flush();
    mocks.wait.mockReturnValue(new Promise(() => {}));
    await emitRuntimeState(action === 'remove' ? 1 : 0, [
      {
        success: true,
        running: true,
        job_id: action,
        component: 'byedpi',
        action,
        message: '',
        current_version: '',
        latest_version: '',
        changed: false,
      },
    ]);
    expect(view.version()).toBe(
      action === 'remove' ? 'Not installed' : '3.0.0',
    );
    expect(store.get().updatesActions.byedpiInstall.loading).toBe(false);
    expect(store.get().updatesActions.byedpiRemove.loading).toBe(false);
    expect(store.get().diagnosticsSystemInfo.byedpi_installed).toBe(
      action === 'remove' ? 0 : 1,
    );

    // A genuine later operation from another page becomes authoritative.
    await emitRuntimeState(action === 'remove' ? 0 : 1, [
      {
        success: true,
        running: true,
        job_id: 'foreign-next',
        component: 'byedpi',
        action: action === 'remove' ? 'install' : 'remove',
        message: '',
        current_version: '',
        latest_version: '',
        changed: false,
      },
    ]);
    expect(view.version()).toBe(
      action === 'remove' ? 'Installing…' : 'Removing…',
    );
    await emitRuntimeState(action === 'remove' ? 1 : 0, [
      {
        success: true,
        running: false,
        job_id: 'foreign-next',
        component: 'byedpi',
        action: action === 'remove' ? 'install' : 'remove',
        current_version: '4.0.0',
        message: '',
        latest_version: '4.0.0',
        changed: true,
      },
    ]);
    expect(view.version()).toBe(
      action === 'remove' ? '4.0.0' : 'Not installed',
    );
    expect(
      view.button(action === 'remove' ? 'Remove' : 'Install').disabled,
    ).toBe(false);
  },
);

it.each(['sing_box'] as const)(
  'shows %s update immediately and does not replace it with a late cached result',
  async (component) => {
    store = (await import('../../../services/store.service')).store;
    mocks.activeStore = store;
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
