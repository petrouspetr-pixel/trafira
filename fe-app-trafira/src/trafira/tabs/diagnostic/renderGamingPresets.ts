import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { GamingPresetController, GamingState } from './gamingPresetPanel';
interface Device {
  name: string;
  interface: string;
  mac: string;
  ips: string[];
}
interface Catalog {
  digest: string;
  devices: Device[];
  presets: Array<{ id: string; revision: number; checked_at: string }>;
  proxies: Array<{ id: string; label: string }>;
  owners: Array<{ owner: string; platform: string; edited: boolean }>;
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
      'Alice Mode bypasses this device. Explicitly enable its selected addresses before applying.',
    ),
    alice_broad_bypass: _(
      'This Alice Mode exception also covers other devices. Edit it manually before applying this preset.',
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
let mounted: { controller: GamingPresetController; timer: number } | null =
  null;
let generation = 0;
export const gamingPresetsPanel = {
  mount() {
    this.unmount();
    const host = document.getElementById('trafira-gaming-presets');
    if (!host) return;
    const mine = generation;
    let catalog: Catalog | null = null;
    let state: GamingState;
    let loading = false;
    const platform = E('select', {}) as HTMLSelectElement,
      device = E('select', {}) as HTMLSelectElement,
      proxy = E('select', {}) as HTMLSelectElement;
    const placement = E('select', {}, [
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
    const addresses = E('div', {}),
      output = E('div', {}),
      status = E('p', {}),
      existing = E('div', {});
    const enable = E('input', { type: 'checkbox' }) as HTMLInputElement,
      replace = E('input', { type: 'checkbox' }) as HTMLInputElement;
    const buttons: HTMLButtonElement[] = [];
    let apply: HTMLButtonElement;
    function button(label: string, click: () => void) {
      const b = E(
        'button',
        { class: 'cbi-button cbi-button-action', click },
        label,
      ) as HTMLButtonElement;
      buttons.push(b);
      return b;
    }
    function update() {
      const busy = loading || state?.busy || state?.running;
      for (const b of buttons) b.disabled = !!busy;
      for (const input of [platform, device, proxy, placement, enable, replace])
        input.disabled = !!busy;
      for (const input of Array.from(addresses.querySelectorAll('input')))
        input.disabled = !!busy;
      if (apply) apply.disabled = !!busy || state?.preview?.applicable !== true;
    }
    const controller = new GamingPresetController(command, (next) => {
      const wasRunning = state?.running;
      state = next;
      status.textContent = state.error
        ? message(state.error)
        : state.running
          ? _('Applying configuration. You can reconnect to this page.')
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
        // E uses text nodes; device names, domains and errors never enter innerHTML.
        output.append(
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
        );
      }
      update();
      if (wasRunning && !state.running && !state.error) void refresh();
    });
    function showAddresses() {
      controller.invalidate();
      addresses.replaceChildren();
      const selected = catalog?.devices[Number(device.value)];
      if (!selected) return;
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
        input.addEventListener('change', () => controller.invalidate());
        addresses.append(
          E('label', { style: 'display:block' }, [input, ' ' + address]),
        );
      }
    }
    async function refresh() {
      if (loading || state?.busy || state?.running) return;
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
          ...catalog.presets.map((p) =>
            E(
              'option',
              { value: p.id },
              `${p.id} · ${p.checked_at} · v${p.revision}`,
            ),
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
        addresses.replaceChildren();
        existing.replaceChildren();
        for (const owner of catalog.owners) {
          existing.append(
            E(
              'p',
              {},
              owner.platform +
                ' · ' +
                owner.owner +
                (owner.edited ? ' · ' + _('Edited') : ''),
            ),
          );
          existing.append(
            button(_('Keep as ordinary rules'), () => {
              void controller.preview(
                { owner: owner.owner, mode: 'keep' },
                catalog!.digest,
              );
            }),
          );
          existing.append(
            button(_('Preview deletion'), () => {
              if (
                owner.edited &&
                !window.confirm(
                  _(
                    'Delete the edited preset rules? The next step shows the changes.',
                  ),
                )
              )
                return;
              void controller.preview(
                { owner: owner.owner, mode: 'delete', confirm: owner.edited },
                catalog!.digest,
              );
            }),
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
    host.replaceChildren(
      E('h3', {}, _('Gaming presets')),
      E(
        'p',
        {},
        _(
          'Store and account services use the selected proxy; remaining traffic from the selected addresses goes directly. Shared services may also carry game traffic. These editable lists do not cover every platform endpoint.',
        ),
      ),
      E(
        'p',
        {},
        _(
          'Select host addresses explicitly, including IPv6 if needed. DHCP and IPv6 address changes require updating the rules. No ports or UPnP are opened.',
        ),
      ),
      E('div', { class: 'fkp_diagnostic-fields' }, [
        E('label', { class: 'fkp_diagnostic-field' }, [
          E('span', {}, _('Gaming presets')),
          platform,
        ]),
        E('label', { class: 'fkp_diagnostic-field' }, [
          E('span', {}, _('Select a known device')),
          device,
        ]),
        E('label', { class: 'fkp_diagnostic-field' }, [
          E('span', {}, _('Select a connection')),
          proxy,
        ]),
        E('label', { class: 'fkp_diagnostic-field' }, [
          E('span', {}, _('Choose rule priority')),
          placement,
        ]),
      ]),
      addresses,
      E('label', { style: 'display:block' }, [
        enable,
        ' ' + _('Enable only these addresses in Alice Mode if required'),
      ]),
      E('label', { style: 'display:block' }, [
        replace,
        ' ' + _('Replace my edits to this preset after preview'),
      ]),
      E('div', { class: 'fkp_diagnostic-actions' }, [
        button(_('Refresh devices'), () => {
          void refresh();
        }),
        button(_('Preview gaming rules'), () => {
          if (!catalog || device.value === '') return;
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
        }),
        (apply = button(_('Apply reviewed changes'), () => {
          void controller.apply();
        })),
      ]),
      status,
      output,
      existing,
    );
    controller.mount();
    mounted = {
      controller,
      timer: window.setInterval(() => {
        void controller.poll();
      }, 2000),
    };
    void controller.poll().then(() => refresh());
  },
  unmount() {
    generation++;
    if (mounted) {
      mounted.controller.unmount();
      window.clearInterval(mounted.timer);
    }
    mounted = null;
  },
};
