import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { store } from '../store.service';
import { startServiceStatusBanner } from '../serviceStatus.service';

vi.mock('../../../helpers', () => ({ executeShellCommand: vi.fn() }));

// The native LuCI form replaces its map on Reset. Keep DOM ownership and
// connection behavior here, while the production mount/render functions run.
class Node {
  parentElement: Node | null = null;
  children: Node[] = [];
  attributes: Record<string, string> = {};
  textContent = '';
  className = '';
  id = '';
  style = { cssText: '' };
  onclick?: () => void;
  connected = true;
  get isConnected(): boolean {
    return (
      this.connected && (!this.parentElement || this.parentElement.isConnected)
    );
  }
  appendChild(child: Node) {
    child.parentElement = this;
    this.children.push(child);
    return child;
  }
  insertBefore(child: Node, reference: Node | null) {
    child.parentElement = this;
    this.children.splice(
      reference ? this.children.indexOf(reference) : this.children.length,
      0,
      child,
    );
  }
  remove() {
    if (this.parentElement)
      this.parentElement.children = this.parentElement.children.filter(
        (n) => n !== this,
      );
    this.connected = false;
  }
  setAttribute(key: string, value: string) {
    this.attributes[key] = value;
  }
  querySelector(selector: string) {
    return selector === '.cbi-tabmenu'
      ? this.children.find((n) => n.className === 'cbi-tabmenu')
      : null;
  }
}

let map: Node;
let mutation: () => void;
let stop: () => void;
const nativeTabClick = vi.fn();
beforeEach(() => {
  store.reset();
  nativeTabClick.mockReset();
  map = new Node();
  const tabs = new Node();
  tabs.className = 'cbi-tabmenu';
  map.appendChild(tabs);
  vi.stubGlobal('_', (text: string) => text);
  vi.stubGlobal('document', {
    body: new Node(),
    createElement: () => new Node(),
    getElementById: (id: string) => (id === 'cbi-trafira' ? map : null),
    querySelector: () => ({ click: nativeTabClick }),
  });
  vi.stubGlobal(
    'MutationObserver',
    class {
      constructor(callback: () => void) {
        mutation = callback;
      }
      observe() {}
      disconnect() {}
    },
  );
});
afterEach(() => {
  stop?.();
  vi.unstubAllGlobals();
});

it('shows live status above all tabs and opens diagnostics through the native tab', () => {
  stop = startServiceStatusBanner();
  const banner = map.children[0];
  expect(map.children[1].className).toBe('cbi-tabmenu');
  const status = banner.children[0];
  expect(status.attributes['aria-live']).toBe('polite');
  expect(status.textContent).toContain('Loading');
  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: false,
      data: {
        singbox: 1,
        trafiraRunning: 1,
        trafiraEnabled: 0,
        trafiraStatus: 'running but disabled',
      },
    },
  });
  expect(status.textContent).toContain('Running');
  store.set({ tabService: { current: 'configuration', all: [] } });
  mutation();
  expect(map.children[0]).toBe(banner);
  banner.children[1].onclick?.();
  expect(nativeTabClick).toHaveBeenCalledOnce();
});

it('remounts exactly once after native Reset replaces the form map and releases subscriptions on cleanup', () => {
  stop = startServiceStatusBanner();
  const previous = map;
  previous.connected = false;
  map = new Node();
  mutation();
  mutation();
  expect(map.children).toHaveLength(1);
  expect(map.children[0].children[0].textContent).toContain('Loading');
  const status = map.children[0].children[0];
  stop();
  store.set({
    servicesInfoWidget: {
      ...store.get().servicesInfoWidget,
      loading: false,
      failed: true,
    },
  });
  expect(map.children).toHaveLength(0);
  expect(status.textContent).toContain('Loading');
});
