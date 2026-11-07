import { beforeEach, expect, it } from 'vitest';
import { store } from '../../services/store.service';
import type { Trafira } from '../../types';
import {
  createServiceStatusPresenter,
  getServiceStatus,
} from '../serviceStatus';

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

const failedStart: Trafira.ServiceActionState = {
  kind: 'service',
  action: 'start',
  job_id: 'start-10',
  started_at: 10,
  running: false,
  success: false,
  exit_code: 1,
};

it('retains a failed service outcome after acknowledgement removes the backend action', () => {
  ready();
  const present = createServiceStatusPresenter();
  expect(present(store.get(), [failedStart])).toBe('start-failed');
  expect(present(store.get(), [])).toBe('start-failed');
  expect(present(store.get())).toBe('start-failed');
});

it.each(['start', 'stop'] as const)(
  'clears the retained failure on a new local %s and does not restore the acknowledged job',
  (action) => {
    ready();
    const present = createServiceStatusPresenter();
    present(store.get(), [failedStart]);
    present(store.get(), []);
    store.set({
      diagnosticsActions: {
        ...store.get().diagnosticsActions,
        [action]: { loading: true },
      },
    });
    expect(present(store.get())).toBe(
      action === 'start' ? 'starting' : 'stopping',
    );
    store.set({
      diagnosticsActions: {
        ...store.get().diagnosticsActions,
        [action]: { loading: false },
      },
    });
    expect(present(store.get(), [failedStart])).toBe('stopped');
    expect(present(store.get(), [])).toBe('stopped');
  },
);

it('does not restore a stale failed snapshot after confirmed recovery and a later stop', () => {
  ready();
  const present = createServiceStatusPresenter();
  present(store.get(), [failedStart]);
  ready(1, 'running');
  expect(present(store.get())).toBe('running');
  ready();
  expect(present(store.get(), [failedStart])).toBe('stopped');
});

it('accepts a new failed job after a backend transition and clears it on a newer successful stop', () => {
  ready();
  const present = createServiceStatusPresenter();
  present(store.get(), [failedStart]);
  const next = { ...failedStart, job_id: 'start-20', started_at: 20 };
  ready(0, 'starting');
  expect(present(store.get(), [{ ...next, running: true }])).toBe('starting');
  ready();
  expect(present(store.get(), [next])).toBe('start-failed');
  expect(present(store.get(), [])).toBe('start-failed');
  expect(
    present(store.get(), [
      {
        ...next,
        action: 'stop',
        job_id: 'stop-30',
        started_at: 30,
        success: true,
        exit_code: 0,
      },
    ]),
  ).toBe('stopped');
  expect(present(store.get(), [failedStart, next])).toBe('stopped');
});

it('retains the outcome of an action whose status was temporarily unavailable', () => {
  ready(0, 'starting');
  const present = createServiceStatusPresenter();
  present(store.get(), [{ ...failedStart, running: true }]);
  store.set({
    servicesInfoWidget: { ...store.get().servicesInfoWidget, failed: true },
  });
  expect(present(store.get())).toBe('unavailable');
  store.set({
    servicesInfoWidget: { ...store.get().servicesInfoWidget, failed: false },
  });
  expect(present(store.get(), [{ ...failedStart, running: true }])).toBe(
    'starting',
  );
  ready();
  expect(present(store.get(), [failedStart])).toBe('start-failed');
});
