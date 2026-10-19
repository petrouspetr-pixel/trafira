import { describe, expect, it } from 'vitest';
import { LatencyObservations, formatLatency } from '../latencyStatus';
import { ClashAPI } from '../../types';
const snapshot = (delay?: number) => ({
  node: {
    type: 'Direct',
    name: 'node',
    udp: true,
    history:
      delay === undefined ? [] : [{ time: '2026-10-19T10:00:00Z', delay }],
  },
});
describe('latency availability evidence', () => {
  it('does not call a never-tested node unavailable', () => {
    expect(
      new LatencyObservations().update('core-1/config', snapshot()).get('node'),
    ).toBe('unmeasured');
  });
  it('tracks a successful result disappearing within the same core/config', () => {
    const state = new LatencyObservations();
    expect(state.update('core-1/config', snapshot(20)).get('node')).toBe(
      'available',
    );
    expect(state.update('core-1/config', snapshot()).get('node')).toBe(
      'unavailable',
    );
    expect(state.update('core-1/config', snapshot()).get('node')).toBe(
      'unavailable',
    );
    expect(state.update('core-1/config', snapshot(30)).get('node')).toBe(
      'available',
    );
  });
  it.each(['core-2/config', 'core-1/new-config', ''])(
    'forgets earlier evidence for changed or unknown scope %s',
    (scope) => {
      const state = new LatencyObservations();
      state.update('core-1/config', snapshot(20));
      expect(state.update(scope, snapshot()).get('node')).toBe('unmeasured');
    },
  );
  it('does not infer failure without a runtime identity', () => {
    const state = new LatencyObservations();
    state.update('', snapshot(20));
    expect(state.update('', snapshot()).get('node')).toBe('unmeasured');
  });
  it('prunes removed nodes and handles an explicit zero delay failure', () => {
    const state = new LatencyObservations();
    state.update('core', snapshot(20));
    state.update('core', {});
    expect(state.update('core', snapshot()).get('node')).toBe('unmeasured');
    expect(state.update('core', snapshot(0)).get('node')).toBe('unavailable');
  });
  it('does not treat malformed history as an observed failure', () => {
    const state = new LatencyObservations();
    state.update('core', snapshot(20));
    expect(
      state
        .update('core', {
          node: { ...snapshot().node, history: null },
        } as unknown as ClashAPI.Proxies['proxies'])
        .get('node'),
    ).toBe('unmeasured');
  });
  it('distinguishes the label for a failed check from a missing check', () => {
    expect(formatLatency(0, 'unavailable')).toBe('Unavailable');
    expect(formatLatency(0, 'unmeasured')).toBe('No measurement');
    expect(formatLatency(30, 'available')).toBe('30ms');
  });
});
