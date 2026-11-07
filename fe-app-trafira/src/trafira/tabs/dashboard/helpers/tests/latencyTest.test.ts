import { expect, it } from 'vitest';
import {
  getSectionLatencyTarget,
  testAllSectionsLatency,
} from '../latencyTest';
import { Trafira } from '../../../../types';
const section = (
  name: string,
  extra: Partial<Trafira.OutboundGroup> = {},
): Trafira.OutboundGroup => ({
  code: name,
  sectionName: name,
  displayName: name,
  withTagSelect: false,
  outbounds: [
    {
      code: name,
      displayName: name,
      type: 'VLESS',
      latency: 0,
      selected: true,
    },
  ],
  ...extra,
});
it('uses existing group lists, proxy bounds and skips empty or unavailable sections', () => {
  expect(
    getSectionLatencyTarget(
      section('group', { withTagSelect: true, latencyTestCodes: ['a', 'b'] }),
    ),
  ).toEqual({ type: 'proxy_list', tag: '["a","b"]' });
  expect(
    getSectionLatencyTarget(section('vpn', { latencyTestTimeout: '10000' })),
  ).toEqual({ type: 'proxy', tag: 'vpn', timeout: '10000' });
  expect(
    getSectionLatencyTarget(section('empty', { outbounds: [] })),
  ).toBeNull();
  expect(
    getSectionLatencyTarget(
      section('gone', {
        outbounds: [
          {
            code: 'gone',
            displayName: '',
            type: '',
            latency: 0,
            selected: true,
            runtimeAvailable: false,
          },
        ],
      }),
    ),
  ).toBeNull();
});
it('runs eligible sections sequentially, tolerates failures, and stops after leaving the panel', async () => {
  const visited: string[] = [];
  let active = true;
  await testAllSectionsLatency(
    [
      section('first'),
      section('empty', { outbounds: [] }),
      section('second'),
      section('third'),
    ],
    async (item) => {
      visited.push(item.sectionName);
      if (item.sectionName === 'first') throw new Error('offline');
      active = false;
    },
    () => active,
  );
  expect(visited).toEqual(['first', 'second']);
});
