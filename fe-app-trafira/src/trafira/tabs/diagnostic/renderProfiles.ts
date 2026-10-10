import { executeShellCommand } from '../../../helpers/executeShellCommand';
import {
  ProfilePanelController,
  ProfileRequest,
  ProfileState,
} from './profilePanel';

async function command(request: object): Promise<Record<string, unknown>> {
  const result = await executeShellCommand({
    command: '/usr/bin/trafira-config',
    args: ['profile_action', JSON.stringify(request)],
    timeout: 30000,
  });
  if (result.code) throw new Error('Profile command failed');
  return JSON.parse(result.stdout) as Record<string, unknown>;
}
function encode(bytes: Uint8Array) {
  return btoa(Array.from(bytes, (byte) => String.fromCharCode(byte)).join(''));
}
function decode(value: string) {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}
let mountId = 0;
let active: { controller: ProfilePanelController; timer: number } | null = null;
export const profilesPanel = {
  mount() {
    this.unmount();
    const host = document.getElementById('trafira-profiles');
    if (!host) return;
    const generation = mountId;
    let last: ProfileState;
    let transferring = false;
    const name = E('input', {
      type: 'text',
      maxLength: 64,
      placeholder: _('Profile name'),
    }) as HTMLInputElement;
    const select = E('select', {}) as HTMLSelectElement;
    const file = E('input', {
      type: 'file',
      accept: '.json,application/json',
    }) as HTMLInputElement;
    const result = E('div', {});
    const message = E('p', {});
    const buttons: HTMLButtonElement[] = [];
    let apply: HTMLButtonElement;
    let restore: HTMLButtonElement;
    function updateButtons() {
      const disabled = transferring || last?.busy || last?.running;
      for (const button of buttons) button.disabled = disabled;
      apply.disabled =
        disabled ||
        !last?.preview ||
        last.preview.id !== select.value ||
        !last.preview.applicable;
      restore.disabled = disabled || !last?.canRestore || !last?.digest;
      file.disabled = disabled;
      select.disabled = disabled;
    }
    async function submit(request: ProfileRequest, refresh = false) {
      await controller.submit(request);
      if (refresh && generation === mountId && !last.error)
        await controller.submit({ action: 'list' });
    }
    function button(label: string, click: () => void) {
      const element = E(
        'button',
        { class: 'cbi-button cbi-button-action', click },
        label,
      ) as HTMLButtonElement;
      buttons.push(element);
      return element;
    }
    const actions = [
      button(_('Save current settings'), () => {
        void submit({ action: 'create', name: name.value }, true);
      }),
      button(_('Rename profile'), () => {
        void submit(
          { action: 'rename', id: select.value, name: name.value },
          true,
        );
      }),
      button(_('Show differences'), () => {
        void submit({ action: 'preview', id: select.value });
      }),
      (apply = button(_('Apply profile'), () => {
        void submit({
          action: 'apply',
          id: select.value,
          digest: last.preview?.digest,
        });
      })),
      (restore = button(_('Restore previous settings'), () => {
        void submit({ action: 'restore', digest: last.digest });
      })),
      button(_('Delete profile'), () => {
        if (
          window.confirm(
            _(
              'Delete the selected saved profile? Current settings will remain unchanged.',
            ),
          )
        )
          void submit({ action: 'remove', id: select.value }, true);
      }),
    ];
    async function transfer(kind: 'import' | 'export') {
      if (transferring || last.busy || last.running) return;
      transferring = true;
      message.textContent = _('Transferring profile');
      updateButtons();
      let transferId = '';
      try {
        if (kind === 'import') {
          const selected = file.files?.[0];
          if (!selected || selected.size > 1048576) throw new Error('size');
          const bytes = new Uint8Array(await selected.arrayBuffer());
          const begin = await command({ action: 'import_begin' });
          if (!begin.success || typeof begin.id !== 'string')
            throw new Error('begin');
          transferId = begin.id;
          for (let offset = 0; offset < bytes.length; offset += 12288) {
            if (generation !== mountId) throw new Error('closed');
            const sent = await command({
              action: 'import_chunk',
              id: transferId,
              offset,
              data: encode(bytes.slice(offset, offset + 12288)),
            });
            if (!sent.success) throw new Error('chunk');
          }
          if (generation !== mountId) throw new Error('closed');
          const imported = await command({
            action: 'import_finish',
            id: transferId,
          });
          if (!imported.success) throw new Error('import');
          await controller.submit({ action: 'list' });
        } else {
          const begin = await command({
            action: 'export_begin',
            id: select.value,
          });
          if (!begin.success || typeof begin.id !== 'string')
            throw new Error('begin');
          transferId = begin.id;
          let offset = 0;
          const chunks: Uint8Array[] = [];
          for (;;) {
            if (generation !== mountId) throw new Error('closed');
            const part = await command({
              action: 'export_read',
              id: transferId,
              offset,
            });
            if (!part.success || typeof part.data !== 'string')
              throw new Error('read');
            const bytes = decode(part.data);
            chunks.push(bytes);
            offset += bytes.length;
            if (offset > 1048576 || (!bytes.length && !part.done))
              throw new Error('size');
            if (part.done) break;
          }
          if (generation !== mountId) throw new Error('closed');
          const bytes = new Uint8Array(offset);
          let position = 0;
          for (const chunk of chunks) {
            bytes.set(chunk, position);
            position += chunk.length;
          }
          const url = URL.createObjectURL(
            new Blob([bytes], { type: 'application/json' }),
          );
          const link = document.createElement('a');
          link.href = url;
          link.download = 'trafira-profile.json';
          link.click();
          URL.revokeObjectURL(url);
        }
        if (generation === mountId)
          message.textContent = _('Profile transfer completed');
      } catch {
        if (generation === mountId)
          message.textContent = _(
            'Profile transfer failed. Select a valid JSON file of up to 1 MiB.',
          );
      } finally {
        if (transferId)
          void command({ action: 'transfer_cancel', id: transferId }).catch(
            () => undefined,
          );
        transferring = false;
        if (generation === mountId) updateButtons();
      }
    }
    actions.push(
      button(_('Import profile'), () => {
        void transfer('import');
      }),
      button(_('Export profile'), () => {
        void transfer('export');
      }),
    );
    select.addEventListener('change', updateButtons);
    host.replaceChildren(
      E('h3', {}, _('Configuration profiles')),
      E(
        'p',
        {},
        _('Save up to eight profiles. Applying a profile may restart routing.'),
      ),
      E('div', { class: 'fkp_diagnostic-fields' }, [
        E('label', { class: 'fkp_diagnostic-field' }, [
          E('span', {}, _('Profile name')),
          name,
        ]),
        E('label', { class: 'fkp_diagnostic-field' }, [
          E('span', {}, _('Configuration profiles')),
          select,
        ]),
      ]),
      E('div', { class: 'fkp_diagnostic-actions' }, actions),
      E(
        'p',
        {},
        _(
          'Exported profiles contain passwords and keys. Keep the downloaded file private.',
        ),
      ),
      E('label', { class: 'fkp_diagnostic-field' }, [
        E('span', {}, _('Import profile')),
        file,
      ]),
      message,
      result,
    );
    const controller = new ProfilePanelController(command, (state) => {
      if (generation !== mountId) return;
      if (JSON.stringify(last?.entries) !== JSON.stringify(state.entries)) {
        const chosen = select.value;
        select.replaceChildren(
          ...state.entries.map((entry) =>
            E(
              'option',
              {
                value: entry.id,
                ...(entry.invalid ? { disabled: true } : {}),
              },
              entry.name,
            ),
          ),
        );
        if (state.entries.some((entry) => entry.id === chosen))
          select.value = chosen;
      }
      last = state;
      result.replaceChildren(
        ...(state.error ? [E('p', {}, _(state.error))] : []),
        ...(state.running
          ? [
              E(
                'p',
                {},
                _(
                  'Applying settings in the background. You can close this page.',
                ),
              ),
            ]
          : []),
        ...(state.restored
          ? [E('p', {}, _('Previous settings were restored.'))]
          : []),
        ...(state.preview
          ? [
              E(
                'p',
                {},
                _(
                  'Only changed section and option names are shown; values are hidden.',
                ),
              ),
              ...(!state.preview.applicable
                ? [
                    E(
                      'p',
                      {},
                      _(
                        'The profile cannot be used with the current configuration and components.',
                      ),
                    ),
                  ]
                : []),
              ...state.preview.changes.map((change) =>
                E(
                  'p',
                  {},
                  `${change.section}${change.option ? ` / ${change.option}` : ''}: ${{ added: _('Added'), removed: _('Removed'), changed: _('Changed') }[change.change] || _('Changed')}`,
                ),
              ),
            ]
          : []),
      );
      updateButtons();
    });
    controller.mount();
    void controller
      .submit({ action: 'list' })
      .then(() => controller.submit({ action: 'status' }));
    const timer = window.setInterval(() => {
      if (!last.running) return;
      void controller.submit({ action: 'status' }).then(() => {
        if (!last.running && !last.error)
          void controller.submit({ action: 'list' });
      });
    }, 2000);
    active = { controller, timer };
  },
  unmount() {
    mountId++;
    if (active) {
      active.controller.unmount();
      window.clearInterval(active.timer);
    }
    active = null;
  },
};
