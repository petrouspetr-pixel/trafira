import { nativeChoice } from '../../helpers/nativeChoice';
import { renderConfigurationRow as row } from '../../helpers/renderConfigurationRow';
import { executeShellCommand } from '../../../helpers/executeShellCommand';
import {
  pendingRoute,
  savePendingRoute,
  clearPendingRoute,
  pendingRouteId,
  savePendingRouteId,
} from './routePending';
import {
  ExplainRequest,
  parseRouteExplanationResult,
  RouteExplanationController,
  RouteJobStatus,
  parseRouteJobCommandResult,
  runRoutePreparation,
} from './routeExplanation';

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
import { renderRouteExplanationResult } from './renderRouteResult';
export { renderRouteExplanationResult } from './renderRouteResult';
let updateFormBusy: ((busy: boolean) => void) | null = null;
const controller = new RouteExplanationController(
  async (request, progress, active) => {
    savePendingRoute(request);
    try {
      const report = await runRoutePreparation(
        async (name, args) => {
          const state = await command<RouteJobStatus>(name, args);
          savePendingRouteId(request, state.job_id);
          return state;
        },
        request,
        progress || (() => {}),
        active || (() => true),
        undefined,
        pendingRouteId(request),
      );
      clearPendingRoute(request);
      return report;
    } catch (error) {
      // Preserve transport failures for refresh/retry; final server failures
      // must not silently auto-run again when the page next opens.
      if (
        error instanceof Error &&
        !['timeout', 'rpc_failed', 'Route view no longer active'].includes(
          error.message,
        )
      )
        clearPendingRoute(request);
      throw error;
    }
  },
  (report, error, busy, progress) => {
    updateFormBusy?.(busy);
    renderRouteExplanationResult(report, error, busy, progress);
  },
);
let mountId = 0;
export const routeExplanationPanel = {
  mount() {
    const generation = ++mountId;
    const container = document.getElementById('trafira-route-explanation');
    if (!container) return;
    const domain = E('input', {
      id: 'trafira-route-domain',
      type: 'text',
      placeholder: 'example.com',
      maxLength: 253,
      required: true,
    }) as HTMLInputElement;
    const source = nativeChoice(
      'trafira-route-source',
      _('Source'),
      'device',
      {
        device: _('Phone or computer'),
        router: _('This router'),
      },
      false,
      undefined,
      true,
    );
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
      placeholder: _('Determined automatically'),
    }) as HTMLInputElement;
    const destinationLabel = E('span', {}, _('Server IP (optional override)'));
    const sourceHelp = E(
      'p',
      { id: 'trafira-route-source-help', class: 'cbi-value-description' },
      _('Choose the device that will open the website.'),
    );
    const destinationHelp = E(
      'p',
      { class: 'cbi-value-description' },
      _(
        'Leave empty to find the server addresses through Trafira DNS. Enter an IP only to check a particular server.',
      ),
    );
    const port = E('input', {
      id: 'trafira-route-port',
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
        bittorrent: 'BitTorrent / TCP',
        tcp: _('TCP, unknown protocol'),
        udp: _('UDP, unknown protocol'),
      },
      false,
      undefined,
      true,
    );
    let manualPort = false;
    const preservePort = () => {
      manualPort = true;
    };
    port.addEventListener('input', preservePort);
    port.addEventListener('change', preservePort);
    protocol.onChange(() => {
      if (manualPort) return;
      const standardPorts: Record<string, string> = {
        http: '80',
        tls: '443',
        quic: '443',
      };
      const standard = standardPorts[protocol.value];
      if (standard) port.value = standard;
    });
    let devices: Array<{ ip: string; mac?: string; interface?: string }> = [];
    const updateSource = () => {
      const router = source.value === 'router';
      ip.setDisabled(router);
      mac.setDisabled(router);
      iface.setDisabled(router);
      deviceField.hidden = router;
      metadataFields.hidden = router;
      destination.required = false;
      destinationLabel.textContent = _('Server IP (optional override)');
      destination.placeholder = _('Determined automatically');
      sourceHelp.textContent = router
        ? _(
            'This checks apps running on the router itself. Device traffic is checked separately.',
          )
        : _('Choose the device that will open the website.');
      sourceHelp.hidden = !router;
      destinationHelp.textContent = _(
        'Leave empty to find the server addresses through Trafira DNS. Enter an IP only to check a particular server.',
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
    const advanced = E(
      'details',
      { id: 'trafira-route-advanced', class: 'fkp_diagnostic-details' },
      [
        E('summary', {}, _('Additional settings')),
        field(_('Destination port'), port),
        field(_('Protocol'), protocol.node),
        row(destinationLabel, destination.id, [destination], destinationHelp),
        metadataFields,
      ],
    );
    const form = E('form', { class: 'cbi-section' }, [
      E(
        'p',
        { class: 'cbi-section-descr' },
        _(
          'Choose a device and enter a website, for example ya.ru. We will find its server addresses and explain how Trafira would route the connection. This does not open the website or change your settings.',
        ),
      ),
      E('div', {}, [
        row(_('Source'), source.node.id, [source.node], sourceHelp),
        deviceField,
        field(_('Website'), domain),
      ]),
      advanced,
      E('div', { class: 'fkp_diagnostic-actions' }, [
        E(
          'button',
          {
            id: 'trafira-route-submit',
            type: 'submit',
            class: 'cbi-button cbi-button-action',
          },
          _('Check routing'),
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
      if (['tls', 'http', 'quic', 'bittorrent'].includes(protocol.value))
        request.protocol = protocol.value;
      void controller.submit(request);
    });
    // Do not leave a previous website's answer under an edited request.
    for (const event of ['input', 'change', 'cbi-dropdown-change'])
      form.addEventListener(event, () => {
        document
          .getElementById('trafira-route-explanation-result')
          ?.replaceChildren();
      });
    container.replaceChildren(
      form,
      E('div', {
        id: 'trafira-route-explanation-result',
        role: 'status',
        'aria-live': 'polite',
      }),
    );
    updateSource();
    let routeBusy = false,
      loadingDevices = false;
    updateFormBusy = (busy) => {
      routeBusy = busy;
      const router = source.value === 'router';
      domain.disabled = destination.disabled = port.disabled = busy;
      source.setDisabled(busy);
      protocol.setDisabled(busy);
      ip.setDisabled(busy || router || loadingDevices);
      mac.setDisabled(busy || router || loadingDevices);
      iface.setDisabled(busy || router || loadingDevices);
      refreshDevices.disabled = busy || loadingDevices;
      form.setAttribute('aria-busy', String(busy));
    };
    controller.mount();
    const loadDevices = () => {
      loadingDevices = true;
      updateFormBusy?.(routeBusy);
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
            ? _('Select a device from the list, or enter its local IP address.')
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
          if (generation === mountId) {
            loadingDevices = false;
            updateFormBusy?.(routeBusy);
          }
        });
    };
    refreshDevices.addEventListener('click', () => {
      void loadDevices();
    });
    const pending = pendingRoute();
    if (pending) updateFormBusy(true);
    void loadDevices().then(() => {
      if (!pending || generation !== mountId) return;
      source.value = pending.source.kind;
      ip.value = pending.source.ip || '';
      mac.value = pending.source.mac || '';
      iface.value = pending.source.interface || '';
      domain.value = pending.domain;
      destination.value = pending.destination_ip || '';
      // A restored request must keep its exact port, including a standard one.
      manualPort = true;
      port.value = String(pending.port);
      protocol.value = pending.protocol || pending.network;
      updateSource();
      void controller.submit(pending);
    });
  },
  unmount() {
    mountId++;
    updateFormBusy = null;
    controller.unmount();
  },
};
