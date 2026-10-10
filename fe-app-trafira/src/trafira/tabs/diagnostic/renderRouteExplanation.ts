import { executeShellCommand } from '../../../helpers/executeShellCommand';
import {
  ExplainDecision,
  ExplainReport,
  ExplainRequest,
  RouteExplanationController,
} from './routeExplanation';

async function command<T>(name: string, args: string[] = []): Promise<T> {
  const result = await executeShellCommand({
    command: '/usr/bin/trafira',
    args: [name, ...args],
    timeout: 15000,
  });
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
function decisionView(title: string, decision: ExplainDecision) {
  return E('div', {}, [
    E('b', {}, title),
    E(
      'p',
      {},
      `${status(decision.status)}${decision.outbound ? `: ${decision.outbound}` : ''}`,
    ),
    ...decision.missing.map((reason) =>
      E('p', {}, `${_('Missing information')}: ${reason}`),
    ),
    E('details', {}, [
      E('summary', {}, _('Rule evaluation order')),
      ...decision.trace.map((row) =>
        E(
          'p',
          {},
          `#${row.index + 1}: ${row.match} · ${row.action} · ${row.origin?.section || row.origin?.kind || '—'}${row.shadowed ? ` (${_('Overridden by an earlier rule')})` : ''}`,
        ),
      ),
      ...(decision.trace_truncated
        ? [E('p', {}, _('Only the first 200 rules are displayed'))]
        : []),
    ]),
  ]);
}
function render(report: ExplainReport | null, error: string, busy: boolean) {
  const result = document.getElementById('trafira-route-explanation-result');
  if (!result) return;
  result.replaceChildren(
    ...(busy
      ? [E('p', {}, _('Checking route'))]
      : error
        ? [E('p', {}, _('Could not explain route'))]
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
              decisionView(_('Connection route'), report.decision),
              ...(report.dns_policy
                ? [decisionView(_('DNS policy (A query)'), report.dns_policy)]
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
              E('p', {}, _('No DNS query was sent from the selected device.')),
              ...report.limitations.map((reason) =>
                E('p', {}, `${_('Limitations')}: ${reason}`),
              ),
            ]
          : []),
  );
}
const controller = new RouteExplanationController(
  (request) =>
    command<ExplainReport>('route_explain', [JSON.stringify(request)]),
  render,
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
    }) as HTMLInputElement;
    const source = E('select', {}, [
      E('option', { value: 'device' }, _('Device by IP address')),
      E('option', { value: 'router' }, _('This router')),
    ]) as HTMLSelectElement;
    const ip = E('input', {
      type: 'text',
      placeholder: _('Device IP address'),
    }) as HTMLInputElement;
    const mac = E('input', {
      type: 'text',
      placeholder: _('Device MAC (optional)'),
    }) as HTMLInputElement;
    const iface = E('input', {
      type: 'text',
      placeholder: _('Incoming interface (optional)'),
    }) as HTMLInputElement;
    const destination = E('input', {
      type: 'text',
      placeholder: _('Real destination IP (optional)'),
    }) as HTMLInputElement;
    const port = E('input', {
      type: 'number',
      min: '1',
      max: '65535',
      value: '443',
    }) as HTMLInputElement;
    const protocol = E('select', {}, [
      E('option', { value: 'tls' }, 'TLS / TCP'),
      E('option', { value: 'http' }, 'HTTP / TCP'),
      E('option', { value: 'quic' }, 'QUIC / UDP'),
      E('option', { value: 'tcp' }, _('TCP, unknown protocol')),
      E('option', { value: 'udp' }, _('UDP, unknown protocol')),
    ]) as HTMLSelectElement;
    let devices: Array<{ ip: string; mac?: string; interface?: string }> = [];
    source.addEventListener('change', () => {
      const device = devices[Number(source.value)];
      if (device) {
        ip.value = device.ip;
        mac.value = device.mac || '';
        iface.value = device.interface || '';
      }
      const router = source.value === 'router';
      ip.disabled = router;
      mac.disabled = router;
      iface.disabled = router;
    });
    const field = (label: string, control: HTMLElement) =>
      E('label', { class: 'fkp_diagnostic-field' }, [
        E('span', {}, label),
        control,
      ]);
    const form = E('form', { class: 'fkp_diagnostic-panel' }, [
      E('h3', {}, _('Where will the connection go?')),
      E('div', { class: 'fkp_diagnostic-fields' }, [
        field(_('Domain'), domain),
        field(_('Source'), source),
        field(_('Device IP address'), ip),
        field(_('Destination port'), port),
        field(_('Protocol'), protocol),
      ]),
      E('details', { class: 'fkp_diagnostic-details' }, [
        E('summary', {}, _('Additional route information (optional)')),
        E('div', { class: 'fkp_diagnostic-fields' }, [
          field(_('Device MAC (optional)'), mac),
          field(_('Incoming interface (optional)'), iface),
          field(_('Real destination IP (optional)'), destination),
        ]),
      ]),
      E('div', { class: 'fkp_diagnostic-actions' }, [
        E(
          'button',
          { type: 'submit', class: 'cbi-button cbi-button-action' },
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
        if (mac.value.trim()) request.source.mac = mac.value.trim();
        if (iface.value.trim()) request.source.interface = iface.value.trim();
      }
      if (destination.value.trim())
        request.destination_ip = destination.value.trim();
      if (['tls', 'http', 'quic'].includes(protocol.value))
        request.protocol = protocol.value;
      void controller.submit(request);
    });
    container.replaceChildren(
      form,
      E('div', { id: 'trafira-route-explanation-result' }),
    );
    controller.mount();
    void command<{
      devices: Array<{
        name?: string;
        ips: string[];
        mac?: string;
        interface?: string;
      }>;
    }>('get_alice_devices')
      .then((report) => {
        if (generation !== mountId) return;
        devices = [];
        for (const device of report.devices || [])
          for (const address of device.ips || []) {
            const index =
              devices.push({
                ip: address,
                mac: device.mac,
                interface: device.interface,
              }) - 1;
            source.append(
              E(
                'option',
                { value: String(index) },
                `${device.name || address} — ${address}`,
              ),
            );
          }
      })
      .catch(() => {
        /* Manual input remains available. */
      });
  },
  unmount() {
    mountId++;
    controller.unmount();
  },
};
