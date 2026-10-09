import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { SnapshotController, SnapshotReport } from './snapshotPanel';

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

function render(
  report: SnapshotReport | null,
  error: string,
  starting: boolean,
) {
  const container = document.getElementById('fkp_diagnostic-page-snapshots');
  if (!container) return;
  const busy = starting || !!report?.job?.running;
  const errorText =
    error === 'Could not start snapshot preparation'
      ? _('Could not start snapshot preparation')
      : _('Could not read snapshot status');
  container.replaceChildren(
    E('div', { class: 'fkp_diagnostic-page__right-bar__system-info' }, [
      E('b', {}, _('Saved rule sets')),
      E(
        'p',
        {},
        _(
          'Stored copies are validated when preparing and before startup. Presence does not confirm current validity or use by the running core.',
        ),
      ),
      ...(error ? [E('p', { class: 'alert-message warning' }, errorText)] : []),
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
            E(
              'p',
              {},
              `${_('Storage')}: ${size(report.total_bytes)} / ${size(report.quota_bytes)}`,
            ),
            ...report.entries.map((entry) =>
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
                  ? [E('p', {}, _('Referenced in saved startup configuration'))]
                  : []),
              ]),
            ),
            ...(report.entries.length === 0
              ? [E('p', {}, _('No remote rule sets in saved configuration'))]
              : []),
            ...(report.job
              ? [
                  E(
                    'p',
                    {},
                    report.job.running
                      ? _('Preparing snapshots')
                      : report.job.success
                        ? _('Snapshot preparation completed')
                        : _(
                            'Snapshot preparation failed; check core, configuration, proxy and storage',
                          ),
                  ),
                ]
              : []),
          ]),
      E(
        'button',
        {
          class: 'btn cbi-button',
          disabled:
            busy ||
            !report?.supported ||
            !report?.available ||
            !report?.preparable ||
            !report.entries.length,
          click: () => void snapshots.prepare(),
        },
        _('Prepare saved copies'),
      ),
      E(
        'button',
        {
          class: 'btn cbi-button',
          disabled: starting,
          click: () => void snapshots.refresh(),
        },
        _('Refresh status'),
      ),
    ]),
  );
}

export const snapshots = new SnapshotController(
  () => command<SnapshotReport>('ruleset_snapshot_report'),
  () => command<{ success: boolean }>('ruleset_snapshot_prepare_async'),
  render,
);
