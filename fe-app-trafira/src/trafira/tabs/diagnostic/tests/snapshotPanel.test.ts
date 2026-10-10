import { afterEach, describe, expect, it, vi } from 'vitest';
import { SnapshotController, SnapshotReport } from '../snapshotPanel';

const report = (running = false): SnapshotReport => ({
  supported: true,
  available: true,
  preparable: true,
  entries: [],
  total_bytes: 0,
  quota_bytes: 8388608,
  max_file_bytes: 4194304,
  job: running
    ? { running: true, success: false, message: 'Preparing snapshots' }
    : null,
});
afterEach(() => vi.useRealTimers());
describe('saved snapshots controller', () => {
  it('clears a pending start on remount and ignores its obsolete completion', async () => {
    let finishFirst!: (value: { success: boolean }) => void;
    let finishSecond!: (value: { success: boolean }) => void;
    const start = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finishFirst = resolve;
          }),
      )
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            finishSecond = resolve;
          }),
      );
    const render = vi.fn();
    const controller = new SnapshotController(
      vi.fn().mockResolvedValue(report()),
      start,
      render,
    );
    await controller.mount();
    const first = controller.prepare();
    controller.unmount();
    await controller.mount();
    expect(render.mock.lastCall?.[2]).toBe(false);
    const second = controller.prepare();
    finishFirst({ success: true });
    await first;
    await controller.refresh();
    expect(render.mock.lastCall?.[2]).toBe(true);
    await controller.prepare();
    expect(start).toHaveBeenCalledTimes(2);
    finishSecond({ success: true });
    await second;
    expect(render.mock.lastCall?.[2]).toBe(false);
  });
  it('loads once when idle and resumes polling an existing job after mounting', async () => {
    vi.useFakeTimers();
    const read = vi
      .fn()
      .mockResolvedValueOnce(report(true))
      .mockResolvedValue(report());
    const render = vi.fn();
    const controller = new SnapshotController(read, vi.fn(), render);
    await controller.mount();
    await vi.advanceTimersByTimeAsync(3000);
    expect(read).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(30000);
    expect(read).toHaveBeenCalledTimes(2);
  });
  it('reports polling failures and stops after a bounded number of retries', async () => {
    vi.useFakeTimers();
    const read = vi
      .fn()
      .mockResolvedValueOnce(report(true))
      .mockRejectedValue(new Error('offline'));
    const render = vi.fn();
    const controller = new SnapshotController(read, vi.fn(), render);
    await controller.mount();
    await vi.advanceTimersByTimeAsync(30000);
    expect(read).toHaveBeenCalledTimes(4);
    expect(render.mock.lastCall?.[1]).toBe('Could not read snapshot status');
  });
  it('does not hide rejected preparation and stops polling after unmount', async () => {
    vi.useFakeTimers();
    const read = vi.fn().mockResolvedValue(report(true));
    const render = vi.fn();
    const controller = new SnapshotController(
      read,
      vi.fn().mockResolvedValue({ success: false }),
      render,
    );
    await controller.mount();
    await controller.prepare();
    expect(render.mock.lastCall?.[1]).toBe(
      'Could not start snapshot preparation',
    );
    controller.unmount();
    await vi.advanceTimersByTimeAsync(10000);
    expect(read).toHaveBeenCalledTimes(1);
  });
  it('keeps the backend reason when starting a copy download is rejected', async () => {
    const render = vi.fn();
    const controller = new SnapshotController(
      vi.fn().mockResolvedValue(report()),
      vi.fn().mockResolvedValue({
        success: false,
        message: 'Failed to write snapshot job',
      }),
      render,
    );
    await controller.mount();
    await controller.prepare();
    expect(render.mock.lastCall?.[1]).toBe('Failed to write snapshot job');
    expect(render.mock.lastCall?.[2]).toBe(false);
  });
});
