import type { ExplainRequest } from './routeExplanation';

const KEY = 'trafira-route-pending';
const MAX_AGE = 180000;

// Tab-scoped only: do not persist device metadata after a completed check.
// Browsers may disable storage; manual diagnostics must still work then.
export function pendingRoute(): ExplainRequest | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;
    if (raw.length > 10000) throw new Error('Oversized pending request');
    const value = JSON.parse(raw);
    const r = value?.request;
    if (
      !Number.isFinite(value.started) ||
      Date.now() - value.started > MAX_AGE ||
      value.started > Date.now() + 5000 ||
      typeof r?.domain !== 'string' ||
      r.domain.length > 253 ||
      !['router', 'device'].includes(r.source?.kind) ||
      (r.source.kind === 'device' && typeof r.source.ip !== 'string') ||
      !Number.isInteger(r.port) ||
      r.port < 1 ||
      r.port > 65535 ||
      !['tcp', 'udp'].includes(r.network)
    )
      throw new Error('Invalid pending request');
    return r as ExplainRequest;
  } catch {
    try {
      sessionStorage.removeItem(KEY);
    } catch {
      /* Storage unavailable. */
    }
    return null;
  }
}

export function savePendingRoute(request: ExplainRequest) {
  try {
    if (JSON.stringify(pendingRoute()) !== JSON.stringify(request))
      sessionStorage.setItem(
        KEY,
        JSON.stringify({ started: Date.now(), request }),
      );
  } catch {
    /* Storage unavailable. */
  }
}

export function clearPendingRoute(request: ExplainRequest) {
  try {
    if (JSON.stringify(pendingRoute()) === JSON.stringify(request))
      sessionStorage.removeItem(KEY);
  } catch {
    /* Storage unavailable. */
  }
}

export function pendingRouteId(request: ExplainRequest): string | undefined {
  try {
    if (JSON.stringify(pendingRoute()) !== JSON.stringify(request)) return;
    const id = JSON.parse(sessionStorage.getItem(KEY) || '{}').job_id;
    return typeof id === 'string' && /^r-[a-f0-9-]{1,60}$/.test(id)
      ? id
      : undefined;
  } catch {
    return;
  }
}

export function savePendingRouteId(request: ExplainRequest, id?: string) {
  try {
    if (
      !id ||
      !/^r-[a-f0-9-]{1,60}$/.test(id) ||
      JSON.stringify(pendingRoute()) !== JSON.stringify(request)
    )
      return;
    const value = JSON.parse(sessionStorage.getItem(KEY) || '{}');
    value.job_id = id;
    sessionStorage.setItem(KEY, JSON.stringify(value));
  } catch {
    /* Storage unavailable. */
  }
}
