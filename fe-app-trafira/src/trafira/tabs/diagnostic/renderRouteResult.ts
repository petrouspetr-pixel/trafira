import type {
  ExplainDecision,
  ExplainReport,
  PreparationProgress,
} from './routeExplanation';
import { routeError, routeOutcome, routeReasons } from './routePresentation';

function ruleDetails(decision: ExplainDecision) {
  const matches: Record<string, string> = {
    yes: _('Applies to this connection'),
    no: _('Does not apply'),
    unknown: _('Could not check this condition'),
  };
  const actions: Record<string, string> = {
    route: _('Select a connection'),
    reject: _('Block the connection'),
    sniff: _('Read the application protocol'),
    resolve: _('Look up the website address'),
    'route-options': _('Set connection parameters'),
    'hijack-dns': _('Send the DNS request to Trafira'),
  };
  return E('div', {}, [
    ...(decision.trace.length
      ? [
          E('table', { class: 'table' }, [
            E(
              'thead',
              {},
              E(
                'tr',
                {},
                [_('Rule'), _('Purpose'), _('Result')].map((text) =>
                  E('th', {}, text),
                ),
              ),
            ),
            E(
              'tbody',
              {},
              decision.trace.map((item) =>
                E('tr', { class: 'tr' }, [
                  E(
                    'td',
                    {},
                    `${item.index + 1}${item.origin?.section ? ` (${item.origin.section})` : ''}`,
                  ),
                  E(
                    'td',
                    {},
                    actions[item.action] || _('Other routing action'),
                  ),
                  E(
                    'td',
                    {},
                    item.shadowed
                      ? _('Not needed: an earlier rule already chose the route')
                      : matches[item.match],
                  ),
                ]),
              ),
            ),
          ]),
        ]
      : []),
    ...(decision.trace_truncated
      ? [E('p', {}, _('Only the first 200 rules are displayed'))]
      : []),
  ]);
}

