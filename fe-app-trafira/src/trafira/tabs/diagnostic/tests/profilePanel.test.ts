import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
let ProfilePanelController: typeof import('../profilePanel').ProfilePanelController;
let profileErrorMessage: typeof import('../profilePanel').profileErrorMessage;
const reload = vi.fn();
beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers();
  reload.mockReset();
  vi.stubGlobal('window', { location: { reload } });
  ({ ProfilePanelController, profileErrorMessage } = await import(
    '../profilePanel'
  ));
});

afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('configuration profiles controller', () => {
  it('does not consume a failure when a status response arrives after unmount', async () => {
    const failed = {
      success: false,
      running: false,
      job_id: 'own-profile',
      error: 'candidate_check_failed',
    };
    let finish!: (status: object) => void;
    const call = vi
      .fn()
      .mockResolvedValueOnce({
        success: true,
        running: true,
        job_id: 'own-profile',
      })
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          }),
      )
      .mockResolvedValue(failed);
    const first = new ProfilePanelController(call, vi.fn());
    first.mount();
    await first.submit({ action: 'apply', id: 'profile', digest: 'current' });
    const pending = first.submit({ action: 'status' });
    first.unmount();
    finish(failed);
    await pending;
    await vi.advanceTimersByTimeAsync(2000);
    const render = vi.fn();
    const second = new ProfilePanelController(call, render);
    second.mount();
    await second.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0].error).toBe(
      'The profile cannot be used with the current configuration and components.',
    );
    expect(reload).not.toHaveBeenCalled();
  });
  it('shows an own failure already observed in the background once without erasing a later preview', async () => {
    const failed = {
      success: false,
      running: false,
      job_id: 'own-profile',
      error: 'candidate_check_failed',
    };
    const call = vi
      .fn()
      .mockResolvedValueOnce({
        success: true,
        running: true,
        job_id: 'own-profile',
      })
      .mockResolvedValueOnce(failed)
      .mockResolvedValueOnce(failed)
      .mockResolvedValueOnce({
        success: true,
        applicable: true,
        digest: 'current',
        changes: [],
      })
      .mockResolvedValueOnce(failed);
    const first = new ProfilePanelController(call, vi.fn());
    first.mount();
    await first.submit({ action: 'apply', id: 'profile', digest: 'current' });
    first.unmount();
    await vi.advanceTimersByTimeAsync(2000);
    const render = vi.fn();
    const second = new ProfilePanelController(call, render);
    second.mount();
    await second.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0].error).toBe(
      'The profile cannot be used with the current configuration and components.',
    );
    await second.submit({ action: 'preview', id: 'profile' });
    await second.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0]).toMatchObject({
      error: '',
      preview: { id: 'profile' },
    });
    expect(reload).not.toHaveBeenCalled();
  });
  it('reports an own failed job when a new controller first observes its completion', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({
        success: true,
        running: true,
        job_id: 'own-profile',
      })
      .mockResolvedValueOnce({
        success: false,
        running: false,
        job_id: 'own-profile',
        error: 'candidate_check_failed',
      });
    const first = new ProfilePanelController(call, vi.fn());
    first.mount();
    await first.submit({ action: 'apply', id: 'profile', digest: 'current' });
    first.unmount();
    const render = vi.fn();
    const second = new ProfilePanelController(call, render);
    second.mount();
    await second.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0].error).toBe(
      'The profile cannot be used with the current configuration and components.',
    );
    expect(reload).not.toHaveBeenCalled();
  });
  it('keeps the own apply job across unmount and a new controller instance', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({
        success: true,
        running: true,
        job_id: 'own-profile',
      })
      .mockResolvedValueOnce({
        success: true,
        running: false,
        job_id: 'own-profile',
      });
    const first = new ProfilePanelController(call, vi.fn());
    first.mount();
    await first.submit({ action: 'apply', id: 'profile', digest: 'current' });
    first.unmount();
    const render = vi.fn();
    const second = new ProfilePanelController(call, render);
    second.mount();
    await second.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0].committed).toBe(true);
    expect(reload).toHaveBeenCalledTimes(1);
  });
  it('tracks an accepted apply even if its response arrives after unmount', async () => {
    let finish!: (status: object) => void;
    const call = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finish = resolve;
          }),
      )
      .mockResolvedValueOnce({
        success: true,
        running: false,
        job_id: 'own-profile',
      });
    const render = vi.fn();
    const controller = new ProfilePanelController(call, render);
    controller.mount();
    const pending = controller.submit({
      action: 'apply',
      id: 'profile',
      digest: 'current',
    });
    controller.unmount();
    const rendersBeforeReply = render.mock.calls.length;
    finish({ success: true, running: true, job_id: 'own-profile' });
    await pending;
    await vi.advanceTimersByTimeAsync(2000);
    expect(render).toHaveBeenCalledTimes(rendersBeforeReply);
    expect(call.mock.lastCall?.[0]).toEqual({ action: 'status' });
    expect(reload).toHaveBeenCalledTimes(1);
  });
  it('keeps a failed list visible after the initial idle status check', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({ success: false, error: 'storage_unavailable' })
      .mockResolvedValueOnce({
        success: true,
        running: false,
        recovery_pending: false,
      });
    const render = vi.fn();
    const controller = new ProfilePanelController(call, render);
    controller.mount();
    await controller.submit({ action: 'list' });
    await controller.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0].error).toBe(
      'The profile operation failed.',
    );
  });
  it('ignores an unrelated historical worker failure after reviewing a profile', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({
        success: true,
        applicable: true,
        digest: 'current',
        changes: [],
      })
      .mockResolvedValueOnce({
        success: false,
        running: false,
        job_id: 'old-gaming',
        error: 'activation_failed',
        recovery_pending: false,
      });
    const render = vi.fn();
    const controller = new ProfilePanelController(call, render);
    controller.mount();
    await controller.submit({ action: 'preview', id: 'profile' });
    await controller.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0]).toMatchObject({
      error: '',
      committed: false,
      preview: { id: 'profile' },
    });
  });
  it.each(['apply', 'restore'])(
    'signals a committed %s only after its own successful worker finishes',
    async (action) => {
      const call = vi
        .fn()
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
      const controller = new ProfilePanelController(call, render);
      controller.mount();
      await controller.submit({ action, id: 'profile', digest: 'current' });
      expect(render.mock.lastCall?.[0].committed).toBe(false);
      await controller.submit({ action: 'status' });
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
    'does not claim a commit from a failed, unrelated or incomplete worker response: %j',
    async (terminal) => {
      const call = vi
        .fn()
        .mockResolvedValueOnce({
          success: true,
          running: true,
          job_id: 'expected',
        })
        .mockResolvedValueOnce(terminal);
      const render = vi.fn();
      const controller = new ProfilePanelController(call, render);
      controller.mount();
      await controller.submit({
        action: 'apply',
        id: 'profile',
        digest: 'current',
      });
      await controller.submit({ action: 'status' });
      expect(render.mock.lastCall?.[0].committed).toBe(false);
    },
  );
  it('does not signal a configuration commit when deleting a saved profile', async () => {
    const render = vi.fn();
    const controller = new ProfilePanelController(
      vi.fn().mockResolvedValue({ success: true }),
      render,
    );
    controller.mount();
    await controller.submit({ action: 'remove', id: 'profile' });
    expect(render.mock.lastCall?.[0].committed).toBe(false);
  });
  it('translates profile failures statically and hides unknown error details', () => {
    vi.stubGlobal('_', (value: string) => 'translated:' + value);
    for (const error of [
      'Restore the interrupted operation before continuing.',
      'The profile format is invalid or unsupported.',
      'A maximum of eight profiles can be saved.',
      'The profile operation failed.',
    ])
      expect(profileErrorMessage(error)).toBe('translated:' + error);
    expect(profileErrorMessage('token=private')).toBe(
      'translated:The profile operation failed.',
    );
  });
  it('keeps background operations busy while allowing status polling', async () => {
    const call = vi
      .fn()
      .mockResolvedValueOnce({ success: true, running: true, job_id: 'job-1' })
      .mockResolvedValueOnce({
        success: true,
        running: false,
        job_id: 'job-1',
      });
    const render = vi.fn();
    const controller = new ProfilePanelController(call, render);
    controller.mount();
    await controller.submit({ action: 'apply', id: 'p-1', digest: 'old' });
    expect(render.mock.lastCall?.[0].running).toBe(true);
    await controller.submit({ action: 'remove', id: 'p-1' });
    expect(call).toHaveBeenCalledTimes(1);
    await controller.submit({ action: 'status' });
    expect(render.mock.lastCall?.[0].running).toBe(false);
  });
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
      vi.fn().mockResolvedValue({
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
