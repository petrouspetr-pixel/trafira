import { describe, expect, it, vi } from 'vitest';
import { ProfilePanelController } from '../profilePanel';

describe('configuration profiles controller', () => {
  it('does not submit an apply operation twice', async () => {
    let finish!: (value: object) => void;
    const call = vi.fn().mockImplementation(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const render = vi.fn();
    const controller = new ProfilePanelController(call, render);
    controller.mount();
    const pending = controller.submit({
      action: 'apply',
      id: 'p-1',
      digest: 'old',
    });
    await controller.submit({ action: 'apply', id: 'p-1', digest: 'old' });
    expect(call).toHaveBeenCalledTimes(1);
    finish({ success: true, job_id: 'job-1' });
    await pending;
    expect(render.mock.lastCall?.[0].jobId).toBe('job-1');
  });
  it('ignores stale results after a remount', async () => {
    let finish!: (value: object) => void;
    const render = vi.fn();
    const controller = new ProfilePanelController(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
      render,
    );
    controller.mount();
    const pending = controller.submit({ action: 'list' });
    controller.unmount();
    controller.mount();
    const count = render.mock.calls.length;
    finish({ success: true, entries: [{ id: 'p-old', name: 'Old' }] });
    await pending;
    expect(render).toHaveBeenCalledTimes(count);
  });
  it('reports a conflict without keeping a stale preview', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({
        success: true,
        digest: 'old',
        changes: [
          {
            section: 'proxy',
            option: 'password',
            before: 'secret',
            after: 'secret2',
          },
        ],
      })
      .mockResolvedValueOnce({ success: false, error: 'conflict' });
    const render = vi.fn();
    const controller = new ProfilePanelController(call, render);
    controller.mount();
    await controller.submit({ action: 'preview', id: 'p-1' });
    expect(JSON.stringify(render.mock.calls)).not.toContain('secret');
    await controller.submit({ action: 'apply', id: 'p-1', digest: 'old' });
    expect(render.mock.lastCall?.[0].error).toBe(
      'Configuration changed. Review the differences again.',
    );
    expect(render.mock.lastCall?.[0].preview).toBeNull();
  });
  it('does not hide rollback failure or expose raw messages', async () => {
    const render = vi.fn();
    const controller = new ProfilePanelController(
      vi
        .fn()
        .mockResolvedValue({
          success: false,
          rollback_error: 'restore_service_failed',
          message: 'password=secret',
        }),
      render,
    );
    controller.mount();
    await controller.submit({ action: 'restore', digest: 'old' });
    expect(render.mock.lastCall?.[0].error).toBe(
      'Restoration failed. Check the service before continuing.',
    );
    expect(JSON.stringify(render.mock.calls)).not.toContain('secret');
  });
});
