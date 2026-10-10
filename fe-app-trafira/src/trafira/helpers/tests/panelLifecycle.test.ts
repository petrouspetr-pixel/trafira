import { afterEach, expect, it, vi } from 'vitest';
import { watchPanel } from '../panelLifecycle';

afterEach(() => vi.unstubAllGlobals());
it('mounts only a visible native CBI host and cleans up on tab switches and rerenders', () => {
  let changed: () => void = () => {};
  const disconnect = vi.fn();
  vi.stubGlobal(
    'MutationObserver',
    class {
      constructor(callback: () => void) {
        changed = callback;
      }
      observe() {}
      disconnect = disconnect;
    },
  );
  let node: { isConnected: boolean; offsetParent: object | null } | null = null;
  vi.stubGlobal('document', { body: {}, getElementById: () => node });
  const panel = { mount: vi.fn(), unmount: vi.fn() };
  const stop = watchPanel('profiles', panel, false);
  expect(panel.mount).not.toHaveBeenCalled();
  node = { isConnected: true, offsetParent: null };
  changed();
  expect(panel.mount).not.toHaveBeenCalled();
  node.offsetParent = {};
  changed();
  changed();
  expect(panel.mount).toHaveBeenCalledExactlyOnceWith(false);
  node.offsetParent = null;
  changed();
  expect(panel.unmount).toHaveBeenCalledTimes(1);
  node.offsetParent = {};
  changed();
  node = { isConnected: true, offsetParent: {} };
  changed();
  expect(panel.mount).toHaveBeenCalledTimes(3);
  expect(panel.unmount).toHaveBeenCalledTimes(2);
  stop();
  expect(disconnect).toHaveBeenCalledTimes(1);
  expect(panel.unmount).toHaveBeenCalledTimes(3);
});
