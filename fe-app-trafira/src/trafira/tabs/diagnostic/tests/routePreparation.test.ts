import { describe, expect, it } from 'vitest';
import {
  parseRouteJobCommandResult,
  runRoutePreparation,
} from '../routeExplanation';
const request = {
  domain: 'target.example',
  source: { kind: 'router' as const },
  destination_ip: '203.0.113.10',
  port: 443,
  network: 'tcp' as const,
};
const report = {
  success: true,
  decision: { status: 'matched', outbound: 'vpn-out', trace: [], missing: [] },
  limitations: [],
};
const job = (value: unknown) =>
  parseRouteJobCommandResult({ stdout: JSON.stringify(value), code: 0 });
describe('background route transport', () => {
  it('starts a fresh job only when the stored job no longer exists', async () => {
    const calls: string[] = [];
    const result = await runRoutePreparation(
      async (name) => {
        calls.push(name);
        if (name === 'route_explain_status')
          return job({ success: false, running: false, error: 'invalid_job' });
        return job({ success: true, running: false, job_id: 'r-ade', report });
      },
      request,
      () => {},
      () => true,
      async () => {},
      'r-abcd',
    );
    expect(result.decision.outbound).toBe('vpn-out');
    expect(calls).toEqual(['route_explain_status', 'route_explain_start']);
  });
  it('restores a finished job by ID without calculating the same scenario again', async () => {
    const calls: string[] = [];
    const result = await runRoutePreparation(
      async (name, args) => {
        calls.push(name);
        expect(args).toEqual(['r-abcd']);
        return job({ success: true, running: false, job_id: 'r-abcd', report });
      },
      request,
      () => {},
      () => true,
      async () => {},
      'r-abcd',
    );
    expect(result.decision.outbound).toBe('vpn-out');
    expect(calls).toEqual(['route_explain_status']);
  });
  it('polls its own job, reports progress and validates the final route report', async () => {
    const calls: string[] = [],
      progress: number[] = [];
    const responses = [
      {
        success: true,
        running: true,
        job_id: 'r-abc',
        progress: { completed: 0, total: 41, phase: 'preparing' },
      },
      {
        success: true,
        running: true,
        job_id: 'r-abc',
        progress: { completed: 12, total: 41, phase: 'preparing' },
      },
      { success: true, running: false, job_id: 'r-abc', report },
    ];
    const result = await runRoutePreparation(
      async (name, args) => {
        calls.push(name);
        if (name === 'route_explain_status') expect(args).toEqual(['r-abc']);
        else expect(JSON.parse(args[0])).toEqual(request);
        return job(responses.shift());
      },
      request,
      (p) => progress.push(p.completed),
      () => true,
      async () => {},
    );
    expect(result.decision.outbound).toBe('vpn-out');
    expect(progress).toEqual([0, 12]);
    expect(calls).toEqual([
      'route_explain_start',
      'route_explain_status',
      'route_explain_status',
    ]);
  });
  it('does not accept a different job result', async () => {
    let n = 0;
    await expect(
      runRoutePreparation(
        async () =>
          job(
            n++ === 0
              ? { success: true, running: true, job_id: 'r-a' }
              : { success: true, running: false, job_id: 'r-b', report },
          ),
        request,
        () => {},
        () => true,
        async () => {},
      ),
    ).rejects.toMatchObject({ category: 'invalid_response' });
  });
  it('retries a transient polling timeout without starting a second worker', async () => {
    const calls: string[] = [];
    let polls = 0;
    const result = await runRoutePreparation(
      async (name) => {
        calls.push(name);
        if (name === 'route_explain_start')
          return job({ success: true, running: true, job_id: 'r-a' });
        if (!polls++)
          return parseRouteJobCommandResult({
            stdout: '',
            code: 1,
            failure: 'timeout',
          });
        return job({ success: true, running: false, job_id: 'r-a', report });
      },
      request,
      () => {},
      () => true,
      async () => {},
    );
    expect(result.decision.outbound).toBe('vpn-out');
    expect(calls.filter((name) => name === 'route_explain_start')).toHaveLength(
      1,
    );
  });
  it('stops polling after the view has changed', async () => {
    let active = true,
      calls = 0;
    await expect(
      runRoutePreparation(
        async () => {
          calls++;
          return job({ success: true, running: true, job_id: 'r-a' });
        },
        request,
        () => {},
        () => active,
        async () => {
          active = false;
        },
      ),
    ).rejects.toThrow();
    expect(calls).toBe(1);
  });
  it('bounds polling when a worker never finishes', async () => {
    let calls = 0;
    await expect(
      runRoutePreparation(
        async () => {
          calls++;
          return job({ success: true, running: true, job_id: 'r-a' });
        },
        request,
        () => {},
        () => true,
        async () => {},
      ),
    ).rejects.toMatchObject({ category: 'worker_timeout' });
    expect(calls).toBeLessThanOrEqual(301);
  });
  it.each([
    { success: true, running: true, job_id: '../secret' },
    {
      success: true,
      running: true,
      job_id: 'r-a',
      progress: { completed: 2, total: 1, phase: 'preparing' },
    },
    {
      success: true,
      running: true,
      job_id: 'r-a',
      progress: { completed: 0, total: 100000, phase: 'preparing' },
    },
  ])('rejects malformed job state', (value) => {
    expect(() => job(value)).toThrow();
  });
  it('keeps known worker errors actionable without exposing arbitrary output', () => {
    expect(() =>
      job({ success: false, running: false, error: 'worker_interrupted' }),
    ).toThrow(expect.objectContaining({ category: 'worker_interrupted' }));
    expect(() =>
      parseRouteJobCommandResult({ stdout: 'private /etc/key', code: 1 }),
    ).toThrow(expect.objectContaining({ category: 'invalid_response' }));
  });
});

it('preserves validation errors from the background worker', () => {
  expect(() =>
    job({ success: false, running: false, error: 'invalid_request' }),
  ).toThrow('invalid_request');
});

it('preserves resource limit errors from background jobs', () => {
  expect(() =>
    job({ success: false, running: false, error: 'resource_limit' }),
  ).toThrow(expect.objectContaining({ category: 'resource_limit' }));
});
