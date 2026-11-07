import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { store } from '../../services/store.service';
const h = vi.hoisted(() => ({
  refresh: vi.fn(),
  cached: false,
  streams: new Map<
    string,
    { message: (s: string) => void; error: () => void }
  >(),
  render: vi.fn(),
  start: vi.fn(),
  sections: vi.fn(),
  watchStops: [] as Array<() => void>,
}));
vi.mock('../../../helpers', () => ({
  onMount: () => Promise.resolve(),
  getClashWsUrl: () => 'ws://router',
  preserveScrollForPage: (fn: () => void) => fn(),
  isCopyableProxyLink: () => false,
}));
vi.mock('../../helpers/panelLifecycle', () => ({
  watchPanel: (
    _id: string,
    panel: { mount: () => void; unmount: () => void },
  ) => {
    let active = false;
    const stop = store.subscribe((next) => {
      const visible = next.tabService.current === 'dashboard';
      if (active === visible) return;
      active = visible;
      if (visible) panel.mount();
      else panel.unmount();
    });
    h.watchStops.push(stop);
    return stop;
  },
}));
vi.mock('../../services', () => ({
  store,
  logger: { debug: vi.fn(), error: vi.fn() },
  socket: {
    resetAll: () => h.streams.clear(),
    subscribe: (url: string, message: (s: string) => void, error: () => void) =>
      h.streams.set(url, { message, error }),
  },
  setLocalLatencyAction: vi.fn(),
  setLocalSubscriptionAction: vi.fn(),
  markUiActionOwned: vi.fn(),
  shouldNotifyOwnedUiAction: () => false,
}));
vi.mock('../../services/runtimeUiState.service', () => ({
  getCachedRuntimeUiState: () =>
    h.cached ? { service: { sing_box: { instance_id: 'test' } } } : null,
  refreshRuntimeUiState: () => h.refresh(),
  subscribeRuntimeUiState: () => () => {},
}));
vi.mock('../../methods', () => ({
  CustomTrafiraMethods: {
    getDashboardSections: () => h.sections(),
  },
  TrafiraShellMethods: {
    latencyTestStart: (...args: unknown[]) => h.start(...args),
    waitLatencyTestJob: () => Promise.resolve({ success: true }),
    uiActionAck: () => Promise.resolve(),
    getAliceDevices: () => Promise.resolve({ success: true, data: {} }),
  },
}));
vi.mock('../../fetchers/fetchServicesInfo', () => ({
  fetchServicesInfo: vi.fn(),
}));
vi.mock('./renderFailurePolicies', () => ({
  failurePoliciesPanel: { mount: vi.fn(), unmount: vi.fn() },
}));
vi.mock('./partials', () => ({
  renderWidget: (props: unknown) => props,
  renderSections: () => '',
  renderAliceDevices: () => '',
  renderFlagEmojis: () => '',
  getLatencyTestLabel: () => '',
}));
beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  store.reset();
  h.streams.clear();
  h.render.mockClear();
  h.cached = false;
  h.sections.mockReset().mockResolvedValue({ success: true, data: [] });
  h.start.mockReset().mockImplementation(() =>
    Promise.resolve({
      success: true,
      data: { job_id: String(h.start.mock.calls.length) },
    }),
  );
  h.refresh.mockReset().mockReturnValue(new Promise(() => {}));
  vi.stubGlobal('E', (tag: string, attrs: unknown, children: unknown) => ({
    tag,
    attrs,
    children,
  }));
  vi.stubGlobal('document', {
    getElementById: () => ({
      replaceChildren: h.render,
      classList: { toggle: vi.fn() },
    }),
  });
});
afterEach(() => {
  store.set({ tabService: { current: 'other', all: [] } });
  h.watchStops.splice(0).forEach((stop) => stop());
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
async function mount() {
  const { initController } = await import('./initController');
  store.set({ tabService: { current: 'dashboard', all: [] } });
  await initController();
  await Promise.resolve();
}
function running() {
  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: false,
      data: {
        singbox: 1,
        trafiraRunning: 1,
        trafiraEnabled: 1,
        trafiraStatus: 'running',
      },
    },
  });
}
it('renders and subscribes while the runtime refresh is pending', async () => {
  await mount();
  expect(h.render).toHaveBeenCalled();
  running();
  expect(h.streams.has('ws://router/connections')).toBe(true);
});
it('keeps measurements across re-entry and ignores an old stream callback', async () => {
  h.cached = true;
  await mount();
  running();
  const previous = h.streams.get('ws://router/connections')!;
  previous.message(
    JSON.stringify({
      connections: [1, 2],
      memory: 1024,
      uploadTotal: 3,
      downloadTotal: 4,
    }),
  );
  store.set({ tabService: { current: 'other', all: [] } });
  store.set({ tabService: { current: 'dashboard', all: [] } });
  expect(store.get().systemInfoWidget.data.connections).toBe(2);
  previous.message(JSON.stringify({ connections: [], memory: 0 }));
  expect(store.get().systemInfoWidget.data.connections).toBe(2);
});
it('ends initial loading if a stream never sends its first frame', async () => {
  h.cached = true;
  await mount();
  running();
  await vi.advanceTimersByTimeAsync(15000);
  expect(store.get().systemInfoWidget.loading).toBe(false);
  expect(store.get().systemInfoWidget.failed).toBe(true);
});

