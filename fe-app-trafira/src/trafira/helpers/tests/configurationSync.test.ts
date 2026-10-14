import { afterEach, beforeEach, expect, it, vi } from 'vitest';

type TestNode = {
  tag: string;
  attrs: Record<string, unknown>;
  children: Array<TestNode | string>;
};
let modal: { title: string; content: TestNode };
const hideModal = vi.fn();
function controls(node: TestNode): TestNode[] {
  return [
    ...(node.tag === 'button' ? [node] : []),
    ...node.children.flatMap((child) =>
      typeof child === 'string' ? [] : controls(child),
    ),
  ];
}
const reload = vi.fn();
beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  hideModal.mockReset();
  vi.stubGlobal('document', {
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  });
  vi.stubGlobal(
    'E',
    (
      tag: string,
      attrs: Record<string, unknown>,
      children: Array<TestNode | string> | string = [],
    ) => ({
      tag,
      attrs,
      children: Array.isArray(children) ? children : [children],
    }),
  );
  vi.stubGlobal('ui', {
    hideModal,
    showModal: (title: string, content: TestNode) => {
      modal = { title, content };
    },
  });
  reload.mockReset();
  vi.stubGlobal('_', (value: string) => 'translated:' + value);
  vi.stubGlobal('window', { location: { reload } });
});
afterEach(() => {
  vi.clearAllTimers();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

it('requires an explicit decision before discarding the native form changes', async () => {
  const { confirmConfigurationReplacement } = await import(
    '../configurationSync'
  );
  const cancelled = confirmConfigurationReplacement();
  expect(modal.title).toMatch(/^translated:/);
  expect(JSON.stringify(modal.content)).toContain('unsaved changes');
  (controls(modal.content)[0].attrs.click as () => void)();
  await expect(cancelled).resolves.toBe(false);
  const accepted = confirmConfigurationReplacement();
  (controls(modal.content)[1].attrs.click as () => void)();
  await expect(accepted).resolves.toBe(true);
  expect(hideModal).toHaveBeenCalledTimes(2);
  expect(reload).not.toHaveBeenCalled();
});

it('reloads the native page once even if more than one panel observes the same commit', async () => {
  const { reloadAfterConfigurationCommit } = await import(
    '../configurationSync'
  );
  reloadAfterConfigurationCommit();
  reloadAfterConfigurationCommit();
  expect(reload).toHaveBeenCalledTimes(1);
});

it('keeps watching the requested job through unrelated historical status and reloads only once', async () => {
  const { trackConfigurationCommit, observeConfigurationCommit } = await import(
    '../configurationSync'
  );
  const poll = vi
    .fn()
    .mockResolvedValueOnce({
      success: true,
      running: false,
      job_id: 'historical',
    })
    .mockResolvedValueOnce({ success: true, running: true, job_id: 'own' })
    .mockResolvedValueOnce({ success: true, running: false, job_id: 'own' });
  trackConfigurationCommit('own', poll);
  await vi.advanceTimersByTimeAsync(2000);
  expect(reload).not.toHaveBeenCalled();
  await vi.advanceTimersByTimeAsync(2000);
  expect(reload).not.toHaveBeenCalled();
  await vi.advanceTimersByTimeAsync(2000);
  expect(reload).toHaveBeenCalledTimes(1);
  expect(
    observeConfigurationCommit({
      success: true,
      running: false,
      job_id: 'own',
    }),
  ).toBe(false);
  await vi.advanceTimersByTimeAsync(4000);
  expect(poll).toHaveBeenCalledTimes(3);
  expect(reload).toHaveBeenCalledTimes(1);
});

it.each([
  { success: false, running: false, job_id: 'own', error: 'activation_failed' },
  {
    success: true,
    running: false,
    job_id: 'own',
    rollback_error: 'restore_failed',
  },
  { success: true, running: false, job_id: 'own', recovery_pending: true },
  { running: false, job_id: 'own' },
])(
  'stops without reloading after an unsuccessful terminal status: %j',
  async (status) => {
    const { trackConfigurationCommit } = await import('../configurationSync');
    const poll = vi.fn().mockResolvedValue(status);
    trackConfigurationCommit('own', poll);
    await vi.advanceTimersByTimeAsync(6000);
    expect(poll).toHaveBeenCalledTimes(1);
    expect(reload).not.toHaveBeenCalled();
  },
);

it('retries a status transport failure without overlapping requests', async () => {
  const { trackConfigurationCommit } = await import('../configurationSync');
  let finish!: (status: Record<string, unknown>) => void;
  const poll = vi
    .fn()
    .mockRejectedValueOnce(new Error('unavailable'))
    .mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
  trackConfigurationCommit('own', poll);
  await vi.advanceTimersByTimeAsync(4000);
  expect(poll).toHaveBeenCalledTimes(2);
  await vi.advanceTimersByTimeAsync(6000);
  expect(poll).toHaveBeenCalledTimes(2);
  finish({ success: true, running: false, job_id: 'own' });
  await vi.advanceTimersByTimeAsync(0);
  expect(reload).toHaveBeenCalledTimes(1);
});

it('stops polling without guessing a commit when another terminal job permanently replaces its record', async () => {
  const { trackConfigurationCommit } = await import('../configurationSync');
  const poll = vi
    .fn()
    .mockResolvedValue({ success: true, running: false, job_id: 'other' });
  trackConfigurationCommit('own', poll);
  await vi.advanceTimersByTimeAsync(12000);
  expect(poll).toHaveBeenCalledTimes(3);
  expect(reload).not.toHaveBeenCalled();
});

it('does not lose a newer accepted job when an older start response arrives late', async () => {
  const { trackConfigurationCommit } = await import('../configurationSync');
  const poll = vi
    .fn()
    .mockResolvedValue({ success: true, running: false, job_id: 'newer' });
  trackConfigurationCommit('newer', poll);
  trackConfigurationCommit('older', poll);
  await vi.advanceTimersByTimeAsync(2000);
  expect(reload).toHaveBeenCalledTimes(1);
});

it('counts only consecutive mismatches when deciding whether its job record disappeared', async () => {
  const { trackConfigurationCommit } = await import('../configurationSync');
  const other = { success: true, running: false, job_id: 'other' };
  const poll = vi
    .fn()
    .mockResolvedValueOnce(other)
    .mockResolvedValueOnce(other)
    .mockResolvedValueOnce({ success: true, running: true, job_id: 'own' })
    .mockResolvedValueOnce(other)
    .mockResolvedValueOnce(other)
    .mockResolvedValueOnce({ success: true, running: false, job_id: 'own' });
  trackConfigurationCommit('own', poll);
  await vi.advanceTimersByTimeAsync(12000);
  expect(poll).toHaveBeenCalledTimes(6);
  expect(reload).toHaveBeenCalledTimes(1);
});
