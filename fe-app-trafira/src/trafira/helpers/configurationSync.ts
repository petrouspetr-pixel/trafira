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
}
let pendingCommit: TrackedCommit | null = null;

// The configuration worker is shared by profiles and presets and runs one job
// at a time. Keep its ownership outside tab controllers, which may be unmounted.
export function trackConfigurationCommit(
  jobId: string,
  poll: () => Promise<object>,
): void {
  if (!jobId || pendingCommit?.jobId === jobId) return;
  if (pendingCommit?.timer) clearTimeout(pendingCommit.timer);
  const tracked = { jobId, poll };
  pendingCommit = tracked;
  schedule(tracked);
}

export function isTrackedConfigurationCommit(jobId: unknown): boolean {
  return !!pendingCommit && jobId === pendingCommit.jobId;
}

export function observeConfigurationCommit(status: JobStatus): boolean {
  if (
    !pendingCommit ||
    status.job_id !== pendingCommit.jobId ||
    status.running !== false
  )
    return false;
  if (pendingCommit.timer) clearTimeout(pendingCommit.timer);
  pendingCommit = null;
  const committed =
    status.success === true &&
    !status.rollback_error &&
    !status.recovery_pending;
  if (committed) reloadAfterConfigurationCommit();
  return committed;
}

function schedule(tracked: TrackedCommit): void {
  tracked.timer = setTimeout(async () => {
    tracked.timer = undefined;
    try {
      const status = (await tracked.poll()) as JobStatus;
      if (pendingCommit === tracked) observeConfigurationCommit(status);
    } catch {
      // A failed status request says nothing about whether the worker committed.
    } finally {
      if (pendingCommit === tracked) schedule(tracked);
    }
  }, 2000);
}
