import { expect, it, vi } from 'vitest';
import { CoreVersionPicker } from '../coreVersionPicker';

const catalog = {
  success: true,
  current_version: '1.14.2',
  cached_at: 100,
  entries: [
    { id: 'older', version: '1.14.1', available: true },
    { id: 'wrong', version: '1.14.2', available: false },
  ],
};
it('selects a downgrade and blocks duplicate installs and changes during the job', async () => {
  const call = vi
    .fn()
    .mockResolvedValueOnce(catalog)
    .mockResolvedValueOnce({ success: true, running: true, job_id: 'j1' });
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  await picker.load();
  picker.select('wrong');
  await picker.install(true);
  expect(call).toHaveBeenCalledTimes(1);
  picker.select('older');
  await picker.install(true);
  await picker.install(true);
  picker.select('wrong');
  expect(call).toHaveBeenCalledTimes(2);
  expect(call.mock.calls[1][0]).toEqual({
    action: 'install',
    candidate_id: 'older',
    expected_current_version: '1.14.2',
    pin: true,
  });
  expect(render.mock.lastCall?.[0].stage).toBe('installing');
  expect(render.mock.lastCall?.[0].selected).toBe('older');
});
it('ignores a catalog arriving after unmount', async () => {
  let finish!: (result: object) => void;
  const call = vi.fn(
    () =>
      new Promise<object>((resolve) => {
        finish = resolve;
      }),
  );
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  const pending = picker.load();
  picker.unmount();
  const count = render.mock.calls.length;
  finish(catalog);
  await pending;
  expect(render).toHaveBeenCalledTimes(count);
});
it('reports a failed install and successful rollback without raw worker output', async () => {
  const call = vi
    .fn()
    .mockResolvedValueOnce(catalog)
    .mockResolvedValueOnce({ success: true, running: true, job_id: 'j1' })
    .mockResolvedValueOnce({
      success: false,
      running: false,
      job_id: 'j1',
      restored: true,
      error: 'secret worker output',
    });
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  await picker.load();
  picker.select('older');
  await picker.install(false);
  await picker.poll();
  expect(call.mock.lastCall?.[0]).toEqual({ action: 'status', job_id: 'j1' });
  const state = render.mock.lastCall?.[0];
  expect(state.stage).toBe('failed');
  expect(state.restored).toBe(true);
  expect(JSON.stringify(state)).not.toContain('secret worker output');
});

it('retains installed and pinned versions when a catalog refresh fails', async () => {
  const call = vi.fn().mockResolvedValue({
    success: false,
    error: 'catalog_fetch_failed',
    current_version: '1.14.1-extended-2.7.2',
    pin: { version: '1.14.0-extended-2.7.1', variant: 'extended' },
    cached_at: 100,
    stale: true,
    entries: [
      {
        id: 'old',
        version: '1.14.0-extended-2.7.1',
        available: false,
        reason: 'stale_catalog',
      },
    ],
  });
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  await picker.load(true);
  expect(render.mock.lastCall?.[0]).toMatchObject({
    stage: 'failed',
    currentVersion: '1.14.1-extended-2.7.2',
    pinnedVersion: '1.14.0-extended-2.7.1',
    cachedAt: 100,
    entries: [
      {
        id: 'old',
        version: '1.14.0-extended-2.7.1',
        available: false,
        reason: 'stale_catalog',
      },
    ],
    error:
      'Could not load available versions. Check the connection and refresh the list.',
  });
});

it('keeps a catalog failure visible when the background worker is idle', async () => {
  const call = vi
    .fn()
    .mockResolvedValueOnce({
      success: false,
      error: 'catalog_fetch_failed',
      entries: [],
      current_version: '1.14.1',
    })
    .mockResolvedValueOnce({ success: true, running: false, job_id: '' });
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  await picker.load();
  await picker.poll();
  expect(render.mock.lastCall?.[0]).toMatchObject({
    stage: 'failed',
    currentVersion: '1.14.1',
    error:
      'Could not load available versions. Check the connection and refresh the list.',
  });
});

it('preserves a selected version during idle status checks', async () => {
  const call = vi
    .fn()
    .mockResolvedValueOnce(catalog)
    .mockResolvedValueOnce({ success: true, running: false, job_id: '' });
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  await picker.load();
  picker.select('older');
  await picker.poll();
  expect(render.mock.lastCall?.[0]).toMatchObject({
    stage: 'selected',
    selected: 'older',
  });
});

it('reports why a successful catalog has no selectable versions', async () => {
  const call = vi.fn().mockResolvedValue({
    ...catalog,
    entries: [],
    unavailable_reason: 'no_available_versions',
  });
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  await picker.load();
  expect(render.mock.lastCall?.[0].unavailableReason).toBe(
    'no_available_versions',
  );
});

it('disables old choices after a transport failure while retaining installed metadata', async () => {
  const call = vi
    .fn()
    .mockResolvedValueOnce({
      ...catalog,
      pin: { version: '1.14.1', variant: 'stable' },
    })
    .mockRejectedValueOnce(new Error('offline'));
  const render = vi.fn();
  const picker = new CoreVersionPicker(call, render);
  picker.mount();
  await picker.load();
  picker.select('older');
  await picker.load(true);
  const state = render.mock.lastCall?.[0];
  expect(state).toMatchObject({
    stage: 'failed',
    selected: '',
    currentVersion: '1.14.2',
    pinnedVersion: '1.14.1',
  });
  expect(
    state.entries.every((entry: { available: boolean }) => !entry.available),
  ).toBe(true);
});
