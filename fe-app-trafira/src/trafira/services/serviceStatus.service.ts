import { getServiceStatus, ServiceStatus } from '../helpers/serviceStatus';
import {
  getCachedRuntimeUiState,
  subscribeRuntimeUiState,
} from './runtimeUiState.service';
import { store } from './store.service';

function statusLabel(status: ServiceStatus) {
  const labels: Record<ServiceStatus, string> = {
    loading: _('Loading service status…'),
    unavailable: _('Service status unavailable'),
    running: _('Running'),
    stopped: _('Stopped'),
    starting: _('Starting…'),
    restarting: _('Restarting…'),
    stopping: _('Stopping…'),
    'start-failed': _('Failed to start Trafira'),
  };
  return labels[status];
}

/** Shares the existing runtime poll; survives native form Reset replacing the map. */
export function startServiceStatusBanner() {
  let banner: HTMLElement | null = null;
  let statusNode: HTMLElement | null = null;
  let cachedState = getCachedRuntimeUiState();
  let stopped = false;

  const render = () => {
    if (!statusNode) return;
    const status = getServiceStatus(store.get(), cachedState?.actions.service);
    const label = `Trafira: ${statusLabel(status)}`;
    if (statusNode.textContent !== label) statusNode.textContent = label;
  };

  const mount = () => {
    if (stopped || typeof document === 'undefined') return;
    const map = document.getElementById('cbi-trafira');
    if (!map) return;
    if (banner?.isConnected && banner.parentElement === map) return;
    banner?.remove();
    banner = document.createElement('div');
    banner.id = 'trafira-service-status';
    banner.className = 'cbi-section';
    banner.style.cssText =
      'display:flex;align-items:center;justify-content:space-between;gap:1em;flex-wrap:wrap;padding:.75em 1em;margin-bottom:1em';
    statusNode = document.createElement('strong');
    statusNode.setAttribute('role', 'status');
    statusNode.setAttribute('aria-live', 'polite');
    statusNode.setAttribute('aria-atomic', 'true');
    banner.appendChild(statusNode);
    const diagnostics = document.createElement('button');
    diagnostics.setAttribute('type', 'button');
    diagnostics.className = 'cbi-button cbi-button-neutral';
    diagnostics.textContent = _('Diagnostics');
    diagnostics.onclick = () => {
      document
        .querySelector<HTMLAnchorElement>(
          '#cbi-trafira .cbi-tabmenu [data-tab="diagnostic"] a',
        )
        ?.click();
    };
    banner.appendChild(diagnostics);
    const tabs = map.querySelector('.cbi-tabmenu');
    // CBI may render its tab menu inside the section; keeping the status before
    // that section also keeps it outside every tab's hidden pane.
    let anchor = tabs;
    while (anchor && anchor.parentElement !== map)
      anchor = anchor.parentElement;
    map.insertBefore(banner, anchor || null);
    render();
  };

  const unsubscribeStore = store.subscribe(render);
  const unsubscribeRuntime = subscribeRuntimeUiState((state) => {
    cachedState = state;
    render();
  });
  const observer = new MutationObserver(mount);
  observer.observe(document.body, { childList: true, subtree: true });
  mount();
  return () => {
    if (stopped) return;
    stopped = true;
    observer.disconnect();
    unsubscribeStore();
    unsubscribeRuntime();
    banner?.remove();
    banner = null;
    statusNode = null;
  };
}
