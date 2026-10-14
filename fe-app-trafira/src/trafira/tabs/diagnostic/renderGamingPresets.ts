import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { renderConfigurationRow as row } from '../../helpers/renderConfigurationRow';
import {
  confirmAction,
  confirmConfigurationReplacement,
  reloadAfterConfigurationCommit,
  showConfigurationCommitNotice,
} from '../../helpers/configurationSync';
import { GamingPresetController, GamingState } from './gamingPresetPanel';
interface Device {
  name: string;
  interface: string;
  mac: string;
  ips: string[];
}
interface Catalog {
  digest: string;
  enabled?: boolean;
  devices: Device[];
  presets: Array<{ id: string; revision: number; checked_at: string }>;
  proxies: Array<{ id: string; label: string }>;
  owners: Array<{
    owner: string;
    platform: string;
    edited: boolean;
    addresses?: string[];
    connection?: string;
  }>;
}
async function command(
  request: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const response = await executeShellCommand({
    command: '/usr/bin/trafira-config',
    args: ['gaming_preset_action', JSON.stringify(request)],
    timeout: 30000,
  });
  if (response.code) throw new Error('Gaming preset request failed');
  return JSON.parse(response.stdout) as Record<string, unknown>;
}
function message(code: string) {
  const messages: Record<string, string> = {
    conflict: _('Configuration changed. Review the differences again.'),
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
    candidate_check_failed: _(
      'The generated configuration did not pass validation.',
    ),
    gaming_disabled: _(
      'Enable gaming presets before creating or updating their rules.',
    ),
    busy: _('Another configuration operation is already running.'),
    rollback_failed: _(
      'Restoration failed. Check the service before continuing.',
    ),
  };
  return (
    messages[code] ||
    _('The operation failed. Refresh the page and review the settings.') +
      ' (' +
      code +
      ')'
  );
}
let mounted: {
  controller: GamingPresetController;
  timer: number;
  closeProgress: () => void;
} | null = null;
let generation = 0;
function platformName(id: string) {
  return (
    (
      {
        steam: 'Steam',
        playstation: 'PlayStation',
        xbox: 'Xbox',
        epic: 'Epic Games',
      } as Record<string, string>
    )[id] || id
  );
}
function rows(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value)
    ? value.filter(
        (row): row is Record<string, unknown> =>
          !!row && typeof row === 'object',
      )
    : [];
}
function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === 'string')
    : [];
}
export const gamingPresetsPanel = {
  mount(canWrite = true) {
    this.unmount();
    const host = document.getElementById('trafira-gaming-presets');
    if (!host) return;
    showConfigurationCommitNotice();
    const mine = generation;
    let catalog: Catalog | null = null;
    let state: GamingState;
    let observedRunning = false;
    let loading = false;
    let confirming = false;
    let shownRemoval: Record<string, unknown> | null = null;
    const platform = E('select', {
        id: 'trafira-game-platform',
      }) as HTMLSelectElement,
      device = E('select', { id: 'trafira-game-device' }) as HTMLSelectElement,
      proxy = E('select', { id: 'trafira-game-proxy' }) as HTMLSelectElement;
    const placement = E('select', { id: 'trafira-game-priority' }, [
      E('option', { value: '' }, _('Choose rule priority')),
      E(
        'option',
        { value: 'before-device-routes' },
        _('Before existing device rules'),
      ),
      E(
        'option',
        { value: 'after-device-routes' },
        _('After existing device rules'),
      ),
    ]) as HTMLSelectElement;
    const master = E('input', {
      type: 'checkbox',
      id: 'trafira-game-enabled',
    }) as HTMLInputElement;
    const masterStatus = E('p', {
      class: 'cbi-value-description',
      role: 'status',
    });
    const content = E('div', { id: 'trafira-game-content' });
    const addresses = E('div', { class: 'trafira-form-controls' }),
      output = E('div', {}),
      status = E('p', {}),
      existing = E('div', {});
    const hint = E('p', { role: 'status' });
    const addressRow = row(_('Device IP addresses'), '', [addresses]);
    const hintRow = row('', '', [hint]);
    const resultRow = row('', '', [E('div', {}, [status, output])]);
    const existingRow = row(_('Installed gaming presets'), '', [existing]);
    const enable = E('input', { type: 'checkbox' }) as HTMLInputElement,
      replace = E('input', { type: 'checkbox' }) as HTMLInputElement;
    let apply: HTMLButtonElement;
    let preview: HTMLButtonElement;
    function button(label: string, click: () => void) {
      const b = E(
        'button',
        { type: 'button', class: 'cbi-button cbi-button-action', click },
        label,
      ) as HTMLButtonElement;
      return b;
    }
    function update() {
      const busy = loading || confirming || state?.busy || state?.running;
      for (const b of Array.from(host!.querySelectorAll('button')))
        b.disabled = !!busy;
      master.disabled = !canWrite || !catalog || !!busy;
      const disabled = catalog?.enabled === false;
      content.hidden = disabled;
      master.checked = catalog?.enabled !== false;
      masterStatus.textContent = disabled
        ? _(
            'Gaming presets are disabled. Saved presets are kept; their rules do not route traffic.',
          )
        : _(
            'Gaming presets are enabled. Changes to this switch are applied immediately and may briefly restart routing.',
          );
      for (const input of [platform, device, proxy, placement, enable, replace])
        input.disabled = !!busy || disabled;
      for (const input of Array.from(addresses.querySelectorAll('input')))
        input.disabled = !!busy || disabled;
      const ready =
        !!catalog &&
        !!platform.value &&
        device.value !== '' &&
        !!proxy.value &&
        !!placement.value &&
        addresses.querySelectorAll('input:checked').length > 0;
      if (preview) preview.disabled = !!busy || disabled || !ready;
      if (apply) {
        apply.textContent =
          state?.preview?.operation === 'preview_remove'
            ? state.preview.mode === 'keep'
              ? _('Keep as ordinary rules')
              : _('Delete')
            : _('Apply reviewed changes');
        apply.disabled =
          !canWrite ||
          !!busy ||
          state?.preview?.applicable !== true ||
          (disabled && state?.preview?.operation !== 'preview_remove');
      }
      hint.textContent = !catalog
        ? ''
        : !catalog.devices.length
          ? _(
              'No known devices. Connect the device to the router and refresh the list.',
            ) +
            (!catalog.proxies.length
              ? ' ' + _('No enabled connection rules. Add a connection first.')
              : '')
          : !catalog.proxies.length
            ? _('No enabled connection rules. Add a connection first.')
            : !catalog.presets.length
              ? _('No gaming presets are available.')
              : ready
                ? ''
                : _(
                    'Choose a platform, device addresses, connection and rule priority before previewing.',
                  );
      addressRow.className =
        'cbi-value' +
        (addresses.querySelectorAll('input').length ? '' : ' hidden');
      hintRow.className = 'cbi-value' + (hint.textContent ? '' : ' hidden');
      existingRow.className =
        'cbi-value' + (existing.children.length ? '' : ' hidden');
      resultRow.className =
        'cbi-value' +
        (status.textContent || output.children.length ? '' : ' hidden');
    }
    let progressNode: HTMLElement | null = null;
    let progressPhase = 'idle';
    let dismissedPhase = '';
    let notifiedError = '';
    const closeProgress = () => {
      if (progressNode?.isConnected) ui.hideModal();
      progressNode = null;
      progressPhase = 'idle';
    };
    const showProgress = (next: GamingState) => {
      const phase = next.running
        ? 'applying'
        : next.busy
          ? next.phase || 'idle'
          : 'idle';
      if (phase === 'idle') {
        closeProgress();
        dismissedPhase = '';
        return;
      }
      if (dismissedPhase === phase || progressPhase === phase) return;
      closeProgress();
      progressPhase = phase;
      progressNode = E('div', {}, [
        E(
          'p',
          { class: 'spinning' },
          phase === 'checking'
            ? _(
                'Please wait while Trafira checks the proposed configuration. Your settings have not been changed.',
              )
            : _(
                'Please wait while Trafira saves and applies the configuration. The service may restart briefly.',
              ),
        ),
        E('div', { class: 'right' }, [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              click: () => {
                dismissedPhase = phase;
                closeProgress();
              },
            },
            _('Continue in background'),
          ),
        ]),
      ]);
      ui.showModal(
        phase === 'checking'
          ? _('Checking configuration...')
          : _('Applying configuration...'),
        progressNode,
      );
    };
    const controller = new GamingPresetController(command, (next) => {
      if (mine !== generation) return;
      const wasRunning = observedRunning;
      observedRunning = next.running;
      state = next;
      showProgress(next);
      if (next.error && next.error !== notifiedError)
        ui.addNotification(
          _('Gaming presets'),
          E('p', {}, message(next.error)),
          'danger',
        );
      notifiedError = next.error;
      status.textContent = state.error
        ? message(state.error)
        : state.running
          ? _('Applying configuration. You can reconnect to this page.')
          : state.busy && state.phase !== 'idle'
            ? state.phase === 'applying'
              ? _('Applying configuration...')
              : _('Checking configuration...')
            : '';
      output.replaceChildren();
      if (state.preview) {
        const p = state.preview;
        output.append(
          E(
            'p',
            {},
            p.applicable
              ? _('Configuration validation passed. Review the changes below.')
              : _('The generated configuration did not pass validation.'),
          ),
        );
        for (const route of rows(p.routes)) {
          const domains = [
            ...strings(route.domain),
            ...strings(route.domain_suffix).map((name) => '*.' + name),
          ];
          const target = String(route.target || '');
          const label =
            target === 'direct'
              ? _('Direct connection')
              : catalog?.proxies.find((item) => item.id === target)?.label ||
                target;
          output.append(
            E(
              'p',
              {},
              `${strings(route.source).join(', ')}: ${domains.length ? domains.join(', ') : _('Other traffic')} → ${label}`,
            ),
          );
        }
        const changes = rows(p.changes);
        output.append(
          E(
            'p',
            {},
            _('Changed rules') +
              ': ' +
              new Set(changes.map((change) => String(change.section || '')))
                .size,
          ),
        );
        for (const conflict of strings(p.conflicts)) {
          const description = conflict.startsWith('existing_device_routes:')
            ? _(
                'An existing device rule may overlap. The selected priority determines which rule takes effect.',
              ) +
              ' ' +
              conflict.slice('existing_device_routes:'.length)
            : conflict === 'alice_device_enabled'
              ? _('Device routing will be enabled for the selected addresses.')
              : message(conflict);
          output.append(
            E('p', { class: 'alert-message warning' }, description),
          );
        }
        if (rows(p.checks).some((check) => check.status === 'indeterminate'))
          output.append(
            E(
              'p',
              {},
              _(
                'Some routes could not be fully verified. Review existing rules and saved list copies.',
              ),
            ),
          );
        // Details remain optional; all backend text goes through text nodes.
        output.append(
          E('details', {}, [
            E('summary', {}, _('Technical details')),
            E(
              'pre',
              {
                style:
                  'white-space:pre-wrap;overflow-wrap:anywhere;max-height:24em;overflow:auto',
              },
              JSON.stringify(
                {
                  routes: p.routes,
                  changes: p.changes,
                  conflicts: p.conflicts,
                  checks: p.checks,
                },
                null,
                2,
              ),
            ),
          ]),
        );
      }
      update();
      if (
        canWrite &&
        state.preview?.operation === 'preview_remove' &&
        state.preview.mode === 'delete' &&
        state.preview.applicable &&
        shownRemoval !== state.preview
      ) {
        const removal = state.preview;
        shownRemoval = removal;
        const owner = catalog?.owners.find(
          (item) => item.owner === removal.owner,
        );
        confirming = true;
        update();
        void confirmAction(
          _('Delete gaming preset'),
          E('div', {}, [
            E(
              'p',
              {},
              owner
                ? `${platformName(owner.platform)} · ${owner.addresses?.join(', ') || owner.owner}`
                : '',
            ),
            E(
              'p',
              {},
              _(
                'The preset rules will be removed. Other settings will remain unchanged.',
              ),
            ),
            ...(owner?.edited
              ? [E('p', { class: 'alert-message warning' }, _('Edited'))]
              : []),
            output.cloneNode(true),
          ]),
          _('Delete'),
        ).then((accepted) => {
          if (mine !== generation) return;
          confirming = false;
          if (accepted && canWrite && state.preview === removal)
            void controller.apply();
          else controller.invalidate();
          update();
        });
      }
      if (state.committed) reloadAfterConfigurationCommit();
      else if (wasRunning && !state.running && !state.error) void refresh();
    });
    function showAddresses() {
      controller.invalidate();
      addresses.replaceChildren();
      const selected = catalog?.devices[Number(device.value)];
      if (device.value === '' || !selected) {
        update();
        return;
      }
      // Never silently group every address with a shared MAC (proxy ARP is possible).
      const candidates = catalog!.devices.filter(
        (d) => d.mac === selected.mac && d.interface === selected.interface,
      );
      const values = [...new Set(candidates.flatMap((d) => d.ips))];
      for (const address of values) {
        const input = E('input', {
          type: 'checkbox',
          value: address,
        }) as HTMLInputElement;
        input.checked = values.length === 1;
        input.addEventListener('change', () => controller.invalidate());
        addresses.append(
          E('label', { class: 'cbi-checkbox' }, [input, ' ' + address]),
        );
      }
      update();
    }
    async function refresh() {
      if (mine !== generation || loading || state?.busy || state?.running)
        return;
      const previousPlatform = platform.value;
      const previousProxy = proxy.value;
      const previousPlacement = placement.value;
      const previousDevice =
        device.value === '' ? null : catalog?.devices[Number(device.value)];
      const selectedAddresses = new Set(
        Array.from(
          addresses.querySelectorAll<HTMLInputElement>('input:checked'),
        ).map((input) => input.value),
      );
      loading = true;
      controller.invalidate();
      update();
      try {
        const result = await command({ action: 'catalog' });
        if (mine !== generation) return;
        if (result.success !== true)
          throw new Error(String(result.error || 'catalog_unavailable'));
        catalog = result as unknown as Catalog;
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
              `${d.name || d.mac} · ${d.interface} · ${d.ips.join(', ')}`,
            ),
          ),
        );
        proxy.replaceChildren(
          E('option', { value: '' }, _('Select a connection')),
          ...catalog.proxies.map((p) =>
            E('option', { value: p.id }, p.label || p.id),
          ),
        );
        if (catalog.presets.some((p) => p.id === previousPlatform))
          platform.value = previousPlatform;
        if (catalog.proxies.some((p) => p.id === previousProxy))
          proxy.value = previousProxy;
        else if (catalog.proxies.length === 1)
          proxy.value = catalog.proxies[0].id;
        placement.value = previousPlacement || 'after-device-routes';
        const retainedDevice = previousDevice
          ? catalog.devices.findIndex(
              (d) =>
                d.mac === previousDevice.mac &&
                d.interface === previousDevice.interface &&
                d.ips.length === previousDevice.ips.length &&
                d.ips.every((address) => previousDevice.ips.includes(address)),
            )
          : -1;
        device.value = retainedDevice >= 0 ? String(retainedDevice) : '';
        showAddresses();
        if (retainedDevice >= 0)
          for (const input of addresses.querySelectorAll<HTMLInputElement>(
            'input',
          ))
            input.checked = selectedAddresses.has(input.value);
        existing.replaceChildren();
        if (catalog.owners.length) {
          const table = E('table', { class: 'table cbi-section-table' }, [
            E(
              'tr',
              { class: 'tr table-titles' },
              [_('Platform'), _('Device'), _('Connection'), _('Actions')].map(
                (label) => E('th', { class: 'th' }, label),
              ),
            ),
          ]);
          for (const owner of catalog.owners) {
            const keep = button(_('Keep as ordinary rules'), () => {
              void controller.preview(
                { owner: owner.owner, mode: 'keep' },
                catalog!.digest,
              );
            });
            const remove = button(_('Delete'), async () => {
              void controller.preview(
                { owner: owner.owner, mode: 'delete', confirm: owner.edited },
                catalog!.digest,
              );
            });
            table.append(
              E('tr', { class: 'tr' }, [
                E(
                  'td',
                  { class: 'td' },
                  platformName(owner.platform) +
                    (owner.edited ? ' · ' + _('Edited') : ''),
                ),
                E(
                  'td',
                  { class: 'td' },
                  owner.addresses?.join(', ') || owner.owner,
                ),
                E(
                  'td',
                  { class: 'td' },
                  catalog!.proxies.find((p) => p.id === owner.connection)
                    ?.label ||
                    owner.connection ||
                    '—',
                ),
                E(
                  'td',
                  { class: 'td' },
                  E('div', { class: 'trafira-form-controls' }, [keep, remove]),
                ),
              ]),
            );
          }
          existing.append(
            table,
            E(
              'p',
              { class: 'cbi-value-description' },
              _(
                "Delete removes this preset's rules. Keep as ordinary rules preserves routing and moves further management to Sections.",
              ),
            ),
          );
        }
        status.textContent = '';
      } catch (error) {
        if (mine === generation)
          status.textContent = message(
            error instanceof Error ? error.message : 'catalog_unavailable',
          );
      } finally {
        if (mine === generation) {
          loading = false;
          update();
        }
      }
    }
    for (const input of [platform, proxy, placement, enable, replace])
      input.addEventListener('change', () => controller.invalidate());
    device.addEventListener('change', showAddresses);
    master.addEventListener('change', async () => {
      if (!canWrite || !catalog || master.disabled) return;
      const enabled = master.checked;
      master.checked = catalog.enabled !== false;
      confirming = true;
      update();
      const accepted = await confirmAction(
        enabled ? _('Enable gaming presets') : _('Disable gaming presets'),
        E('div', {}, [
          E(
            'p',
            {},
            enabled
              ? _(
                  'Restore the previous enabled state of each saved preset rule. Ordinary rules are not changed.',
                )
              : _(
                  'Disable all saved preset rules without deleting the presets. Ordinary rules are not changed.',
                ),
          ),
          E(
            'p',
            {},
            _(
              'Applying these settings replaces the saved configuration. Any unsaved changes in this LuCI page will be lost. Continue?',
            ),
          ),
        ]),
        enabled ? _('Enable') : _('Disable'),
      );
      confirming = false;
      update();
      if (accepted && mine === generation)
        await controller.setEnabled(enabled, catalog.digest);
    });
    content.replaceChildren(
      E(
        'p',
        { class: 'cbi-section-descr' },
        _(
          'Store and sign-in services use your chosen connection; other traffic from the selected device addresses goes directly. Shared services may also carry game traffic.',
        ),
      ),
      E(
        'p',
        { class: 'cbi-section-descr' },
        _(
          'Select host addresses explicitly, including IPv6 if needed. DHCP and IPv6 address changes require updating the rules. No ports or UPnP are opened.',
        ),
      ),
      existingRow,
      E('h4', {}, _('Create or update a gaming preset')),
      row(_('Gaming presets'), 'trafira-game-platform', [platform]),
      row(_('Select a known device'), 'trafira-game-device', [
        device,
        button(_('Refresh devices'), () => {
          void refresh();
        }),
      ]),
      addressRow,
      row(_('Select a connection'), 'trafira-game-proxy', [proxy]),
      row(_('Choose rule priority'), 'trafira-game-priority', [placement]),
      hintRow,
      ...(!canWrite
        ? [
            E(
              'p',
              {},
              _(
                'Read-only access: you can preview rules but cannot apply changes.',
              ),
            ),
          ]
        : []),
      row('', '', [
        E('label', { class: 'cbi-checkbox' }, [
          enable,
          ' ' + _('Enable device routing only for these addresses if required'),
        ]),
      ]),
      row('', '', [
        E('label', { class: 'cbi-checkbox' }, [
          replace,
          ' ' + _('Replace my edits to this preset after preview'),
        ]),
      ]),
      row('', '', [
        (preview = button(_('Preview gaming rules'), () => {
          if (!catalog || preview.disabled) return;
          void controller.preview(
            {
              preset: platform.value,
              device_ips: Array.from(
                addresses.querySelectorAll<HTMLInputElement>('input:checked'),
              ).map((i) => i.value),
              proxy_section: proxy.value,
              placement: placement.value,
              enable_device: enable.checked,
              replace_edited: replace.checked,
            },
            catalog.digest,
          );
        })),
        (apply = button(_('Apply reviewed changes'), async () => {
          if (!canWrite || apply.disabled || confirming) return;
          confirming = true;
          update();
          const accepted =
            state?.preview?.operation === 'preview_remove' &&
            state.preview.mode === 'delete'
              ? await confirmAction(
                  _('Delete gaming preset'),
                  _(
                    'The preset rules will be removed. Other settings will remain unchanged.',
                  ),
                  _('Delete'),
                )
              : state.preview?.operation === 'preview_remove' &&
                  state.preview.mode === 'keep'
                ? await confirmAction(
                    _('Keep as ordinary rules'),
                    E('div', {}, [
                      E(
                        'p',
                        {},
                        _(
                          'The rules keep their current enabled or disabled state. The preset disappears from this list; enable, edit or delete its rules in Sections.',
                        ),
                      ),
                      E(
                        'p',
                        {},
                        _(
                          'Applying these settings replaces the saved configuration. Any unsaved changes in this LuCI page will be lost. Continue?',
                        ),
                      ),
                    ]),
                    _('Keep as ordinary rules'),
                  )
                : await confirmConfigurationReplacement();
          confirming = false;
          update();
          if (accepted) void controller.apply();
        })),
      ]),
    );
    host.replaceChildren(
      row(_('Enable gaming presets'), 'trafira-game-enabled', [
        master,
        masterStatus,
      ]),
      content,
      resultRow,
    );
    controller.mount();
    mounted = {
      controller,
      closeProgress,
      timer: window.setInterval(() => {
        if (state?.running) void controller.poll();
      }, 2000),
    };
    void controller.poll().then(() => refresh());
  },
  unmount() {
    generation++;
    if (mounted) {
      mounted.closeProgress();
      mounted.controller.unmount();
      window.clearInterval(mounted.timer);
    }
    mounted = null;
  },
};