it('wires the common latency button to the existing job action for each applicable section', async () => {
  await mount();
  running();
  await vi.advanceTimersByTimeAsync(0);
  const group = {
    sectionName: 'main',
    code: 'main-out',
    displayName: 'Main',
    withTagSelect: true,
    latencyTestCodes: ['node'],
    outbounds: [
      {
        code: 'node',
        displayName: 'Node',
        type: 'VLESS',
        latency: 0,
        selected: true,
      },
    ],
  };
  store.set({
    sectionsWidget: {
      ...store.get().sectionsWidget,
      loading: false,
      failed: false,
      data: [group, { ...group, sectionName: 'empty', outbounds: [] }],
    },
  });
  const call = h.render.mock.calls
    .slice()
    .reverse()
    .find(
      (args) => args[0]?.children?.children === 'Test latency for all sections',
    );
  expect(call).toBeDefined();
  call![0].children.attrs.click();
  await vi.advanceTimersByTimeAsync(0);
  expect(h.start.mock.calls).toEqual([
    ['proxy_list', 'main', '["node"]', undefined],
  ]);
});
it('preserves successful measurements after a stream failure and recovers on a new frame', async () => {
  await mount();
  running();
  const stream = h.streams.get('ws://router/connections')!;
  stream.message(
    JSON.stringify({
      connections: [1],
      memory: 1024,
      uploadTotal: 3,
      downloadTotal: 4,
    }),
  );
  stream.error();
  expect(store.get().systemInfoWidget).toEqual({
    loading: false,
    failed: true,
    data: { connections: 1, memory: 1024 },
  });
  stream.message(
    JSON.stringify({
      connections: [1, 2],
      memory: 2048,
      uploadTotal: 6,
      downloadTotal: 8,
    }),
  );
  expect(store.get().systemInfoWidget.failed).toBe(false);
  expect(store.get().systemInfoWidget.data.connections).toBe(2);
});

it('ignores a pending sections response from before the service stopped and restarted', async () => {
  let resolveOld!: (value: unknown) => void;
  h.sections
    .mockReturnValueOnce(
      new Promise((resolve) => {
        resolveOld = resolve;
      }),
    )
    .mockResolvedValueOnce({
      success: true,
      data: [
        {
          code: 'current',
          sectionName: 'current',
          displayName: 'Current',
          withTagSelect: false,
          outbounds: [],
        },
      ],
    });
  await mount();
  running();
  store.set({
    servicesInfoWidget: {
      ...store.get().servicesInfoWidget,
      data: { ...store.get().servicesInfoWidget.data, trafiraRunning: 0 },
    },
  });
  running();
  await vi.advanceTimersByTimeAsync(0);
  resolveOld({ success: true, data: [] });
  await vi.advanceTimersByTimeAsync(0);
  expect(
    store.get().sectionsWidget.data.map((section) => section.sectionName),
  ).toEqual(['current']);
});
