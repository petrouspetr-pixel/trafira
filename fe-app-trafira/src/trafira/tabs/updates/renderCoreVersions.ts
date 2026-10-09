import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { CoreVersionPicker, VersionState } from './coreVersionPicker';

let active: { picker: CoreVersionPicker; timer: number } | null = null;
export const coreVersionsPanel = {
  mount() {
    this.unmount();
    const host = document.getElementById('trafira-core-versions');
    if (!host) return;
    let last: VersionState;
    const select = E('select', {}) as HTMLSelectElement;
    const pin = E('input', {
      type: 'checkbox',
      checked: true,
    }) as HTMLInputElement;
    const info = E('p', {});
    const message = E('p', { role: 'status' });
    const refresh = E(
      'button',
      { class: 'cbi-button', click: () => void picker.load(true) },
      _('Refresh available versions'),
    ) as HTMLButtonElement;
    const install = E(
      'button',
      {
        class: 'cbi-button cbi-button-action',
        click: () => void picker.install(pin.checked),
      },
      _('Install selected version'),
    ) as HTMLButtonElement;
    const unpin = E(
      'button',
      {
        class: 'cbi-button',
        click: () => void picker.unpin().then(() => picker.load()),
      },
      _('Unpin version'),
    ) as HTMLButtonElement;
    const errors: Record<string, string> = {
      'Restoration failed. Check the service before continuing.': _(
        'Restoration failed. Check the service before continuing.',
      ),
      'The installed version changed. Refresh the version list.': _(
        'The installed version changed. Refresh the version list.',
      ),
      'The sing-box version operation failed.': _(
        'The sing-box version operation failed.',
      ),
    };
    const picker = new CoreVersionPicker(
      async (request) => {
        const result = await executeShellCommand({
          command: '/usr/bin/trafira-config',
          args: ['core_action', JSON.stringify(request)],
          timeout: 45000,
        });
        if (result.code) throw new Error('Core version request failed');
        return JSON.parse(result.stdout) as object;
      },
      (state) => {
        last = state;
        select.replaceChildren(
          E('option', { value: '' }, _('Select a version')),
          ...state.entries.map((entry) =>
            E(
              'option',
              { value: entry.id, disabled: !entry.available },
              entry.version +
                (entry.available
                  ? ''
                  : ` — ${_('Unavailable for this installation')}`),
            ),
          ),
        );
        select.value = state.selected;
        const busy = state.stage === 'installing' || state.stage === 'loading';
        select.disabled = pin.disabled = refresh.disabled = busy;
        install.disabled = busy || !state.selected;
        unpin.disabled = busy || !state.pinnedVersion;
        info.textContent = `${_('Installed version')}: ${state.currentVersion || '—'} · ${_('Pinned version')}: ${state.pinnedVersion || '—'}${state.cachedAt ? ` · ${_('Catalog checked')}: ${new Date(state.cachedAt * 1000).toLocaleString()}` : ''}`;
        message.textContent = [
          state.error
            ? errors[state.error] || _('The sing-box version operation failed.')
            : state.stage === 'installing'
              ? _('Installing in the background. You may close this page.')
              : '',
          state.restored ? _('The previous version was restored.') : '',
        ]
          .filter(Boolean)
          .join(' ');
      },
    );
    select.addEventListener('change', () => picker.select(select.value));
    host.replaceChildren(
      E('details', {}, [
        E('summary', {}, _('Sing-box versions')),
        E(
          'p',
          {},
          _(
            'Choose an available version of the installed variant. Compatibility is checked before replacement. Pinning affects updates through Trafira only.',
          ),
        ),
        info,
        select,
        E('label', {}, [pin, _('Pin selected version')]),
        E('div', {}, [refresh, install, unpin]),
        message,
      ]),
    );
    picker.mount();
    void picker.load().then(() => picker.poll());
    const timer = window.setInterval(() => {
      if (last.stage !== 'installing') return;
      void picker.poll().then(() => {
        if (last.stage === 'done') void picker.load(true);
      });
    }, 2000);
    active = { picker, timer };
  },
  unmount() {
    if (active) {
      active.picker.unmount();
      window.clearInterval(active.timer);
    }
    active = null;
  },
};
