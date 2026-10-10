import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { CoreVersionPicker, VersionState } from './coreVersionPicker';

let active: { picker: CoreVersionPicker; timer: number } | null = null;
export const coreVersionsPanel = {
  mount(canWrite = true) {
    this.unmount();
    const host = document.getElementById('trafira-core-versions');
    if (!host) return;
    let last: VersionState;
    const select = E('select', {
      id: 'trafira-core-version-select',
    }) as HTMLSelectElement;
    const pin = E('input', {
      type: 'checkbox',
      checked: true,
    }) as HTMLInputElement;
    const info = E('p', { class: 'fkp_updates-page__core-versions-info' });
    const message = E('p', {
      class: 'fkp_updates-page__core-versions-message',
      role: 'status',
    });
    message.setAttribute('aria-live', 'polite');
    const selectLabel = E('label', {}, _('Select a version'));
    selectLabel.htmlFor = 'trafira-core-version-select';
    const refresh = E(
      'button',
      { class: 'cbi-button', click: () => void picker.load(true) },
      _('Refresh available versions'),
    ) as HTMLButtonElement;
    const install = E(
      'button',
      {
        class: 'cbi-button cbi-button-action',
        click: () => {
          if (canWrite) void picker.install(pin.checked);
        },
      },
      _('Install selected version'),
    ) as HTMLButtonElement;
    const unpin = E(
      'button',
      {
        class: 'cbi-button',
        click: () => {
          if (canWrite) void picker.unpin();
        },
      },
      _('Unpin version'),
    ) as HTMLButtonElement;
    const pinInstalled = E(
      'button',
      {
        class: 'cbi-button',
        click: () => {
          if (canWrite) void picker.pin();
        },
      },
      _('Pin installed version'),
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
      'Could not load available versions. Check the connection and refresh the list.':
        _(
          'Could not load available versions. Check the connection and refresh the list.',
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
        const hasAvailableVersions = state.entries.some(
          (entry) => entry.available,
        );
        const loading = state.stage === 'loading';
        select.replaceChildren(
          E(
            'option',
            { value: '' },
            loading
              ? _('Loading...')
              : state.entries.length
                ? _('Select a version')
                : _('No compatible versions are available'),
          ),
          ...state.entries.map((entry) =>
            E(
              'option',
              {
                value: entry.id,
                ...(!entry.available ? { disabled: true } : {}),
              },
              entry.version +
                (entry.available
                  ? ''
                  : ` — ${
                      entry.reason === 'stale_catalog'
                        ? _('Refresh required')
                        : _('Unavailable for this installation')
                    }`),
            ),
          ),
        );
        select.value = state.selected;
        const busy =
          state.stage === 'installing' || state.stage === 'saving' || loading;
        select.disabled = busy || !hasAvailableVersions;
        pin.disabled = !canWrite || busy || !hasAvailableVersions;
        refresh.disabled = busy;
        install.disabled = !canWrite || busy || !state.selected;
        unpin.disabled = !canWrite || busy || !state.pinnedVersion;
        pinInstalled.disabled =
          !canWrite ||
          busy ||
          !state.currentVersion ||
          state.currentVersion === 'not-installed' ||
          !state.currentVariant;
        info.textContent = `${_('Installed version')}: ${state.currentVersion === 'not-installed' ? _('Not installed') : state.currentVersion || '—'} · ${_('Pinned version')}: ${state.pinnedVersion || _('Not pinned')}${state.cachedAt ? ` · ${_('Catalog checked')}: ${new Date(state.cachedAt * 1000).toLocaleString()}` : ''}`;
        message.textContent = [
          state.error
            ? errors[state.error] || _('The sing-box version operation failed.')
            : state.stage === 'installing'
              ? _('Installing in the background. You may close this page.')
              : state.stage === 'saving'
                ? _('Saving...')
                : state.unavailableReason || (!loading && !hasAvailableVersions)
                  ? _(
                      'No compatible versions are available for this installation.',
                    )
                  : '',
          state.restored ? _('The previous version was restored.') : '',
        ]
          .filter(Boolean)
          .join(' ');
        message.hidden = !message.textContent;
      },
    );
    select.addEventListener('change', () => picker.select(select.value));
    host.replaceChildren(
      E('section', { class: 'fkp_updates-page__core-versions' }, [
        E('h3', {}, _('Sing-box versions')),
        E(
          'p',
          { class: 'fkp_updates-page__core-versions-help' },
          _(
            'Choose an available version of the installed variant. Compatibility is checked before replacement. Pinning affects updates through Trafira only.',
          ),
        ),
        info,
        E('div', { class: 'fkp_updates-page__core-versions-field' }, [
          selectLabel,
          select,
        ]),
        E('label', { class: 'fkp_updates-page__core-versions-pin' }, [
          pin,
          _('Pin after installation'),
        ]),
        E('div', { class: 'fkp_updates-page__core-versions-buttons' }, [
          refresh,
          install,
          pinInstalled,
          unpin,
        ]),
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
