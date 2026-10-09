import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { failurePolicyRows } from './helpers/failurePolicy';

let timer = 0;
let generation = 0;
export const failurePoliciesPanel = {
  mount() {
    this.unmount();
    const host = document.getElementById('trafira-failure-policies');
    if (!host) return;
    const current = generation;
    let pending = false;
    const labels: Record<string, string> = {
      block: _('Block traffic'),
      primary: _('Primary connection'),
      reserve: _('Reserve connection'),
      direct: _('Direct connection'),
      blocked: _('Traffic blocked'),
      'monitor-error': _('Availability check error'),
      unknown: _('State unavailable'),
    };
    async function refresh() {
      if (pending || current !== generation) return;
      pending = true;
      try {
        const result = await executeShellCommand({
          command: '/usr/bin/trafira',
          args: ['failure_policy_status'],
          timeout: 10000,
        });
        if (current !== generation) return;
        if (result.code) throw new Error('Status unavailable');
        const report = JSON.parse(result.stdout) as { guarded?: boolean };
        const rows = failurePolicyRows(report);
        host!.hidden = rows.length === 0 && !report.guarded;
        host!.replaceChildren(
          E('h3', {}, _('VPN failure policy')),
          ...(report.guarded
            ? [
                E(
                  'p',
                  { role: 'alert' },
                  _(
                    'A protective traffic block remains after a failed switch. Restart Trafira to recheck the configuration.',
                  ),
                ),
              ]
            : []),
          E('table', { class: 'table' }, [
            E('tr', {}, [
              E('th', {}, _('Section')),
              E('th', {}, _('Policy')),
              E('th', {}, _('State')),
              E('th', {}, _('Seconds since last switch')),
            ]),
            ...rows.map((row) =>
              E('tr', {}, [
                E('td', {}, row.section),
                E('td', {}, labels[row.policy]),
                E('td', {}, labels[row.state]),
                E(
                  'td',
                  {},
                  row.changedAgo === null ? '—' : String(row.changedAgo),
                ),
              ]),
            ),
          ]),
          E(
            'p',
            {},
            _(
              'Switching interrupts existing connections. Protection applies while Trafira is running.',
            ),
          ),
        );
      } catch {
        if (current === generation && !host!.hidden)
          host!.replaceChildren(E('p', {}, _('State unavailable')));
      } finally {
        pending = false;
      }
    }
    void refresh();
    timer = window.setInterval(() => void refresh(), 10000);
  },
  unmount() {
    generation++;
    window.clearInterval(timer);
    timer = 0;
  },
};
