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
  const state = render.mock.lastCall?.[0];
  expect(state.stage).toBe('failed');
  expect(state.restored).toBe(true);
  expect(JSON.stringify(state)).not.toContain('secret worker output');
});
