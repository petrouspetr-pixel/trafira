import { afterEach, describe, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../executeShellCommand';

afterEach(() => vi.unstubAllGlobals());

describe('RPC command access routing', () => {
  it.each([
    ['/usr/bin/trafira', ['get_ui_state'], '/usr/bin/trafira-read'],
    ['/usr/bin/trafira', ['clash_api', 'get_proxies'], '/usr/bin/trafira-read'],
    [
      '/usr/bin/trafira-config',
      ['core_action', '{"action":"catalog"}'],
      '/usr/bin/trafira-read',
    ],
    [
      '/usr/bin/trafira-config',
      ['profile_action', '{"action":"preview"}'],
      '/usr/bin/trafira-read',
    ],
    ['/usr/bin/trafira', ['stop'], '/usr/bin/trafira'],
    [
      '/usr/bin/trafira',
      ['clash_api', 'set_group_proxy', 'group', 'node'],
      '/usr/bin/trafira',
    ],
    [
      '/usr/bin/trafira-config',
      ['core_action', '{"action":"install"}'],
      '/usr/bin/trafira-config',
    ],
    [
      '/usr/bin/trafira-config',
      [
        'core_action',
        '{"action":"pin","expected_current_version":"1.14.2","expected_current_variant":"stable"}',
      ],
      '/usr/bin/trafira-config',
    ],
    ['/etc/init.d/trafira', ['enable'], '/etc/init.d/trafira'],
    [
      '/usr/bin/trafira-config',
      ['profile_action', '{"action":"export_begin","id":"home"}'],
      '/usr/bin/trafira-config',
    ],
    [
      '/usr/bin/trafira-config',
      ['profile_action', '{"action":"export_read","id":"transfer","offset":0}'],
      '/usr/bin/trafira-config',
    ],
  ])(
    'routes %s %j using the correct RPC permission',
    async (command, args, target) => {
      const exec = vi
        .fn()
        .mockResolvedValue({ stdout: '{}', stderr: '', code: 0 });
      vi.stubGlobal('fs', { exec });
      const result = await executeShellCommand({ command, args });
      expect(exec).toHaveBeenCalledWith(target, args);
      expect(result.code).toBe(0);
    },
  );
});
