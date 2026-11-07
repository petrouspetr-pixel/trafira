import { beforeEach, expect, it } from 'vitest';
import { store } from '../../services/store.service';
import type { Trafira } from '../../types';
import { getServiceStatus } from '../serviceStatus';

beforeEach(() => store.reset());

function ready(running = 0, status = 'stopped & disabled') {
  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: false,
      data: {
        singbox: running,
        trafiraRunning: running,
        trafiraEnabled: 0,
        trafiraStatus: status,
      },
    },
  });
}

it('distinguishes loading and an unavailable status from a confirmed stop', () => {
  expect(getServiceStatus(store.get())).toBe('loading');
  ready();
  expect(getServiceStatus(store.get())).toBe('stopped');
  ready(1, 'running but disabled');
  expect(getServiceStatus(store.get())).toBe('running');
  store.set({
    servicesInfoWidget: { ...store.get().servicesInfoWidget, failed: true },
  });
  expect(getServiceStatus(store.get())).toBe('unavailable');
});

it.each(['starting', 'restarting', 'stopping', 'reloading'])(
  'keeps the backend %s transition visible even while the process is running',
  (status) => {
    ready(1, status);
    expect(getServiceStatus(store.get())).toBe(
      status === 'reloading' ? 'restarting' : status,
    );
  },
);

it.each(['start', 'restart', 'stop'] as const)(
  'shows a local %s action before the next runtime poll',
  (action) => {
    ready();
    store.set({
      diagnosticsActions: {
        ...store.get().diagnosticsActions,
        [action]: { loading: true },
      },
    });
    expect(getServiceStatus(store.get())).toBe(
      { start: 'starting', restart: 'restarting', stop: 'stopping' }[action],
    );
  },
);

it('reports a failed start and clears it after a newer successful stop or a confirmed running state', () => {
  ready();
  const failed: Trafira.ServiceActionState = {
    kind: 'service',
    action: 'start',
    running: false,
    success: false,
    exit_code: 1,
    started_at: 10,
  };
  expect(getServiceStatus(store.get(), [failed])).toBe('start-failed');
  expect(
    getServiceStatus(store.get(), [
      failed,
      {
        ...failed,
        action: 'stop',
        success: true,
        exit_code: 0,
        started_at: 20,
      },
    ]),
  ).toBe('stopped');
  ready(1, 'running');
  expect(getServiceStatus(store.get(), [failed])).toBe('running');
});
