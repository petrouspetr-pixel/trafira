import { nativeChoice } from '../../helpers/nativeChoice';
import { renderConfigurationRow as row } from '../../helpers/renderConfigurationRow';
import { executeShellCommand } from '../../../helpers/executeShellCommand';
import {
  ExplainDecision,
  ExplainReport,
  ExplainRequest,
  parseRouteExplanationResult,
  RouteExplanationController,
  PreparationProgress,
  RouteJobStatus,
  parseRouteJobCommandResult,
  runRoutePreparation,
} from './routeExplanation';
import { routeError, routeReasons } from './routePresentation';

async function command<T>(name: string, args: string[] = []): Promise<T> {
  const result = await executeShellCommand({
    command: '/usr/bin/trafira',
    args: [name, ...args],
    timeout: 15000,
  });
  if (name === 'route_explain') return parseRouteExplanationResult(result) as T;
  if (name === 'route_explain_start' || name === 'route_explain_status')
    return parseRouteJobCommandResult(result) as T;
  if (result.code) throw new Error('Route command failed');
  return JSON.parse(result.stdout) as T;
}
function status(value: ExplainDecision['status']) {
  return {
    matched: _('Matched route'),
    direct: _('Direct connection'),
    blocked: _('Blocked'),
    indeterminate: _('Insufficient information'),
  }[value];
}
function decisionView(
  title: string,
  decision: ExplainDecision,
  unavailable: Array<{ tag: string; reason: string }> = [],
) {
  const matches: Record<string, string> = {
    yes: _('Matches'),
    no: _('Does not match'),
    unknown: _('Needs more information'),
  };
  const actions: Record<string, string> = {
    route: _('Route connection'),
    reject: _('Block connection'),
    sniff: _('Detect protocol'),
    resolve: _('Resolve domain'),
    'route-options': _('Connection options'),
    'hijack-dns': _('Handle DNS'),
  };
  return E(
    'div',
    { class: `fkp_route-decision fkp_route-decision--${decision.status}` },
    [
      E('b', {}, title),
      E(
        'p',
        {},
        `${status(decision.status)}${decision.outbound ? `: ${decision.outbound}` : ''}`,
      ),
      ...routeReasons(decision.missing, unavailable).map((reason) =>
        E('p', {}, reason),
      ),
      ...(unavailable.some((item) =>
        decision.missing.includes('rule_set:' + item.tag),
      )
        ? [
            E('details', { class: 'fkp_diagnostic-details' }, [
              E('summary', {}, _('Lists preventing a confirmed result')),
              ...unavailable
                .filter((item) =>
                  decision.missing.includes('rule_set:' + item.tag),
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
      ...(decision.trace.length
        ? [
            E('details', { class: 'fkp_diagnostic-details' }, [
              E('summary', {}, _('Rule evaluation order')),
              ...decision.trace.map((row) =>
                E(
                  'p',
                  {},
                  `#${row.index + 1}: ${matches[row.match] || _('Needs more information')} · ${actions[row.action] || _('Rule action')}${row.origin?.section ? ` · ${row.origin.section}` : ''}${row.shadowed ? ` (${_('Overridden by an earlier rule')})` : ''}`,
                ),
              ),
              ...(decision.trace_truncated
                ? [E('p', {}, _('Only the first 200 rules are displayed'))]
                : []),
            ]),
          ]
        : []),
    ],
  );
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
  const result = document.getElementById('trafira-route-explanation-result');
  if (!result) return;
  result.replaceChildren(
    ...(busy
      ? [
          E(
            'p',
            { role: 'status' },
            progress?.phase === 'evaluating'
              ? _('Calculating route from prepared lists')
              : progress?.total
                ? `${_('Preparing rule sets')}: ${progress.completed} / ${progress.total}`
                : _('Starting route analysis'),
          ),
          E(
            'p',
            {},
            _(
              'The first check prepares saved lists and may take longer. Verified exports are reused from RAM until a list or sing-box changes.',
            ),
          ),
        ]
      : error
        ? [E('p', { class: 'alert-message warning' }, routeError(error))]
        : report
          ? [
              E(
                'p',
                {},
                _(
                  'Analysis of the applied configuration, not a live connection capture.',
                ),
              ),
              ...(report.generated_at
                ? [
                    E(
                      'p',
                      {},
                      new Date(report.generated_at * 1000).toLocaleString(),
                    ),
                  ]
                : []),
              ...(report.rule_sets?.basis === 'saved_snapshots'
                ? [
                    E(
                      'p',
                      { class: 'fkp_route-basis' },
                      _(
                        'Calculated using saved list copies. The running sing-box may have newer lists; this is a configuration check, not a live connection test.',
                      ),
                    ),
                  ]
                : []),
              ...(report.decision.status === 'indeterminate'
                ? [
                    E(
                      'p',
                      { class: 'alert-message notice' },
                      _(
                        'The request completed, but the route cannot be confirmed with the available data. This is not a website availability failure. See the reasons below.',
                      ),
                    ),
                  ]
                : []),
              ...(report.decision.status === 'indeterminate' &&
              report.decision.missing.some((reason) =>
                reason.startsWith('rule_set:'),
              ) &&
              report.rule_sets?.unavailable_reasons?.some(
                (item) =>
                  item.reason === 'limit' &&
                  report.decision.missing.includes('rule_set:' + item.tag),
              )
                ? [
                    E(
                      'p',
                      {},
                      _(
                        'Some required lists could not be analyzed within the diagnostic limits. Device selection cannot remove this limitation.',
                      ),
                    ),
                  ]
                : []),
              ...(report.rule_sets?.cached != null
                ? [
                    E(
                      'p',
                      {},
                      `${_('Lists available for calculation')}: ${report.rule_sets.available} / ${report.rule_sets.available + report.rule_sets.unavailable} · ${_('Reused from RAM')}: ${report.rule_sets.cached}`,
                    ),
                  ]
                : []),
              decisionView(
                _('Connection route'),
                report.decision,
                report.rule_sets?.unavailable_reasons,
              ),
              ...(report.dns_policy
                ? [
                    E('details', { class: 'fkp_diagnostic-details' }, [
                      E('summary', {}, _('DNS policy (A query)')),
                      decisionView(
                        _('DNS policy (A query)'),
                        report.dns_policy,
                        report.rule_sets?.unavailable_reasons,
                      ),
                      E(
                        'p',
                        {},
                        _('No DNS query was sent from the selected device.'),
                      ),
                    ]),
                  ]
                : []),
              ...(report.selector
                ? [
                    E(
                      'p',
                      {},
                      `${_('Current selected node')}: ${report.selector.current}`,
                    ),
                  ]
                : []),
            ]
          : []),
  );
}
const controller = new RouteExplanationController(
  (request, progress, active) =>
    runRoutePreparation(
      (name, args) => command<RouteJobStatus>(name, args),
      request,
      progress || (() => {}),
      active || (() => true),
    ),
  renderRouteExplanationResult,
);
let mountId = 0;
export const routeExplanationPanel = {
  mount() {
    const generation = ++mountId;
    const container = document.getElementById('trafira-route-explanation');
    if (!container) return;
    const domain = E('input', {
      type: 'text',
      placeholder: 'example.com',
      maxLength: 253,
      required: true,
    }) as HTMLInputElement;
    const source = nativeChoice('trafira-route-source', _('Source'), 'device', {
      device: _('Device by IP address'),
      router: _('This router'),
    });
    const ip = nativeChoice(
      'trafira-route-device',
      _('Device IP address'),
      '',
      {},
      true,
      'ipaddr',
    );
    const mac = nativeChoice(
      'trafira-route-mac',
      _('Device MAC (optional)'),
      '',
      {},
      true,
      'macaddr',
    );
    const iface = nativeChoice(
      'trafira-route-interface',
      _('Incoming interface (optional)'),
      '',
      {},
      true,
    );
    const deviceStatus = E(
      'p',
      { role: 'status', class: 'cbi-value-description' },
      _('Loading detected devices'),
    );
    const refreshDevices = E(
      'button',
      { type: 'button', class: 'cbi-button' },
      _('Refresh devices'),
    );
    const destination = E('input', {
      id: 'trafira-route-destination',
      type: 'text',
      placeholder: _('Real destination IP (optional)'),
    }) as HTMLInputElement;
    const destinationLabel = E('span', {}, _('Real destination IP (optional)'));
    const sourceHelp = E(
      'p',
      { id: 'trafira-route-source-help', class: 'cbi-value-description' },
      _(
        'For a phone or PC, select its detected address or enter its LAN IP. If needed, enter the incoming interface (usually br-lan) below.',
      ),
    );
    const destinationHelp = E(
      'p',
      { class: 'cbi-value-description' },
      _(
        'You can start with the domain only. If an earlier rule checks IP addresses, also enter the real destination IP. FakeIP addresses cannot be used for this check.',
      ),
    );
    const port = E('input', {
      type: 'number',
      min: '1',
      max: '65535',
      value: '443',
      required: true,
    }) as HTMLInputElement;
    const protocol = nativeChoice(
      'trafira-route-protocol',
      _('Protocol'),
      'tls',
      {
        tls: 'TLS / TCP',
        http: 'HTTP / TCP',
        quic: 'QUIC / UDP',
        tcp: _('TCP, unknown protocol'),
        udp: _('UDP, unknown protocol'),
      },
    );
    let devices: Array<{ ip: string; mac?: string; interface?: string }> = [];
    const updateSource = () => {
      const router = source.value === 'router';
      ip.setDisabled(router);
      mac.setDisabled(router);
      iface.setDisabled(router);
      deviceField.hidden = router;
      metadataFields.hidden = router;
      destination.required = router;
      destinationLabel.textContent = router
        ? _('Real destination IP (required for the router)')
        : _('Real destination IP (optional)');
      destination.placeholder = destinationLabel.textContent || '';
      sourceHelp.textContent = router
        ? _(
            'This source is for applications running on the router, not for your phone or PC. Router application routing must be enabled and applied in Settings.',
          )
        : _(
            'For a phone or PC, select its detected address or enter its LAN IP. If needed, enter the incoming interface (usually br-lan) below.',
          );
      destinationHelp.textContent = router
        ? _(
            'Enter the actual server IP for this domain from the connection you want to check. This tool does not resolve the domain automatically; DNS may return several addresses. Do not use a FakeIP address.',
          )
        : _(
            'You can start with the domain only. If an earlier rule checks IP addresses, also enter the real destination IP. FakeIP addresses cannot be used for this check.',
          );
    };
    source.onChange(updateSource);
    ip.onChange(() => {
      const device = devices.find((device) => device.ip === ip.value);
      mac.value = device?.mac || '';
      iface.value = device?.interface || '';
    });
    const field = (label: string, control: HTMLElement) =>
      row(label, control.id, [control]);
    const deviceField = row(
      _('Device IP address'),
      ip.node.id,
      [ip.node, refreshDevices],
      deviceStatus,
    );
    deviceField.id = 'trafira-route-device-row';
    const metadataFields = E('details', { class: 'fkp_diagnostic-details' }, [
      E('summary', {}, _('Device MAC and incoming interface (if needed)')),
      field(_('Device MAC (optional)'), mac.node),
      field(_('Incoming interface (optional)'), iface.node),
    ]);
    const form = E('form', { class: 'cbi-section' }, [
      E('h3', {}, _('Where will the connection go?')),
      E(
        'p',
        { class: 'cbi-section-descr' },
        _(
          'Check which Trafira rule applies to a connection. This does not test whether the website opens and does not send traffic from the selected device.',
        ),
      ),
      E('div', {}, [
        field(_('Domain'), domain),
        row(_('Source'), source.node.id, [source.node], sourceHelp),
        deviceField,
        field(_('Destination port'), port),
        field(_('Protocol'), protocol.node),
        row(destinationLabel, destination.id, [destination], destinationHelp),
      ]),
      metadataFields,
      E('div', { class: 'fkp_diagnostic-actions' }, [
        E(
          'button',
          {
            id: 'trafira-route-submit',
            type: 'submit',
            class: 'cbi-button cbi-button-action',
          },
          _('Explain route'),
        ),
      ]),
    ]);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      const kind = source.value === 'router' ? 'router' : 'device';
      const request: ExplainRequest = {
        domain: domain.value.trim(),
        source: { kind },
        port: Number(port.value),
        network:
          protocol.value === 'quic' || protocol.value === 'udp' ? 'udp' : 'tcp',
      };
      if (kind === 'device') {
        request.source.ip = ip.value.trim();
        const detected = devices.find(
          (device) => device.ip === request.source.ip,
        );
        const deviceMac = mac.value.trim() || detected?.mac;
        const deviceInterface = iface.value.trim() || detected?.interface;
        if (deviceMac) request.source.mac = deviceMac;
        if (deviceInterface) request.source.interface = deviceInterface;
      }
      if (destination.value.trim())
        request.destination_ip = destination.value.trim();
      if (['tls', 'http', 'quic'].includes(protocol.value))
        request.protocol = protocol.value;
      void controller.submit(request);
    });
    container.replaceChildren(
      form,
      E('div', {
        id: 'trafira-route-explanation-result',
        role: 'status',
        'aria-live': 'polite',
      }),
    );
    controller.mount();
    const loadDevices = () => {
      refreshDevices.disabled = true;
      deviceStatus.textContent = _('Loading detected devices');
      return command<{
        source_interfaces?: string[];
        available_interfaces?: string[];
        devices: Array<{
          name?: string;
          ips: string[];
          mac?: string;
          interface?: string;
        }>;
      }>('get_known_devices')
        .then((report) => {
          if (generation !== mountId) return;
          devices = [];
          const ipChoices: Record<string, string> = {},
            macChoices: Record<string, string> = {},
            interfaceChoices: Record<string, string> = {};
          for (const name of [
            ...(report.available_interfaces || []),
            ...(report.source_interfaces || []),
          ])
            interfaceChoices[name] = name;
          for (const device of report.devices || []) {
            const label = device.name || device.mac || '';
            if (device.mac)
              macChoices[device.mac] = label
                ? `${label} — ${device.mac}`
                : device.mac;
            if (device.interface)
              interfaceChoices[device.interface] = device.interface;
            for (const address of device.ips || []) {
              devices.push({
                ip: address,
                mac: device.mac,
                interface: device.interface,
              });
              ipChoices[address] = label ? `${label} — ${address}` : address;
            }
          }
          ip.setChoices(ipChoices);
          mac.setChoices(macChoices);
          iface.setChoices(interfaceChoices);
          deviceStatus.textContent = devices.length
            ? _(
                'Select a device to fill its IP, MAC and incoming interface. You can also enter them manually.',
              )
            : _(
                'No detected devices. Enter the address manually or refresh the list.',
              );
        })
        .catch(() => {
          if (generation === mountId)
            deviceStatus.textContent = _(
              'Could not load detected devices. Enter the address manually or refresh the list.',
            );
        })
        .finally(() => {
          if (generation === mountId) refreshDevices.disabled = false;
        });
    };
    refreshDevices.addEventListener('click', () => {
      void loadDevices();
    });
    void loadDevices();
  },
  unmount() {
    mountId++;
    controller.unmount();
  },
};
