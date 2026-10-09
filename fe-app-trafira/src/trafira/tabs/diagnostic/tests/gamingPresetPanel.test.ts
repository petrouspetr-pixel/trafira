import { describe, expect, it, vi } from 'vitest';
import { GamingPresetController } from '../gamingPresetPanel';
const selection = {
  preset: 'steam',
  device_ips: ['192.0.2.5/32'],
  proxy_section: 'vpn',
  placement: 'before-device-routes',
};
describe('gaming preset preview', () => {
  it('requires a device and explicit placement and applies only reviewed input', async () => {
    const call = vi.fn().mockResolvedValue({
        success: true,
        applicable: true,
        digest: 'digest',
        patch: { sections: [] },
      }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.preview({ ...selection, device_ips: [] }, 'digest');
    expect(call).not.toHaveBeenCalled();
    await c.preview({ ...selection, placement: '' }, 'digest');
    expect(call).not.toHaveBeenCalled();
    await c.preview(selection, 'digest');
    await c.apply();
    expect(call.mock.lastCall?.[0]).toEqual({
      ...selection,
      action: 'apply',
      expected_digest: 'digest',
    });
  });
  it('invalidates preview on edits and stale conflicts', async () => {
    const call = vi
        .fn()
        .mockResolvedValue({ success: true, applicable: true, digest: 'd' }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.preview(selection, 'd');
    c.invalidate();
    await c.apply();
    expect(call).toHaveBeenCalledTimes(1);
    call.mockResolvedValue({ success: false, error: 'conflict' });
    await c.preview(selection, 'd');
    await c.apply();
    expect(call).toHaveBeenCalledTimes(2);
  });
  it('does not add unselected IPv6 and blocks Alice conflicts', async () => {
    const call = vi
        .fn()
        .mockResolvedValue({ success: false, error: 'alice_bypass' }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.preview(selection, 'd');
    expect(call.mock.lastCall?.[0].device_ips).toEqual(['192.0.2.5/32']);
    await c.apply();
    expect(call).toHaveBeenCalledTimes(1);
  });
  it('reconnects to worker without submitting again and ignores unmounted requests', async () => {
    const call = vi
        .fn()
        .mockResolvedValue({ success: true, running: true, job_id: 'j-1' }),
      render = vi.fn();
    const c = new GamingPresetController(call, render);
    c.mount();
    await c.poll();
    expect(render.mock.lastCall?.[0].running).toBe(true);
    await c.preview(selection, 'd');
    expect(call).toHaveBeenCalledTimes(1);
    c.unmount();
    await c.poll();
    expect(call).toHaveBeenCalledTimes(1);
  });
});
