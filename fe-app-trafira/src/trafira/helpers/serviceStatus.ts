import type { StoreType } from '../services/store.service';
import type { Trafira } from '../types';

export type ServiceStatus =
  | 'loading'
  | 'unavailable'
  | 'running'
  | 'stopped'
  | 'starting'
  | 'restarting'
  | 'stopping'
  | 'start-failed';

export function getServiceStatus(
  state: Pick<StoreType, 'servicesInfoWidget' | 'diagnosticsActions'>,
  actions: Trafira.ServiceActionState[] = [],
): ServiceStatus {
  const { servicesInfoWidget: widget, diagnosticsActions: local } = state;
  if (widget.failed) return 'unavailable';
  const status = widget.data.trafiraStatus;
  if (
    local.restart.loading ||
    status === 'restarting' ||
    status === 'reloading'
  )
    return 'restarting';
  if (local.start.loading || status === 'starting') return 'starting';
  if (local.stop.loading || status === 'stopping') return 'stopping';
  if (widget.loading) return 'loading';
  if (widget.data.trafiraRunning) return 'running';
  const latest = [...actions].sort(
    (a, b) => (b.started_at || 0) - (a.started_at || 0),
  )[0];
  if (
    latest &&
    !latest.running &&
    !latest.success &&
    ['start', 'restart', 'reload'].includes(latest.action)
  )
    return 'start-failed';
  return 'stopped';
}
