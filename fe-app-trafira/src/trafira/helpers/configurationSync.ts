export function confirmConfigurationReplacement(): boolean {
  return window.confirm(
    _(
      'Applying these settings replaces the saved configuration. Any unsaved changes in this LuCI page will be lost. Continue?',
    ),
  );
}

let reloadRequested = false;
export function reloadAfterConfigurationCommit(): void {
  if (reloadRequested) return;
  reloadRequested = true;
  window.location.reload();
}

type JobStatus = Record<string, unknown>;
interface TrackedCommit {
  jobId: string;
  poll: () => Promise<object>;
  timer?: ReturnType<typeof setTimeout>;
  unmatchedStatuses: number;
}
const pendingCommits = new Map<string, TrackedCommit>();
const unreportedFailures = new Set<string>();

// The configuration worker is shared by profiles and presets and runs one job
// at a time. Keep ownership outside tab controllers, which may be unmounted.
// Start responses can arrive out of order, so retain each accepted job by ID.
export function trackConfigurationCommit(
  jobId: string,
  poll: () => Promise<object>,
): void {
  if (!jobId || pendingCommits.has(jobId)) return;
  const tracked = { jobId, poll, unmatchedStatuses: 0 };
  pendingCommits.set(jobId, tracked);
  schedule(tracked);
}

export function isTrackedConfigurationCommit(jobId: unknown): boolean {
  return (
    typeof jobId === 'string' &&
    (pendingCommits.has(jobId) || unreportedFailures.has(jobId))
  );
}

export function observeConfigurationCommit(status: JobStatus): boolean {
  return observeStatus(status, true);
}

function observeStatus(status: JobStatus, reportFailure: boolean): boolean {
  if (reportFailure && typeof status.job_id === 'string')
    unreportedFailures.delete(status.job_id);
  if (status.running === false && typeof status.success === 'boolean')
    for (const jobId of unreportedFailures)
      if (jobId !== status.job_id) unreportedFailures.delete(jobId);
  const tracked =
    typeof status.job_id === 'string'
      ? pendingCommits.get(status.job_id)
      : undefined;
  for (const other of pendingCommits.values()) {
    if (other === tracked) other.unmatchedStatuses = 0;
    else if (status.running === false && typeof status.success === 'boolean') {
      // Status stores just the latest durable job. Repeated terminal mismatches
      // mean our record disappeared; stop waiting without inventing its result.
      if (++other.unmatchedStatuses >= 3) forget(other);
    }
  }
  if (!tracked || status.running !== false) return false;
  forget(tracked);
  const committed =
    status.success === true &&
    !status.rollback_error &&
    !status.recovery_pending;
  if (committed) reloadAfterConfigurationCommit();
  else if (
    !reportFailure &&
    (status.success === false ||
      status.rollback_error ||
      status.recovery_pending)
  )
    // Keep an own background failure actionable once when a panel returns.
    unreportedFailures.add(tracked.jobId);
  return committed;
}

function forget(tracked: TrackedCommit): void {
  if (tracked.timer) clearTimeout(tracked.timer);
  pendingCommits.delete(tracked.jobId);
}

function schedule(tracked: TrackedCommit): void {
  tracked.timer = setTimeout(async () => {
    tracked.timer = undefined;
    try {
      const status = (await tracked.poll()) as JobStatus;
      if (pendingCommits.get(tracked.jobId) === tracked)
        observeStatus(status, false);
    } catch {
      // A failed status request says nothing about whether the worker committed.
    } finally {
      if (pendingCommits.get(tracked.jobId) === tracked) schedule(tracked);
    }
  }, 2000);
}
