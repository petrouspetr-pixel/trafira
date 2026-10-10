import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../executeShellCommand';
import { logger } from '../../trafira/services/logger.service';

beforeEach(() => {
  vi.stubGlobal('_', (value: string) => value);
  vi.spyOn(console, 'info').mockImplementation(() => {});
});
afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('safe shell transport failure categories', () => {
  it('does not log profile import payloads or arbitrary action arguments', async () => {
    logger.clear();
    vi.stubGlobal('fs', {
      exec: vi.fn().mockResolvedValue({ code: 0, stdout: '{}', stderr: '' }),
    });
    const secret = btoa(
      '{"password":"private-password","private_key":"private-key"}',
    );
    await executeShellCommand({
      command: '/usr/bin/trafira-config',
      args: [
        'profile_action',
        JSON.stringify({ action: 'import_chunk', data: secret }),
      ],
    });
    await executeShellCommand({
      command: '/usr/bin/trafira',
      args: ['unexpected-token=secret', 'payload-secret'],
    });
    expect(logger.getLogs()).toContain(
      '/usr/bin/trafira-config profile_action',
    );
    for (const value of [
      secret,
      'import_chunk',
      'private-password',
      'private-key',
      'payload-secret',
      'unexpected-token=secret',
    ])
      expect(logger.getLogs()).not.toContain(value);
  });
  it.each([
    ['TimeoutError', 'timeout'],
    ['PermissionError', 'permission_denied'],
    ['Error', 'rpc'],
  ])(
    'preserves %s as %s without depending on translated text',
    async (name, failure) => {
      vi.stubGlobal('fs', {
        exec: vi
          .fn()
          .mockRejectedValue(
            Object.assign(new Error('token=secret'), { name }),
          ),
      });
      const result = await executeShellCommand({
        command: '/usr/bin/trafira',
        args: ['route_explain', '{}'],
      });
      expect(result).toMatchObject({ code: 1, failure });
    },
  );
  it('identifies the local deadline separately from a command exit code', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('fs', { exec: vi.fn(() => new Promise(() => {})) });
    const pending = executeShellCommand({
      command: '/usr/bin/trafira',
      args: ['route_explain', '{}'],
      timeout: 100,
    });
    await vi.advanceTimersByTimeAsync(100);
    expect(await pending).toMatchObject({ code: 1, failure: 'timeout' });
  });
  it('retains an ordinary nonzero command result without a transport category', async () => {
    vi.stubGlobal('fs', {
      exec: vi
        .fn()
        .mockResolvedValue({ code: 2, stdout: '', stderr: 'private path' }),
    });
    const result = await executeShellCommand({
      command: '/usr/bin/trafira',
      args: ['route_explain', '{}'],
    });
    expect(result).toEqual({ code: 2, stdout: '', stderr: 'private path' });
  });
});
