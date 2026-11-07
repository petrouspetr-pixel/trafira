import type { ExplainReport, PreparationProgress } from './routeExplanation';
import { routeError, routeOutcome, routeReasons } from './routePresentation';

export function renderRouteExplanationResult(
  report: ExplainReport | null,
  error: string,
  busy: boolean,
  _progress?: PreparationProgress,
) {
  const submit = document.getElementById(
    'trafira-route-submit',
  ) as HTMLButtonElement | null;
  if (submit) submit.disabled = busy;
  const target = document.getElementById('trafira-route-explanation-result');
  if (!target) return;
  if (busy) {
    target.replaceChildren(
      E(
        'p',
        { class: 'spinning', role: 'status' },
        _('Checking routing. Please wait…'),
      ),
    );
    return;
  }
  if (error) {
    target.replaceChildren(
      E('p', { class: 'alert-message warning' }, routeError(error)),
    );
    return;
  }
  if (!report) {
    target.replaceChildren();
    return;
  }

  const outcome = routeOutcome(report.decision, report.connection);
  const blocked = report.decision.status === 'blocked';
  const uncertain = report.decision.status === 'indeterminate';
  const missing = [...report.decision.missing];
  const dns = report.dns_query;
  // A DNS failure does not invalidate a domain rule that already blocks the site.
  if (!blocked && dns?.status && !['resolved', 'provided'].includes(dns.status))
    missing.push('dns_' + dns.status);
  const reasons = routeReasons(missing, report.rule_sets?.unavailable_reasons);
  const explanation =
    uncertain && reasons.length ? reasons.shift()! : outcome.reason;
  const destinations = report.destinations || [];
  const distinctRoutes =
    new Set(
      destinations.map((item) =>
        JSON.stringify([
          item.decision.status,
          item.decision.outbound || null,
          [...item.decision.missing].sort(),
        ]),
      ),
    ).size > 1;
  const addresses = [
    ...new Set([
      ...(dns?.addresses || []),
      ...destinations.map((item) => item.ip),
    ]),
  ];

  target.replaceChildren(
    E('div', { class: 'cbi-section' }, [
      E('h3', {}, outcome.title),
      E('p', {}, explanation),
      ...reasons
        .filter((reason) => reason !== explanation)
        .map((reason) => E('p', {}, reason)),
      ...(distinctRoutes
        ? [
            E('table', { class: 'table' }, [
              E(
                'thead',
                {},
                E('tr', { class: 'tr' }, [
                  E('th', { class: 'th', scope: 'col' }, _('Server IP')),
                  E('th', { class: 'th', scope: 'col' }, _('Connection route')),
                ]),
              ),
              E(
                'tbody',
                {},
                destinations.map((item) =>
                  E('tr', { class: 'tr' }, [
                    E('td', { class: 'td' }, item.ip),
                    E('td', { class: 'td' }, [
                      E(
                        'strong',
                        {},
                        routeOutcome(item.decision, item.connection).title,
                      ),
                      ...routeReasons(
                        item.decision.missing,
                        report.rule_sets?.unavailable_reasons,
                      ).map((reason) => E('p', {}, reason)),
                    ]),
                  ]),
                ),
              ),
            ]),
          ]
        : addresses.length
          ? [
              E('details', { class: 'fkp_diagnostic-details' }, [
                E('summary', {}, _('Website addresses')),
                E('p', {}, addresses.join(', ')),
                E(
                  'p',
                  { class: 'cbi-value-description' },
                  dns?.origin === 'manual'
                    ? _('Using the server address you entered.')
                    : _(
                        'Addresses were found through Trafira. A device using its own DNS may receive different addresses.',
                      ),
                ),
              ]),
            ]
          : []),
      E(
        'p',
        { class: 'cbi-value-description' },
        report.rule_sets?.basis === 'saved_snapshots'
          ? _(
              'Calculated from saved Trafira rules. This does not test whether the website opens.',
            )
          : _(
              'This shows the route in your current settings. It does not test whether the website opens.',
            ),
      ),
    ]),
  );
}
