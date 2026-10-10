import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
let GamingPresetController: typeof import('../gamingPresetPanel').GamingPresetController;
const reload = vi.fn();
beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  reload.mockReset();
  vi.stubGlobal('window', { location: { reload } });
  ({ GamingPresetController } = await import('../gamingPresetPanel'));
});
afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
const selection = {
  preset: 'steam',
  device_ips: ['192.0.2.5/32'],
  proxy_section: 'vpn',
  placement: 'before-device-routes',
};
describe('gaming preset preview', () => {
  it('reports an own failed preset job after mounting a new controller', async () => {
    const call = vi.fn().mockResolvedValueOnce({ success: true, applicable: true })
      .mockResolvedValueOnce({ success: true, running: true, job_id: 'own-preset' })
      .mockResolvedValueOnce({ success: false, running: false, job_id: 'own-preset', error: 'activation_failed' });
    const first = new GamingPresetController(call, vi.fn());
    first.mount();
    await first.preview(selection, 'current');
    await first.apply();
    first.unmount();
    const render = vi.fn();
    const second = new GamingPresetController(call, render);
    second.mount();
    await second.poll();
    expect(render.mock.lastCall?.[0].error).toBe('activation_failed');
    expect(reload).not.toHaveBeenCalled();
  });
  it('continues an own preset job after switching away and mounting a new controller', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({ success: true, applicable: true })
      .mockResolvedValueOnce({
        success: true,
        running: true,
        job_id: 'own-preset',
      })
      .mockResolvedValueOnce({
        success: true,
        running: false,
        job_id: 'own-preset',
      });
    const first = new GamingPresetController(call, vi.fn());
    first.mount();
    await first.preview(selection, 'current');
    await first.apply();
    first.unmount();
    const render = vi.fn();
    const second = new GamingPresetController(call, render);
    second.mount();
    await second.poll();
    expect(render.mock.lastCall?.[0].committed).toBe(true);
    expect(reload).toHaveBeenCalledTimes(1);
  });
  it('reloads after preset completion while the panel remains unmounted', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({ success: true, applicable: true })
      .mockResolvedValueOnce({
        success: true,
        running: true,
        job_id: 'own-preset',
      })
      .mockResolvedValueOnce({
        success: true,
        running: false,
        job_id: 'own-preset',
      });
    const render = vi.fn();
    const controller = new GamingPresetController(call, render);
    controller.mount();
    await controller.preview(selection, 'current');
    await controller.apply();
    controller.unmount();
    const count = render.mock.calls.length;
    await vi.advanceTimersByTimeAsync(2000);
    expect(render).toHaveBeenCalledTimes(count);
    expect(reload).toHaveBeenCalledTimes(1);
  });
  it.each([
    { selection, action: 'apply' },
    {
      selection: { owner: 'owned', mode: 'delete', confirm: true },
      action: 'remove',
    },
  ])(
    'signals a configuration commit only after its reviewed $action job succeeds',
    async ({ selection: selected, action }) => {
      const call = vi
        .fn()
        .mockResolvedValueOnce({ success: true, applicable: true })
        .mockResolvedValueOnce({
          success: true,
          running: true,
          job_id: 'expected',
        })
        .mockResolvedValueOnce({
          success: true,
          running: false,
          job_id: 'expected',
          recovery_pending: false,
        });
      const render = vi.fn();
      const controller = new GamingPresetController(call, render);
      controller.mount();
      await controller.preview(selected, 'current');
      await controller.apply();
      expect(call.mock.calls[1][0].action).toBe(action);
      expect(render.mock.lastCall?.[0].committed).toBe(false);
      await controller.poll();
      expect(render.mock.lastCall?.[0].committed).toBe(true);
    },
  );
  it.each([
    { success: true, running: false, job_id: 'other' },
    {
      success: false,
      running: false,
      job_id: 'expected',
      error: 'activation_failed',
    },
    {
      success: true,
      running: false,
      job_id: 'expected',
      rollback_error: 'restore_failed',
    },
    {
      success: true,
      running: false,
      job_id: 'expected',
      recovery_pending: true,
    },
    { success: true, job_id: 'expected' },
    { running: false, job_id: 'expected' },
    { success: true, running: false },
  ])(
    'does not claim a commit from a failed, unrelated or incomplete preset worker: %j',
    async (terminal) => {
      const call = vi
        .fn()
        .mockResolvedValueOnce({ success: true, applicable: true })
        .mockResolvedValueOnce({
          success: true,
          running: true,
          job_id: 'expected',
        })
        .mockResolvedValueOnce(terminal);
      const render = vi.fn();
      const controller = new GamingPresetController(call, render);
      controller.mount();
      await controller.preview(selection, 'current');
      await controller.apply();
      await controller.poll();
      expect(render.mock.lastCall?.[0].committed).toBe(false);
    },
  );
  it('does not claim that a discovered shared worker belongs to this preset panel', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({
        success: true,
        running: true,
        job_id: 'shared-profile',
      })
      .mockResolvedValueOnce({
        success: true,
        running: false,
        job_id: 'shared-profile',
      });
    const render = vi.fn();
    const controller = new GamingPresetController(call, render);
    controller.mount();
    await controller.poll();
    await controller.poll();
    expect(render.mock.lastCall?.[0].committed).toBe(false);
  });
  it('keeps a reviewed preview when polling a historical failed profile job', async () => {
    const call = vi.fn(async (request: Record<string, unknown>) =>
      request.action === 'status'
        ? {
            success: false,
            running: false,
            job_id: 'old-profile',
            error: 'candidate_check_failed',
          }
        : { success: true, applicable: true },
    );
    const render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.preview(selection, 'd');
    await c.poll();
    expect(render.mock.lastCall?.[0].preview?.applicable).toBe(true);
    expect(render.mock.lastCall?.[0].error).toBe('');
    await c.apply();
    expect(call.mock.lastCall?.[0].action).toBe('apply');
  });
  it('reports the observed worker failure once without erasing the next preview', async () => {
    const call = vi
      .fn()
      .mockResolvedValue({ success: true, running: true, job_id: 'j-current' });
    const render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.poll();
    const failed = {
      success: false,
      running: false,
      job_id: 'j-current',
      error: 'activation_failed',
    };
    call.mockResolvedValue(failed);
    await c.poll();
    expect(render.mock.lastCall?.[0].error).toBe('activation_failed');
    call.mockResolvedValue({ success: true, applicable: true });
    await c.preview(selection, 'new-digest');
    call.mockResolvedValue(failed);
    await c.poll();
    expect(render.mock.lastCall?.[0].preview?.applicable).toBe(true);
  });
  it('still reports pending recovery on a reconnected page', async () => {
    const call = vi.fn().mockResolvedValue({
      success: false,
      running: false,
      job_id: 'j-old',
      recovery_pending: true,
      rollback_error: 'restore_failed',
    });
    const render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.poll();
    expect(render.mock.lastCall?.[0].error).toBe('rollback_failed');
  });
  it('requires a device and explicit placement and applies only reviewed input', async () => {
    const call = vi.fn().mockResolvedValue({
        success: true,
        applicable: true,
        digest: 'digest',
        patch: { sections: [] },
      }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.preview({ ...selection, device_ips: [] }, 'digest');
    expect(call).not.toHaveBeenCalled();
    await c.preview({ ...selection, placement: '' }, 'digest');
    expect(call).not.toHaveBeenCalled();
    await c.preview(selection, 'digest');
    await c.apply();
    expect(call.mock.lastCall?.[0]).toEqual({
      ...selection,
      action: 'apply',
      expected_digest: 'digest',
    });
  });
  it('invalidates preview on edits and stale conflicts', async () => {
    const call = vi
        .fn()
        .mockResolvedValue({ success: true, applicable: true, digest: 'd' }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.preview(selection, 'd');
    c.invalidate();
    await c.apply();
    expect(call).toHaveBeenCalledTimes(1);
    call.mockResolvedValue({ success: false, error: 'conflict' });
    await c.preview(selection, 'd');
    await c.apply();
    expect(call).toHaveBeenCalledTimes(2);
  });
  it('does not add unselected IPv6 and blocks Alice conflicts', async () => {
    const call = vi
        .fn()
        .mockResolvedValue({ success: false, error: 'alice_bypass' }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.preview(selection, 'd');
    expect(call.mock.lastCall?.[0].device_ips).toEqual(['192.0.2.5/32']);
    await c.apply();
    expect(call).toHaveBeenCalledTimes(1);
  });
  it('reconnects to worker without submitting again and ignores unmounted requests', async () => {
    const call = vi
        .fn()
        .mockResolvedValue({ success: true, running: true, job_id: 'j-1' }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.poll();
    expect(render.mock.lastCall?.[0].running).toBe(true);
    await c.preview(selection, 'd');
    expect(call).toHaveBeenCalledTimes(1);
    c.unmount();
    await c.poll();
    expect(call).toHaveBeenCalledTimes(1);
  });
});
