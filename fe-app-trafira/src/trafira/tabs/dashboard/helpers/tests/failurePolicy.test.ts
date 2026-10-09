import { expect, it } from 'vitest';
import { failurePolicyRows } from '../failurePolicy';

it('sanitizes public policy state and marks stale reports unknown', () => {
  const rows = failurePolicyRows({
    enabled: true,
    sections: [
      {
        section: 'vpn',
        policy: 'block',
        state: 'blocked',
        age_seconds: 2,
        password: 'private',
      },
      { section: 'old', policy: 'reserve', state: 'reserve', age_seconds: 180 },
      {
        section: 'error',
        policy: 'direct',
        state: 'primary',
        age_seconds: 1,
        monitor_error: true,
      },
    ],
  });
  expect(rows.map((row) => row.state)).toEqual([
    'blocked',
    'unknown',
    'monitor-error',
  ]);
  expect(JSON.stringify(rows)).not.toContain('private');
});
it('hides disabled policies and rejects unknown state labels', () => {
  expect(
    failurePolicyRows({ enabled: false, sections: [{ section: 'x' }] }),
  ).toEqual([]);
  expect(
    failurePolicyRows({
      enabled: true,
      sections: [
        {
          section: 'x',
          policy: 'block',
          state: 'secret error',
          age_seconds: 1,
        },
      ],
    })[0].state,
  ).toBe('unknown');
});