export function renderRouteExplanationResult(
  report: ExplainReport | null,
  error: string,
  busy: boolean,
  progress?: PreparationProgress,
) {
  const submit = document.getElementById(
    'trafira-route-submit',
  ) as HTMLButtonElement | null;
  if (submit) submit.disabled = busy;
  const target = document.getElementById('trafira-route-explanation-result');
  if (!target) return;
  if (busy) {
    target.replaceChildren(
      E('div', { class: 'cbi-section', role: 'status' }, [
        E('p', { class: 'spinning' }, _('Checking routing. Please wait…')),
        E(
          'p',
          {},
          progress?.total
            ? _('Checking saved lists: %s of %s')
                .replace('%s', String(progress.completed))
                .replace('%s', String(progress.total))
            : _('Finding the website addresses and checking your settings.'),
        ),
        E(
          'p',
          { class: 'cbi-value-description' },
          _(
            'Lists are read from the router one at a time, without downloading them again.',
          ),
        ),
      ]),
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
  const unavailable = report.rule_sets?.unavailable_reasons || [];
  const reasons = routeReasons(report.decision.missing, unavailable).filter(
    (reason) => reason !== outcome.reason,
  );
  const dns = report.dns_query;
  const dnsFailed =
    dns?.status && !['resolved', 'provided'].includes(dns.status);
  const details = E(
    'details',
    { class: 'cbi-section fkp_diagnostic-details' },
    [
      E('summary', {}, _('Technical details')),
      E('h4', {}, _('How the routing rules were checked')),
      ruleDetails(report.decision),
      ...(report.destinations || [])
        .filter((_item) => report.destinations!.length > 1)
        .map((item) =>
          E('details', {}, [
            E('summary', {}, item.ip),
            ruleDetails(item.decision),
          ]),
        ),
      ...(report.dns_policy
        ? [
            E('h4', {}, _('DNS policy (A query)')),
            ...routeReasons(report.dns_policy.missing, unavailable)
              .filter((message) => !reasons.includes(message))
              .map((message) => E('p', {}, message)),
            ruleDetails(report.dns_policy),
          ]
        : []),
      E('p', {}, _('No DNS query was sent from the selected device.')),
      ...(report.selector
        ? [
            E(
              'p',
              {},
              `${_('Current selected node')}: ${report.selector.current}`,
            ),
          ]
        : []),
      ...(unavailable.length
        ? [
            E('details', {}, [
              E('summary', {}, _('Lists preventing a confirmed result')),
              ...unavailable
                .filter(
                  (item) =>
                    report.decision.missing.includes('rule_set:' + item.tag) ||
                    report.destinations?.some((destination) =>
                      destination.decision.missing.includes(
                        'rule_set:' + item.tag,
                      ),
                    ),
                )
                .map((item) =>
                  E(
                    'p',
                    {},
                    `${item.tag}: ${routeReasons(['rule_set:' + item.tag], [item]).join(' ')}`,
                  ),
                ),
            ]),
          ]
        : []),
      ...(report.rule_sets
        ? [
            E(
              'p',
              {},
              `${_('Lists available for calculation')}: ${report.rule_sets.available} · ${_('Reused from RAM')}: ${report.rule_sets.cached || 0}`,
            ),
          ]
        : []),
      ...(report.rule_sets?.basis === 'saved_snapshots'
        ? [
            E(
              'p',
              {},
              _(
                'Calculated using saved list copies. The running sing-box may have newer lists; this is a configuration check, not a live connection test.',
              ),
            ),
          ]
        : []),
      ...(report.generated_at
        ? [E('p', {}, new Date(report.generated_at * 1000).toLocaleString())]
        : []),
    ],
  );
  target.replaceChildren(
    E('div', { class: 'cbi-section' }, [
      E('h3', {}, outcome.title),
      E('p', {}, outcome.reason),
      ...(reasons.length
        ? [
            E(
              'div',
              {
                class:
                  report.decision.status === 'indeterminate'
                    ? 'alert-message warning'
                    : '',
              },
              reasons.map((reason) => E('p', {}, reason)),
            ),
          ]
        : []),
      ...(dnsFailed && !report.decision.missing.includes('dns_' + dns.status)
        ? routeReasons(['dns_' + dns.status]).map((message) =>
            E('p', { class: 'alert-message warning' }, message),
          )
        : []),
      ...((report.destinations?.length || 0) > 1
        ? [
            E('h4', {}, _('Results for the website server addresses')),
            E('table', { class: 'table' }, [
              E(
                'thead',
                {},
                E(
                  'tr',
                  {},
                  [_('Server IP'), _('Connection route')].map((title) =>
                    E('th', {}, title),
                  ),
                ),
              ),
              E(
                'tbody',
                {},
                report.destinations!.map((item) =>
                  E('tr', { class: 'tr' }, [
                    E('td', {}, item.ip),
                    E('td', {}, [
                      E(
                        'b',
                        {},
                        routeOutcome(item.decision, item.connection).title,
                      ),
                      ...routeReasons(item.decision.missing, unavailable).map(
                        (message) => E('p', {}, message),
                      ),
                    ]),
                  ]),
                ),
              ),
            ]),
          ]
        : dns?.addresses?.length
          ? [E('p', {}, `${_('Server IP')}: ${dns.addresses.join(', ')}`)]
          : []),
      ...(dns?.origin === 'trafira_main_dns' && dns.performed
        ? [
            E(
              'p',
              { class: 'cbi-value-description' },
              _(
                'Addresses were requested through the main DNS configured in Trafira. A device using its own DNS may receive different addresses.',
              ),
            ),
          ]
        : dns?.origin === 'manual'
          ? [
              E(
                'p',
                { class: 'cbi-value-description' },
                _(
                  'The check uses the server IP you entered. No DNS lookup was needed.',
                ),
              ),
            ]
          : []),
      E(
        'p',
        { class: 'cbi-value-description' },
        _(
          'This explains your routing settings. It does not test website availability or capture a real connection.',
        ),
      ),
    ]),
    details,
  );
}
