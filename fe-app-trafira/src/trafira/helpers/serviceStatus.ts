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

type ServiceStatusState = Pick<
  StoreType,
  'servicesInfoWidget' | 'diagnosticsActions'
>;

function actionIdentity(action: Trafira.ServiceActionState) {
  return action.job_id || `${action.action}:${action.started_at || 0}`;
}

/** Retain the latest outcome across backend acknowledgement, for this page's lifetime. */
export function createServiceStatusPresenter() {
  let latest: Trafira.ServiceActionState | undefined;
  let transition: ServiceStatus | undefined;
  const dismissed = new Set<string>();

  const clearOutcome = () => {
    if (latest) dismissed.add(actionIdentity(latest));
  };

  return (
    state: ServiceStatusState,
    actions?: Trafira.ServiceActionState[],
  ): ServiceStatus => {
    const base = getServiceStatus(state);
    const nextTransition = ['starting', 'restarting', 'stopping'].includes(base)
      ? base
      : undefined;
    if (nextTransition && nextTransition !== transition) clearOutcome();
    if (base !== 'unavailable' && base !== 'loading')
      transition = nextTransition;

    // Store notifications may precede the fresh runtime callback. Only ingest
    // actions when supplied by that callback, never replay a cached snapshot.
    const next =
      actions &&
      [...actions].sort((a, b) => (b.started_at || 0) - (a.started_at || 0))[0];
    if (
      next &&
      !dismissed.has(actionIdentity(next)) &&
      (!latest || (next.started_at || 0) >= (latest.started_at || 0))
    ) {
      if (latest && actionIdentity(next) !== actionIdentity(latest))
        clearOutcome();
      latest = next;
    }
    if (base === 'running') clearOutcome();
    return getServiceStatus(
      state,
      latest && !dismissed.has(actionIdentity(latest)) ? [latest] : [],
    );
  };
}

export function getServiceStatus(
  state: ServiceStatusState,
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
