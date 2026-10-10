import { executeShellCommand } from '../../../helpers/executeShellCommand';
import {
  SnapshotController,
  SnapshotReport,
  SnapshotStartResult,
} from './snapshotPanel';

async function command<T>(name: string): Promise<T> {
  const result = await executeShellCommand({
    command: '/usr/bin/trafira',
    args: [name],
    timeout: 15000,
  });
  if (result.code) throw new Error('Snapshot command failed');
  return JSON.parse(result.stdout) as T;
}

function size(bytes: number) {
  return `${(bytes / 1024).toFixed(1)} KiB`;
}

function startErrorText(error: string) {
  switch (error) {
    case 'Could not read snapshot status':
      return _(
        'Could not read saved-copy status. Refresh the status to try again.',
      );
    case 'Snapshot preparation is already starting':
      return _(
        'A copy download is already starting. Wait, then refresh the status.',
      );
    case 'Snapshot preparation is running or unavailable':
      return _(
        'Could not start downloading copies. Another list update may be running, or the core and saved configuration may be unavailable. Refresh the status and try again.',
      );
    case 'Failed to write snapshot job':
      return _(
        'Could not save the download task. Check free storage on the router.',
      );
    case 'Failed to start snapshot worker':
      return _(
        'Could not start the download task. Refresh the status and try again.',
      );
    default:
      return _(
        'Could not start downloading copies. Refresh the status and try again.',
      );
  }
}

function jobStatusText(job: NonNullable<SnapshotReport['job']>) {
  if (job.running) return _('Downloading and checking list copies…');
  if (job.success) {
    return _(
      'Copies were downloaded and checked. They will be checked again before the next startup.',
    );
  }
  switch (job.message) {
    case 'Failed to write snapshot job':
    case 'Failed to start snapshot worker':
      return startErrorText(job.message);
    case 'Another lists update is already running':
      return _(
        'Another list update is already running. Wait for it to finish, then download the copies again.',
      );
    case 'Snapshot preparation unavailable: check core, configuration and lists proxy':
      return _(
        'Could not download copies. Check the sing-box version, saved configuration and proxy for list downloads.',
      );
    case 'Snapshot worker exited unexpectedly':
      return _(
        'Downloading copies was interrupted. Download the copies again.',
      );
    case 'Snapshot preparation failed; previous copies preserved':
      return _(
        'Some copies could not be downloaded or saved. Previous copies were preserved for failed lists. Check the internet connection, list-download proxy and router storage.',
      );
    default:
      return _(
        'Could not download copies. Check the internet connection, list-download proxy and router storage.',
      );
  }
}

function render(
  report: SnapshotReport | null,
  error: string,
  starting: boolean,
) {
  const container = document.getElementById('fkp_diagnostic-page-snapshots');
  if (!container) return;
  const expanded = container.querySelector<HTMLDetailsElement>('details')?.open;
  const busy = starting || !!report?.job?.running;
  const stored = report?.entries.filter((entry) => entry.present).length || 0;
  container.replaceChildren(
    E('div', { class: 'fkp_diagnostic-panel' }, [
      E('h3', {}, _('Rule-set copies for startup')),
      E(
        'p',
        {},
        _(
          'Local copies help Trafira start when remote list sources are unavailable.',
        ),
      ),
      E(
        'p',
        {},
        _(
          'Download or refresh lists from the saved configuration and check them before storing them on the router. The action uses the configured proxy for list downloads.',
        ),
      ),
      ...(error
        ? [
            E(
              'p',
              { class: 'alert-message warning', role: 'status' },
              startErrorText(error),
            ),
          ]
        : []),
      ...(starting
        ? [E('p', { role: 'status' }, _('Starting the copy download…'))]
        : []),
      ...(!report
        ? [E('p', {}, _('Snapshot status unavailable'))]
        : [
            ...(!report.supported
              ? [E('p', {}, _('Requires sing-box 1.14 or newer'))]
              : []),
            ...(!report.available
              ? [E('p', {}, _('Saved configuration unavailable'))]
              : []),
            ...(report.supported &&
            report.available &&
            report.entries.length > 0 &&
            !report.preparable
              ? [
                  E(
                    'p',
                    {},
                    _(
                      'Apply the Trafira configuration again to enable saved copies for this core',
                    ),
                  ),
                ]
              : []),
            ...(report.entries.length
              ? [
                  E(
                    'p',
                    {},
                    `${_('Copies stored on router')}: ${stored} / ${report.entries.length} · ${_('Lists without a saved copy')}: ${report.entries.length - stored}`,
                  ),
                  E(
                    'details',
                    {
                      class: 'fkp_diagnostic-details',
                      ...(expanded ? { open: true } : {}),
                    },
                    [
                      E(
                        'summary',
                        {},
                        `${_('Show saved lists and storage')} (${report.entries.length})`,
                      ),
                      E(
                        'p',
                        {},
                        `${_('Storage')}: ${size(report.total_bytes)} / ${size(report.quota_bytes)}`,
                      ),
                      E(
                        'p',
                        {},
                        _(
                          'Copies are checked when downloaded and before startup. This inventory does not verify their current contents or whether the running service uses them.',
                        ),
                      ),
                      E(
                        'div',
                        { class: 'fkp_diagnostic-snapshots' },
                        report.entries.map((entry) =>
                          E('div', {}, [
                            E('b', {}, entry.tag),
                            E(
                              'p',
                              {},
                              entry.present
                                ? `${_('Copy present')}: ${size(entry.bytes)} · ${entry.mtime ? new Date(entry.mtime * 1000).toLocaleString() : '—'}`
                                : _('Copy missing'),
                            ),
                            ...(entry.configured_initial
                              ? [
                                  E(
                                    'p',
                                    {},
                                    _(
                                      'Referenced in saved startup configuration',
                                    ),
                                  ),
                                ]
                              : []),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ]
              : []),
            ...(report.entries.length === 0
              ? [E('p', {}, _('No remote rule sets in saved configuration'))]
              : []),
            ...(report.job
              ? [
                  E(
                    'p',
                    {
                      role: 'status',
                      ...(!report.job.running && !report.job.success
                        ? { class: 'alert-message warning' }
                        : {}),
                    },
                    report.job.running
                      ? jobStatusText(report.job)
                      : `${_('Last download')}: ${jobStatusText(report.job)}`,
                  ),
                ]
              : []),
          ]),
      E('div', { class: 'fkp_diagnostic-actions' }, [
        E(
          'button',
          {
            class: 'btn cbi-button',
            ...(busy ||
            !report?.supported ||
            !report?.available ||
            !report?.preparable ||
            !report.entries.length
              ? { disabled: true }
              : {}),
            click: () => void snapshots.prepare(),
          },
          _('Download / update list copies'),
        ),
        E(
          'button',
          {
            class: 'btn cbi-button',
            ...(starting ? { disabled: true } : {}),
            click: () => void snapshots.refresh(),
          },
          _('Refresh status'),
        ),
      ]),
    ]),
  );
}

export const snapshots = new SnapshotController(
  () => command<SnapshotReport>('ruleset_snapshot_report'),
  () => command<SnapshotStartResult>('ruleset_snapshot_prepare_async'),
  render,
);
