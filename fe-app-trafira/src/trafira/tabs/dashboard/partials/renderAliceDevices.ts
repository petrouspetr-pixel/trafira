import { Trafira } from '../../../types';
import {
  formatAliceDeviceDetails,
  formatHandshakeAge,
  getAliceDeviceAddress,
  getAliceDeviceLabel,
  getAliceMatchTag,
  groupAliceDevices,
  groupDevicesByInterface,
} from '../helpers/aliceDevices';

interface IRenderAliceDevicesProps {
  loading: boolean;
  failed: boolean;
  report: Trafira.GetAliceDevices | null;
  nowSeconds: number;
  expandedOffline: Partial<Record<Trafira.AliceDeviceStatus, boolean>>;
  onToggleOffline: (status: Trafira.AliceDeviceStatus, open: boolean) => void;
}

interface IRenderGroupContext {
  nowSeconds: number;
  expandedOffline: IRenderAliceDevicesProps['expandedOffline'];
  onToggleOffline: IRenderAliceDevicesProps['onToggleOffline'];
}

const BLOCK = 'fkp_dashboard-page__alice';

const GROUPS: Array<{
  status: Trafira.AliceDeviceStatus;
  title: () => string;
  hint: () => string;
}> = [
  {
    status: 'trafira',
    title: () => _('Via Trafira'),
    hint: () => _('Routing rules and fake DNS apply'),
  },
  {
    status: 'direct',
    title: () => _('Direct'),
    hint: () => _('Bypass Trafira; DNS returns real addresses'),
  },
  {
    status: 'mixed',
    title: () => _('Mixed routing'),
    hint: () => _('Some addresses use Trafira; others connect directly'),
  },
  {
    status: 'not_captured',
    title: () => _('Not captured'),
    hint: () => _('Interface is not in Source Network Interface'),
  },
];

function renderWarning(warning: Trafira.AliceWarning) {
  const messages: Record<Trafira.AliceWarning['code'], string> = {
    interface_not_captured: _(
      'Interface %s is in the device list but not selected in Source Network Interface, so its rule has no effect.',
    ).replace('%s', warning.value),
    empty_allow_list: _('The allow list is empty, so no devices use Trafira.'),
    neighbor_source_unavailable: _(
      'LAN device data is unavailable; LAN devices may be missing.',
    ),
    neighbor_source_partial: _(
      'Some LAN neighbor entries were invalid and skipped.',
    ),
    wireguard_source_unavailable: _(
      'WireGuard peer data is unavailable; peers may be missing.',
    ),
    wireguard_source_partial: _(
      'Some WireGuard peer entries were invalid and skipped.',
    ),
    dhcp_source_unavailable: _(
      'DHCP leases are unavailable; device names may be missing.',
    ),
    dhcp_source_partial: _('Some DHCP lease entries were invalid and skipped.'),
  };
  const text = messages[warning.code];

  return E('div', { class: `${BLOCK}__warning`, role: 'alert' }, text);
}

function renderHandshake(device: Trafira.AliceDevice, nowSeconds: number) {
  const handshake =
    device.kind === 'wireguard'
      ? formatHandshakeAge(device.last_handshake, nowSeconds)
      : '';

  return handshake
    ? E(
        'span',
        { title: _('Last WireGuard handshake') },
        _('%s ago').replace('%s', handshake),
      )
    : '';
}

function renderDevice(device: Trafira.AliceDevice, nowSeconds: number) {
  const tag = getAliceMatchTag(device.matched_by);

  return E(
    'li',
    { class: `${BLOCK}__device`, title: formatAliceDeviceDetails(device) },
    [
      E(
        'span',
        {
          class: `${BLOCK}__dot ${device.online ? `${BLOCK}__dot--online` : ''}`,
        },
        '',
      ),
      E(
        'span',
        { class: `${BLOCK}__device-name` },
        getAliceDeviceLabel(device),
      ),
      E(
        'span',
        { class: `${BLOCK}__device-address` },
        getAliceDeviceAddress(device),
      ),
      E('span', { class: `${BLOCK}__tag` }, tag),
      E(
        'span',
        { class: `${BLOCK}__device-activity` },
        renderHandshake(device, nowSeconds),
      ),
    ],
  );
}

function renderInterfaceBuckets(
  devices: Trafira.AliceDevice[],
  context: IRenderGroupContext,
) {
  return groupDevicesByInterface(devices).map((bucket) =>
    E('div', { class: `${BLOCK}__interface` }, [
      E('div', { class: `${BLOCK}__interface-name` }, bucket.name),
      E(
        'ul',
        { class: `${BLOCK}__devices` },
        bucket.devices.map((device) =>
          renderDevice(device, context.nowSeconds),
        ),
      ),
    ]),
  );
}

function renderGroup(
  group: (typeof GROUPS)[number],
  devices: Trafira.AliceDevice[],
  context: IRenderGroupContext,
) {
  const online = devices.filter((device) => device.online);
  const offline = devices.filter((device) => !device.online);
  const offlineOpen = Boolean(context.expandedOffline[group.status]);

  return E(
    'div',
    {
      class: `${BLOCK}__group ${BLOCK}__group--${group.status}`,
      title: group.hint(),
    },
    [
      E('div', { class: `${BLOCK}__group-title` }, [
        E('b', {}, group.title()),
        E(
          'span',
          { class: `${BLOCK}__group-count` },
          _('%d of %d online')
            .replace('%d', String(online.length))
            .replace('%d', String(devices.length)),
        ),
      ]),
      ...renderInterfaceBuckets(online, context),
      ...(offline.length
        ? [
            E(
              'details',
              {
                class: `${BLOCK}__offline`,
                ...(offlineOpen ? { open: true } : {}),
                toggle: (event: Event) =>
                  context.onToggleOffline(
                    group.status,
                    (event.target as HTMLDetailsElement).open,
                  ),
              },
              [
                E(
                  'summary',
                  { class: `${BLOCK}__offline-summary` },
                  _('Offline: %d').replace('%d', String(offline.length)),
                ),
                ...renderInterfaceBuckets(offline, context),
              ],
            ),
          ]
        : []),
      ...(devices.length
        ? []
        : [E('div', { class: `${BLOCK}__empty` }, _('No devices'))]),
    ],
  );
}

export function renderAliceDevices({
  loading,
  failed,
  report,
  nowSeconds,
  expandedOffline,
  onToggleOffline,
}: IRenderAliceDevicesProps) {
  if (loading || (report && (!report.enabled || !report.dashboard_visible))) {
    return E('div', { class: `${BLOCK} ${BLOCK}--hidden` }, '');
  }

  if (failed || !report?.enabled) {
    return E(
      'div',
      { class: `${BLOCK} ${BLOCK}--failed` },
      _('Device routing information is currently unavailable'),
    );
  }

  const groups = groupAliceDevices(report.devices);
  const visibleGroups = GROUPS.filter(
    (group) =>
      (group.status !== 'not_captured' && group.status !== 'mixed') ||
      groups[group.status].length,
  );

  return E('div', { class: BLOCK }, [
    E('div', { class: `${BLOCK}__header` }, [
      E('b', { class: `${BLOCK}__title` }, _('Device routing')),
    ]),
    ...report.warnings.map(renderWarning),
    E(
      'div',
      { class: `${BLOCK}__groups` },
      visibleGroups.map((group) =>
        renderGroup(group, groups[group.status], {
          nowSeconds,
          expandedOffline,
          onToggleOffline,
        }),
      ),
    ),
  ]);
}
