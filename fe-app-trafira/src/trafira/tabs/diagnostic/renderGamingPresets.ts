import { renderConfigurationRow as row } from '../../helpers/renderConfigurationRow';
import { confirmAction } from '../../helpers/configurationSync';
import {
  gamingCommand,
  gamingDraft,
} from '../configuration/gamingDraft.service';
import type {
  GamingOperation,
  GamingSection,
} from '../configuration/gamingDraft';

interface Device {
  name: string;
  interface: string;
  mac: string;
  ips: string[];
}
interface Catalog {
  devices: Device[];
  presets: Array<{ id: string }>;
}
interface Owner {
  owner: string;
  platform: string;
  addresses: string[];
  connection: string;
  placement: string;
  edited: boolean;
}
const platformName = (id: string) =>
  (
    ({
      steam: 'Steam',
      playstation: 'PlayStation',
      xbox: 'Xbox',
      epic: 'Epic Games',
    }) as Record<string, string>
  )[id] || id;
const strings = (value: unknown): string[] =>
  Array.isArray(value)
    ? value.filter((v): v is string => typeof v === 'string')
    : [];
function owners(sections: GamingSection[]) {
  const result = new Map<string, Owner>();
  for (const section of sections) {
    const key = String(section.preset_owner || '');
    if (!key) continue;
    const owner = result.get(key) || {
      owner: key,
      platform: String(section.preset_platform || ''),
      addresses: [],
      connection: '',
      placement: String(section.preset_placement || 'after-device-routes'),
      edited: false,
    };
    owner.addresses = [
      ...new Set([
        ...owner.addresses,
        ...strings(section.source_ip_cidr),
        ...strings(section.fully_routed_ips),
      ]),
    ];
    if (section.outbound_detour_section)
      owner.connection = String(section.outbound_detour_section);
    const clean: GamingSection = {};
    for (const field of Object.keys(section).sort()) {
      if (field.startsWith('.') || field.startsWith('preset_')) continue;
      const value = section[field];
      if (Array.isArray(value) && !value.length) continue;
      const scalar = (v: unknown) =>
        v === true ? '1' : v === false ? '0' : String(v);
      clean[field] = Array.isArray(value) ? value.map(scalar) : scalar(value);
    }
    try {
      owner.edited ||=
        JSON.stringify(JSON.parse(String(section.preset_original_digest))) !==
        JSON.stringify(clean);
    } catch {
      owner.edited = true;
    }
    result.set(key, owner);
  }
  const manual = sections.findIndex(
    (s) => s['.type'] === 'section' && !s.preset_owner,
  );
  for (const item of result.values()) {
    const identity = item.owner.replace(
      /^game_(steam|playstation|xbox|epic)_/,
      '',
    );
    const first = sections.findIndex(
      (s) =>
        typeof s.preset_owner === 'string' &&
        s.preset_owner.replace(/^game_(steam|playstation|xbox|epic)_/, '') ===
          identity,
    );
    item.placement =
      manual < 0 || first < manual
        ? 'before-device-routes'
        : 'after-device-routes';
  }
  return [...result.values()];
}
export function gamingErrorMessage(code: string) {
  const messages: Record<string, string> = {
    alice_bypass: _(
      'Device routing bypasses this device. Explicitly enable its selected addresses before applying.',
    ),
    alice_broad_bypass: _(
      'This device routing exception also covers other devices. Edit it manually before applying this preset.',
    ),
    preset_edited: _(
      'These rules were edited. Confirm replacement or keep them as ordinary rules.',
    ),
    unknown_device: _(
      'The selected address is no longer known. Refresh the device list.',
    ),
    invalid_proxy: _('Select an enabled connection rule.'),
    busy: _('Another configuration operation is already running.'),
    draft_unavailable: _('Reload the page before editing gaming presets.'),
    incomplete_editor: _(
      'Choose a platform, device addresses and connection, or cancel editing before saving.',
    ),
    editor_cancelled: _(
      'Editing was cancelled. Your changes have not been saved.',
    ),
    permission_denied: _(
      'You do not have permission to change these settings.',
    ),
    invalid_request: _(
      'The gaming draft could not be processed. Reduce the number of pending changes and try again.',
    ),
  };
  return (
    messages[code] ||
    _('The operation failed. Refresh the page and review the settings.')
  );
}
let mounted: {
  host: HTMLElement;
  activate: (canWrite: boolean) => void;
  dispose: () => void;
} | null = null;
export const gamingPresetsPanel = {
  mount(canWrite = true) {
    const host = document.getElementById('trafira-gaming-presets');
    if (!host) return;
    if (mounted?.host === host) {
      mounted.activate(canWrite);
      return;
    }
    mounted?.dispose();
    let disposed = false,
      loading = false,
      refreshPending = true,
      dirty = false,
      editing: Owner | null = null;
    let catalog: Catalog | null = null,
      epoch = gamingDraft.epoch;
    const platform = E('select', {
      id: 'trafira-game-platform',
      class: 'cbi-input-select',
    }) as HTMLSelectElement;
    const device = E('select', {
      id: 'trafira-game-device',
      class: 'cbi-input-select',
    }) as HTMLSelectElement;
    const proxy = E('select', {
      id: 'trafira-game-proxy',
      class: 'cbi-input-select',
    }) as HTMLSelectElement;
    const placement = E(
      'select',
      { id: 'trafira-game-priority', class: 'cbi-input-select' },
      [
        E(
          'option',
          { value: 'after-device-routes' },
          _('After existing device rules'),
        ),
        E(
          'option',
          { value: 'before-device-routes' },
          _('Before existing device rules'),
        ),
      ],
    ) as HTMLSelectElement;
    const addresses = E('div', { class: 'trafira-form-controls' });
    const enable = E('input', { type: 'checkbox' }) as HTMLInputElement;
    const status = E('p', { role: 'status', 'aria-live': 'polite' });
    const error = E('p', {
      role: 'alert',
      class: 'alert-message error hidden',
    });
    const existing = E('div', {}),
      heading = E('h4', {}, _('Add a gaming preset'));
    function button(label: string, click: () => void, danger = false) {
      return E(
        'button',
        {
          type: 'button',
          class: danger
            ? 'cbi-button cbi-button-remove'
            : 'cbi-button cbi-button-action',
          click,
        },
        label,
      ) as HTMLButtonElement;
    }
    const cancel = button(_('Cancel editing'), () => resetEditor());
    const add = button(_('Add to list'), () => {
      void submit().catch(showError);
    });
    function showError(cause: unknown) {
      error.textContent = gamingErrorMessage(
        cause instanceof Error ? cause.message : 'request_failed',
      );
      error.className = 'alert-message error';
    }
    function selectedAddresses() {
      return Array.from(
        addresses.querySelectorAll<HTMLInputElement>('input:checked'),
      ).map((input) => input.value);
    }
    function ready() {
      return Boolean(
        platform.value &&
          device.value !== '' &&
          proxy.value &&
          selectedAddresses().length,
      );
    }
    function resetEditor() {
      dirty = false;
      editing = null;
      platform.value = '';
      device.value = '';
      addresses.replaceChildren();
      enable.checked = false;
      error.className = 'hidden';
      update();
    }
    function showAddresses(selected?: string[]) {
      addresses.replaceChildren();
      const entry =
        device.value === '' ? null : catalog?.devices[Number(device.value)];
      if (entry && catalog) {
        const values = [
          ...new Set(
            catalog.devices
              .filter(
                (d) => d.mac === entry.mac && d.interface === entry.interface,
              )
              .flatMap((d) => d.ips),
          ),
        ];
        for (const address of values) {
          const input = E('input', {
            type: 'checkbox',
            value: address,
          }) as HTMLInputElement;
          input.checked = selected
            ? selected.some((s) => s.split('/')[0] === address)
            : entry.ips.includes(address);
          input.addEventListener('change', () => {
            dirty = true;
            update();
          });
          addresses.append(E('label', {}, [input, ' ' + address]));
        }
      }
      update();
    }
    async function submit() {
      if (!dirty) return;
      if (!canWrite) throw Error('permission_denied');
      if (!ready()) throw Error('incomplete_editor');
      if (
        editing?.edited &&
        !(await confirmAction(
          _('Replace edited preset'),
          _(
            'This preset was changed manually in Sections. Replacement rebuilds its rules from the selected settings and discards your manual edits to these rules. Other presets and ordinary sections are kept. The replacement takes effect only after Save & Apply.',
          ),
          _('Replace'),
        ))
      )
        throw Error('editor_cancelled');
      await gamingDraft.stage({
        action: 'upsert',
        preset: platform.value,
        device_ips: selectedAddresses(),
        proxy_section: proxy.value,
        placement: placement.value,
        enable_device: enable.checked,
        replace_edited: Boolean(editing?.edited),
      });
      resetEditor();
    }
    async function remove(owner: Owner, keep = false) {
      if (!canWrite || gamingDraft.busy) return;
      if (
        owner.edited &&
        !(await confirmAction(
          keep ? _('Keep as ordinary rules') : _('Delete gaming preset'),
          _(
            'These rules were edited. Confirm replacement or keep them as ordinary rules.',
          ),
          keep ? _('Keep as ordinary rules') : _('Delete'),
        ))
      )
        return;
      const operation: GamingOperation = {
        action: 'remove',
        owner: owner.owner,
        mode: keep ? 'keep' : 'delete',
        confirm: owner.edited,
      };
      try {
        await gamingDraft.stage(operation);
        if (editing?.owner === owner.owner) resetEditor();
      } catch (cause) {
        showError(cause);
      }
    }
    function edit(owner: Owner) {
      editing = owner;
      dirty = false;
      platform.value = owner.platform;
      proxy.value = owner.connection;
      placement.value = owner.placement;
      const index =
        catalog?.devices.findIndex((d) =>
          d.ips.some((ip) =>
            owner.addresses.some((s) => s.split('/')[0] === ip),
          ),
        ) ?? -1;
      device.value = index >= 0 ? String(index) : '';
      showAddresses(owner.addresses);
      update();
    }
    function update() {
      if (disposed) return;
      if (epoch !== gamingDraft.epoch) {
        epoch = gamingDraft.epoch;
        dirty = false;
        editing = null;
        platform.value = '';
        device.value = '';
        addresses.replaceChildren();
      }
      // Native Save renders a new host before its busy flag is cleared.
      // Resume its first catalog load on the idle notification instead of
      // dropping it and leaving the replacement selects permanently empty.
      if (refreshPending && !loading && !gamingDraft.busy) {
        void refresh();
        return;
      }
      const busy = loading || gamingDraft.busy;
      refreshButton.disabled = busy;
      for (const input of [platform, device, proxy, placement, enable])
        input.disabled = !canWrite || busy;
      platform.disabled ||= Boolean(editing);
      device.disabled ||= Boolean(editing);
      for (const input of addresses.querySelectorAll<HTMLInputElement>('input'))
        input.disabled = !canWrite || busy;
      add.disabled = !canWrite || busy || !ready() || !dirty;
      add.textContent = editing ? _('Update in list') : _('Add to list');
      cancel.hidden = !editing && !dirty;
      cancel.disabled = busy;
      heading.textContent = editing
        ? _('Edit gaming preset')
        : _('Add a gaming preset');
      status.textContent = gamingDraft.pending
        ? _(
            'Changes are not applied. Use Save & Apply below to activate all changes together. Reset discards unsaved changes.',
          )
        : _('Add platforms to the list, then use Save & Apply below.');
      existing.replaceChildren();
      let sections: GamingSection[];
      try {
        sections = gamingDraft.sections();
      } catch {
        sections = [];
      }
      const list = owners(sections);
      if (list.length) {
        const table = E('table', { class: 'table cbi-section-table' }, [
          E(
            'tr',
            { class: 'tr table-titles' },
            [_('Platform'), _('Device'), _('Connection'), _('Actions')].map(
              (s) => E('th', { class: 'th' }, s),
            ),
          ),
        ]);
        for (const owner of list) {
          const editButton = button(_('Edit'), () => edit(owner));
          const deleteButton = button(
            _('Delete'),
            () => {
              void remove(owner);
            },
            true,
          );
          editButton.disabled = deleteButton.disabled = !canWrite || busy;
          const keep = button(_('Keep as ordinary rules'), () => {
            void remove(owner, true);
          });
          keep.disabled =
            !canWrite || busy || !gamingDraft.savedOwner(owner.owner);
          table.append(
            E('tr', { class: 'tr' }, [
              E(
                'td',
                { class: 'td' },
                platformName(owner.platform) +
                  (owner.edited ? ' / ' + _('Edited') : ''),
              ),
              E('td', { class: 'td' }, owner.addresses.join(', ')),
              E(
                'td',
                { class: 'td' },
                String(
                  sections.find((s) => s['.name'] === owner.connection)
                    ?.label || owner.connection,
                ),
              ),
              E('td', { class: 'td' }, [
                E('div', { class: 'trafira-form-controls' }, [
                  editButton,
                  deleteButton,
                ]),
                E('details', {}, [E('summary', {}, _('Advanced')), keep]),
              ]),
            ]),
          );
        }
        existing.append(table);
      } else
        existing.append(E('p', {}, _('No gaming presets in the list yet.')));
    }
    async function refresh() {
      if (disposed || loading) return;
      if (gamingDraft.busy) {
        refreshPending = true;
        return;
      }
      refreshPending = false;
      loading = true;
      update();
      try {
        const priorDevice =
          device.value === '' ? null : catalog?.devices[Number(device.value)];
        const priorAddresses = selectedAddresses();
        const result = await gamingCommand({ action: 'catalog' });
        if (disposed) return;
        catalog = result as unknown as Catalog;
        const previousPlatform = platform.value;
        const nextDevice = priorDevice
          ? catalog.devices.findIndex(
              (d) =>
                d.mac === priorDevice.mac &&
                d.interface === priorDevice.interface &&
                d.ips.some((ip) => priorDevice.ips.includes(ip)),
            )
          : -1;
        platform.replaceChildren(
          E('option', { value: '' }, _('Choose a platform')),
          ...catalog.presets.map((p) =>
            E('option', { value: p.id }, platformName(p.id)),
          ),
        );
        device.replaceChildren(
          E('option', { value: '' }, _('Select a known device')),
          ...catalog.devices.map((d, i) =>
            E(
              'option',
              { value: String(i) },
              `${d.name || d.mac} / ${d.interface} / ${d.ips.join(', ')}`,
            ),
          ),
        );
        platform.value = previousPlatform;
        device.value = nextDevice >= 0 ? String(nextDevice) : '';
        showAddresses(priorAddresses);
        const sections = gamingDraft.sections();
        const connections = sections.filter(
          (s) =>
            s['.type'] === 'section' &&
            !s.preset_owner &&
            s.enabled !== '0' &&
            ['connection', 'proxy', 'vpn', 'outbound'].includes(
              String(s.action),
            ),
        );
        const priorProxy = proxy.value;
        proxy.replaceChildren(
          E('option', { value: '' }, _('Select a connection')),
          ...connections.map((s) =>
            E(
              'option',
              { value: String(s['.name']) },
              String(s.label || s['.name']),
            ),
          ),
        );
        proxy.value = connections.some((s) => s['.name'] === priorProxy)
          ? priorProxy
          : connections.length === 1
            ? String(connections[0]['.name'])
            : '';
      } catch (cause) {
        if (!disposed) showError(cause);
      } finally {
        loading = false;
        update();
      }
    }
    for (const input of [platform, proxy, placement, enable])
      input.addEventListener('change', () => {
        dirty = true;
        update();
      });
    device.addEventListener('change', () => {
      dirty = true;
      showAddresses();
    });
    const refreshButton = button(_('Refresh devices'), () => {
      void refresh();
    });
    host.replaceChildren(
      E(
        'p',
        { class: 'cbi-section-descr' },
        _(
          'Stores and account services use the selected connection. Other traffic uses a direct connection. Multiple platforms for the same device work together.',
        ),
      ),
      status,
      error,
      existing,
      heading,
      row(_('Platform'), '', [platform]),
      row(_('Select a known device'), '', [device, refreshButton]),
      row(_('Device IP addresses'), '', [addresses]),
      row(_('Connection'), '', [proxy]),
      row(
        _('Device gaming rule priority'),
        '',
        [placement],
        E(
          'div',
          { class: 'cbi-value-description' },
          _(
            'This priority applies to all gaming presets for this device. Existing device rules may take priority when placed first.',
          ),
        ),
      ),
      row(
        '',
        '',
        [
          E('label', {}, [
            enable,
            ' ' + _('Enable these addresses in device routing if needed'),
          ]),
        ],
        E(
          'div',
          { class: 'cbi-value-description' },
          _(
            'Use this if device routing excludes the selected IP addresses: allow Trafira to handle them so the gaming presets can work. Only these addresses are changed when you Save & Apply. Other devices are not affected. Exceptions for a whole subnet, MAC or interface must be edited in Devices.',
          ),
        ),
      ),
      row('', '', [
        E('div', { class: 'trafira-form-controls' }, [add, cancel]),
      ]),
    );
    const unsubscribe = gamingDraft.subscribe(update);
    const unprepare = gamingDraft.setPrepare(submit);
    mounted = {
      host,
      activate: (value) => {
        canWrite = value;
        update();
      },
      dispose: () => {
        disposed = true;
        unsubscribe();
        unprepare();
      },
    };
    update();
  },
  // Retain the editor and operation queue while switching tabs. A replaced form
  // gets a new host and disposes the old listeners on the next mount.
  unmount() {},
};
