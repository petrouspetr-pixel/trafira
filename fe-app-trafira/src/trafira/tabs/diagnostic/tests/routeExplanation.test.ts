import { describe, expect, it, vi } from 'vitest';
import { RouteExplanationController, ExplainReport } from '../routeExplanation';

const request = {
  domain: 'store.example',
  source: { kind: 'router' as const },
  port: 443,
  network: 'tcp' as const,
};
const report = (outbound: string): ExplainReport => ({
  success: true,
  decision: { status: 'matched', outbound, trace: [], missing: [] },
  limitations: [],
});

describe('route explanation controller', () => {
  it('does not replace a newer result with an older request', async () => {
    let finishOld!: (value: ExplainReport) => void;
    const read = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise<ExplainReport>((resolve) => {
            finishOld = resolve;
          }),
      )
      .mockResolvedValueOnce(report('new'));
    const render = vi.fn();
    const controller = new RouteExplanationController(read, render);
    controller.mount();
    const old = controller.submit(request);
    await controller.submit(request);
    finishOld(report('old'));
    await old;
    expect(render.mock.lastCall?.[0]?.decision.outbound).toBe('new');
  });
  it('discards results after unmount and clears old state on mount', async () => {
    let finish!: (value: ExplainReport) => void;
    const render = vi.fn();
    const controller = new RouteExplanationController(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
      render,
    );
    controller.mount();
    const pending = controller.submit(request);
    controller.unmount();
    const count = render.mock.calls.length;
    finish(report('stale'));
    await pending;
    expect(render).toHaveBeenCalledTimes(count);
    controller.mount();
    expect(render.mock.lastCall).toEqual([null, '', false]);
  });
  it('clears a previous result on error without leaking the raw RPC error', async () => {
    const render = vi.fn();
    const read = vi
      .fn()
      .mockResolvedValueOnce(report('old'))
      .mockRejectedValueOnce(new Error('token=secret'));
    const controller = new RouteExplanationController(read, render);
    controller.mount();
    await controller.submit(request);
    await controller.submit(request);
    expect(render.mock.lastCall).toEqual([
      null,
      'Could not explain route',
      false,
    ]);
    expect(JSON.stringify(render.mock.calls)).not.toContain('secret');
  });
});
