import { ClashAPI } from '../types';

export type LatencyStatus = 'unmeasured' | 'available' | 'unavailable';

// Only keep one snapshot, scoped to a running core and the configured nodes.
// sing-box deletes a node's successful history when its next check fails.
export class LatencyObservations {
  private scope = '';
  private previous = new Map<string, LatencyStatus>();

  update(
    scope: string,
    proxies: ClashAPI.Proxies['proxies'],
  ): Map<string, LatencyStatus> {
    if (!scope || scope !== this.scope) this.previous.clear();
    this.scope = scope;
    const next = new Map<string, LatencyStatus>();
    for (const [code, proxy] of Object.entries(proxies)) {
      const history = proxy.history;
      const latest = Array.isArray(history) ? history[0] : undefined;
      const delay = latest?.delay;
      let status: LatencyStatus = 'unmeasured';
      if (typeof delay === 'number' && Number.isFinite(delay) && delay >= 0) {
        status = delay > 0 ? 'available' : 'unavailable';
      } else if (
        Array.isArray(history) &&
        !history.length &&
        scope &&
        ['available', 'unavailable'].includes(this.previous.get(code) || '')
      ) {
        status = 'unavailable';
      }
      next.set(code, status);
    }
    this.previous = next;
    return next;
  }
}

export function formatLatency(latency: number, status?: LatencyStatus): string {
  if (status === 'unavailable') return _('Unavailable');
  return latency > 0 ? `${latency}ms` : _('No measurement');
}
