import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import {
  clearPendingRoute,
  pendingRoute,
  pendingRouteId,
  savePendingRoute,
  savePendingRouteId,
} from '../routePending';

const request = {
  domain: 'instagram.com',
  source: {
    kind: 'device' as const,
    ip: '192.168.10.234',
    interface: 'br-lan',
  },
  port: 443,
  network: 'tcp' as const,
};
let values: Map<string, string>;
beforeEach(() => {
  values = new Map();
  vi.stubGlobal('sessionStorage', {
    getItem: (key: string) => values.get(key) || null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
  });
});
afterEach(() => vi.unstubAllGlobals());

it('retains the same job until completion and clears only its own request', () => {
  savePendingRoute(request);
  savePendingRouteId(request, 'r-abc');
  savePendingRoute(request);
  expect(pendingRouteId(request)).toBe('r-abc');
  const next = { ...request, domain: 'youtube.com' };
  savePendingRoute(next);
  clearPendingRoute(request);
  expect(pendingRoute()).toEqual(next);
  expect(pendingRouteId(request)).toBeUndefined();
  clearPendingRoute(next);
  expect(values.size).toBe(0);
});

it.each([Date.now() - 180001, Date.now() + 60000])(
  'does not run an expired or future stored request (%s)',
  (started) => {
    values.set('trafira-route-pending', JSON.stringify({ started, request }));
    expect(pendingRoute()).toBeNull();
    expect(values.size).toBe(0);
  },
);

it.each(['broken', 'x'.repeat(10001), '{}'])(
  'ignores malformed persisted state',
  (raw) => {
    values.set('trafira-route-pending', raw);
    expect(pendingRoute()).toBeNull();
  },
);

it('keeps manual checking usable when browser storage is blocked', () => {
  vi.stubGlobal('sessionStorage', {
    getItem() {
      throw new Error('disabled');
    },
    setItem() {
      throw new Error('disabled');
    },
    removeItem() {
      throw new Error('disabled');
    },
  });
  expect(() => savePendingRoute(request)).not.toThrow();
  expect(pendingRoute()).toBeNull();
  expect(pendingRouteId(request)).toBeUndefined();
  expect(() => clearPendingRoute(request)).not.toThrow();
});
