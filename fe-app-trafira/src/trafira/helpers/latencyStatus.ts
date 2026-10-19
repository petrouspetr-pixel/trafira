import { ClashAPI } from '../types';

export type LatencyStatus = 'unmeasured' | 'available' | 'unavailable';

// Only keep one snapshot, scoped to a running core and the configured nodes.
// sing-box deletes a node's successful history when its next check fails.
function isGroup(proxy: ClashAPI.ProxyBase) {
  return (
    Array.isArray(proxy.all) ||
    ['selector', 'urltest', 'fallback'].includes(proxy.type.toLowerCase())
  );
}

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
      if (isGroup(proxy)) {
        next.set(code, 'unmeasured');
        continue;
      }
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
    this.previous = new Map(next);
    // A group's history follows its selected leaf. Switching to an untested
    // leaf must not be misreported as a failed check on the old selection.
    for (const [groupCode, group] of Object.entries(proxies)) {
      if (!isGroup(group)) continue;
      let code = groupCode;
      const seen = new Set<string>();
      let status: LatencyStatus = 'unmeasured';
      while (proxies[code] && !seen.has(code) && seen.size < 64) {
        seen.add(code);
        const proxy = proxies[code];
        if (!isGroup(proxy)) {
          status = next.get(code) || 'unmeasured';
          break;
        }
        if (!proxy.now || !proxy.all?.includes(proxy.now)) break;
        code = proxy.now;
      }
      next.set(groupCode, status);
    }
    return next;
  }
}

export function formatLatency(latency: number, status?: LatencyStatus): string {
  if (status === 'unavailable') return _('Unavailable');
  return latency > 0 ? `${latency}ms` : _('No measurement');
}
