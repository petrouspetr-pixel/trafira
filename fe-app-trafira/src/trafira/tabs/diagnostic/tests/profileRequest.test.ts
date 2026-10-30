import { afterEach, describe, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../../helpers/executeShellCommand';
import { callProfileCommand } from '../profileRequest';

vi.mock('../../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));
afterEach(() => {
  vi.resetAllMocks();
  vi.useRealTimers();
});
describe('profile request failures', () => {
  it('retries a temporary read failure and returns the list', async () => {
    vi.useFakeTimers();
    vi.mocked(executeShellCommand)
      .mockResolvedValueOnce({
        code: 1,
        stdout: '',
        stderr: 'temporary',
        failure: 'rpc',
      })
      .mockResolvedValueOnce({
        code: 0,
        stdout: '{"success":true,"entries":[]}',
        stderr: '',
      });
    const request = expect(
      callProfileCommand({ action: 'list' }),
    ).resolves.toEqual({ success: true, entries: [] });
    await vi.runAllTimersAsync();
    await request;
    expect(executeShellCommand).toHaveBeenCalledTimes(2);
  });
  it('retries busy reads without repeating writes', async () => {
    vi.useFakeTimers();
    vi.mocked(executeShellCommand)
      .mockResolvedValueOnce({
        stdout: '{"success":false,"error":"busy"}',
        stderr: '',
      })
      .mockResolvedValueOnce({
        stdout: '{"success":true,"entries":[]}',
        stderr: '',
      });
    const request = callProfileCommand({ action: 'list' });
    await vi.runAllTimersAsync();
    expect((await request).success).toBe(true);
    vi.mocked(executeShellCommand)
      .mockClear()
      .mockResolvedValue({
        code: 1,
        stdout: '',
        stderr: 'private details',
        failure: 'timeout',
      });
    await expect(
      callProfileCommand({ action: 'apply', id: 'p-test' }),
    ).rejects.toThrow('timeout');
    expect(executeShellCommand).toHaveBeenCalledTimes(1);
  });
  it('preserves a structured error even with a nonzero exit code', async () => {
    vi.mocked(executeShellCommand).mockResolvedValue({
      code: 1,
      stdout: '{"success":false,"error":"storage_unavailable"}',
      stderr: 'private details',
    });
    expect(await callProfileCommand({ action: 'list' })).toEqual({
      success: false,
      error: 'storage_unavailable',
    });
    expect(executeShellCommand).toHaveBeenCalledTimes(1);
  });
  it('never retries permission failures or exposes command output', async () => {
    vi.mocked(executeShellCommand).mockResolvedValue({
      code: 1,
      stdout: '',
      stderr: 'token=secret',
      failure: 'permission_denied',
    });
    await expect(callProfileCommand({ action: 'list' })).rejects.toThrow(
      'permission_denied',
    );
    expect(executeShellCommand).toHaveBeenCalledTimes(1);
  });
});
