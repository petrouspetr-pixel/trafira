import { executeShellCommand } from '../../../helpers/executeShellCommand';
import {
  ProfilePanelController,
  ProfileRequest,
  ProfileState,
  profileErrorMessage,
} from './profilePanel';
import {
  confirmConfigurationReplacement,
  reloadAfterConfigurationCommit,
} from '../../helpers/configurationSync';

const MAX_FILE = 1048576;
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
function requireSuccess(result: Record<string, unknown>) {
  if (result.success !== true)
    throw new Error(
      typeof result.error === 'string' ? result.error : 'transfer_failed',
    );
}
let mountId = 0;
let active: { controller: ProfilePanelController; timer: number } | null = null;
export const profilesPanel = {
  mount(canWrite = true) {
    this.unmount();
    const host = document.getElementById('trafira-profiles');
    if (!host) return;
    const generation = mountId;
    let last: ProfileState;
    let transferring = false;
    let preferredSelection = '';
    const createName = E('input', {
      id: 'trafira-profile-create-name',
      type: 'text',
      maxLength: 64,
    }) as HTMLInputElement;
    const renameName = E('input', {
      id: 'trafira-profile-rename-name',
      type: 'text',
      maxLength: 64,
    }) as HTMLInputElement;
    const select = E('select', {
      id: 'trafira-profile-selected',
    }) as HTMLSelectElement;
    const file = E('input', {
      id: 'trafira-profile-import',
      type: 'file',
      accept: '.json,application/json',
    }) as HTMLInputElement;
    const output = E('div', { role: 'status' });
    const message = E('p', { role: 'status' });
    const restoreHint = E('p', { class: 'cbi-value-description' });
    const buttons: HTMLButtonElement[] = [];
    function button(label: string, click: () => void, writer = false) {
      const element = E(
        'button',
        {
          type: 'button',
          class: 'cbi-button cbi-button-action',
          click: () => {
            if (element.disabled || (writer && !canWrite)) return;
            click();
          },
        },
        label,
      ) as HTMLButtonElement;
      buttons.push(element);
      return element;
    }
    function row(label: string, id: string, children: Node[]) {
      const title = E('label', { class: 'cbi-value-title' }, label);
      if (id) (title as HTMLLabelElement).htmlFor = id;
      return E('div', { class: 'cbi-value' }, [
        title,
        E('div', { class: 'cbi-value-field' }, [
          E('div', { class: 'trafira-profile-controls' }, children),
        ]),
      ]);
    }
    function notify(value: string, error = false) {
      message.textContent = value;
      message.className = value
        ? 'alert-message ' + (error ? 'warning' : 'notice')
        : '';
    }
    function selectedEntry() {
      return last?.entries.find((entry) => entry.id === select.value);
    }
    function updateButtons() {
      const disabled = !!(transferring || last?.busy || last?.running);
      for (const b of buttons) b.disabled = disabled;
      const selected = selectedEntry();
      const usable = !!selected && !selected.invalid;
      create.disabled ||=
        !canWrite || !createName.value.trim() || last?.entries.length >= 8;
      rename.disabled ||=
        !canWrite ||
        !usable ||
        !renameName.value.trim() ||
        renameName.value.trim() === selected?.name;
      remove.disabled ||= !canWrite || !selected;
      review.disabled ||= !usable;
      apply.disabled ||=
        !canWrite ||
        !usable ||
        !last?.preview?.applicable ||
        !last.preview.digest ||
        last.preview.id !== select.value;
      restore.disabled ||= !canWrite || !last?.canRestore || !last.digest;
      exportButton.disabled ||= !canWrite || !usable;
      const upload = file.files?.[0];
      importButton.disabled ||=
        !canWrite || !upload || !upload.size || upload.size > MAX_FILE;
      file.disabled = disabled || !canWrite;
      select.disabled = disabled || !last?.entries.length;
      createName.disabled = disabled || !canWrite;
      renameName.disabled = disabled || !canWrite || !usable;
      restoreHint.textContent =
        last?.canRestore === false
          ? _('No previous configuration is available to restore.')
          : '';
    }
    async function submit(request: ProfileRequest, refresh = false) {
      notify('');
      const accepted = await controller.submit(request);
      if (!accepted?.success || generation !== mountId) return;
      if (!refresh) return;
      preferredSelection =
        request.action === 'remove' ? '' : accepted.id || select.value;
      if (request.action === 'create') createName.value = '';
      await controller.submit({ action: 'list' });
      if (generation !== mountId || last.error) return;
      const notices: Record<string, string> = {
        create: _('Profile created.'),
        rename: _('Profile renamed.'),
        remove: _('Profile deleted.'),
      };
      if (notices[request.action]) notify(notices[request.action]);
    }
    const create = button(
      _('Create profile from saved settings'),
      () => {
        void submit({ action: 'create', name: createName.value.trim() }, true);
      },
      true,
    );
    const refresh = button(_('Refresh profiles'), () => {
      void submit({ action: 'list' });
    });
    const rename = button(
      _('Rename profile'),
      () => {
        void submit(
          { action: 'rename', id: select.value, name: renameName.value.trim() },
          true,
        );
      },
      true,
    );
    const review = button(_('Show differences'), () => {
      void submit({ action: 'preview', id: select.value });
    });
    const apply = button(
      _('Apply profile'),
      () => {
        if (!confirmConfigurationReplacement()) return;
        notify('');
        void controller.applyReviewed(select.value);
      },
      true,
    );
    const restore = button(
      _('Restore previous settings'),
      () => {
        if (!confirmConfigurationReplacement()) return;
        void submit({ action: 'restore', digest: last.digest });
      },
      true,
    );
    const remove = button(
      _('Delete profile'),
      () => {
        if (
          window.confirm(
            _(
              'Delete the selected saved profile? Current settings will remain unchanged.',
            ),
          )
        )
          void submit({ action: 'remove', id: select.value }, true);
      },
      true,
    );

    async function transfer(kind: 'import' | 'export') {
      if (!canWrite || transferring || last.busy || last.running) return;
      const chosenId = select.value;
      transferring = true;
      notify(_('Transferring profile'));
      updateButtons();
      let transferId = '';
      try {
        if (kind === 'import') {
          const selected = file.files?.[0];
          if (!selected || !selected.size || selected.size > MAX_FILE)
            throw new Error('invalid_file');
          const bytes = new Uint8Array(await selected.arrayBuffer());
          if (!bytes.length || bytes.length > MAX_FILE)
            throw new Error('invalid_file');
          if (generation !== mountId) throw new Error('closed');
          const begin = await command({ action: 'import_begin' });
          requireSuccess(begin);
          if (typeof begin.id !== 'string' || !begin.id)
            throw new Error('transfer_failed');
          transferId = begin.id;
          for (let offset = 0; offset < bytes.length; offset += 12288) {
            if (generation !== mountId) throw new Error('closed');
            requireSuccess(
              await command({
                action: 'import_chunk',
                id: transferId,
                offset,
                data: encode(bytes.slice(offset, offset + 12288)),
              }),
            );
          }
          if (generation !== mountId) throw new Error('closed');
          const imported = await command({
            action: 'import_finish',
            id: transferId,
          });
          requireSuccess(imported);
          if (generation !== mountId) return;
          preferredSelection =
            typeof imported.id === 'string' ? imported.id : chosenId;
          file.value = '';
          await controller.submit({ action: 'list' });
        } else {
          if (!selectedEntry() || selectedEntry()?.invalid)
            throw new Error('profile_unavailable');
          const begin = await command({ action: 'export_begin', id: chosenId });
          requireSuccess(begin);
          if (typeof begin.id !== 'string' || !begin.id)
            throw new Error('transfer_failed');
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
            requireSuccess(part);
            if (typeof part.data !== 'string' || typeof part.done !== 'boolean')
              throw new Error('transfer_failed');
            const bytes = decode(part.data);
            chunks.push(bytes);
            offset += bytes.length;
            if (offset > MAX_FILE || !bytes.length)
              throw new Error('transfer_failed');
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
          try {
            const link = document.createElement('a');
            link.href = url;
            link.download = 'trafira-profile.json';
            link.click();
          } finally {
            URL.revokeObjectURL(url);
          }
        }
        if (generation === mountId && !last.error)
          notify(_('Profile transfer completed'));
      } catch (error) {
        if (generation === mountId) {
          const code =
            error instanceof Error ? error.message : 'transfer_failed';
          notify(
            code === 'invalid_file'
              ? _(
                  'Profile transfer failed. Select a valid JSON file of up to 1 MiB.',
                )
              : profileErrorMessage(code),
            true,
          );
        }
      } finally {
        if (transferId)
          void command({ action: 'transfer_cancel', id: transferId }).catch(
            () => undefined,
          );
        transferring = false;
        if (generation === mountId) updateButtons();
      }
    }
    const importButton = button(
      _('Import profile'),
      () => {
        void transfer('import');
      },
      true,
    );
    const exportButton = button(
      _('Export profile'),
      () => {
        void transfer('export');
      },
      true,
    );
    select.addEventListener('change', () => {
      preferredSelection = select.value;
      renameName.value = selectedEntry()?.name || '';
      notify('');
      controller.invalidatePreview();
      updateButtons();
    });
    createName.addEventListener('input', updateButtons);
    renameName.addEventListener('input', updateButtons);
    file.addEventListener('change', () => {
      const selected = file.files?.[0];
      notify(
        selected && (!selected.size || selected.size > MAX_FILE)
          ? _(
              'Profile transfer failed. Select a valid JSON file of up to 1 MiB.',
            )
          : '',
        !!selected && (!selected.size || selected.size > MAX_FILE),
      );
      updateButtons();
    });
    host.replaceChildren(
      E('h3', {}, _('Configuration profiles')),
      E(
        'p',
        {},
        _(
          'Save up to eight configuration profiles and switch between them. Apply or save form changes before creating a profile.',
        ),
      ),
      ...(!canWrite
        ? [
            E(
              'p',
              { class: 'alert-message notice' },
              _(
                'Read-only access. Configuration changes require write permission.',
              ),
            ),
          ]
        : []),
      message,
      E('h4', {}, _('Create a profile')),
      row(_('Profile name'), createName.id, [createName, create]),
      E('h4', {}, _('Selected profile')),
      row(_('Saved profiles'), select.id, [select, refresh]),
      row('', '', [review, apply]),
      output,
      row(_('New name for selected profile'), renameName.id, [
        renameName,
        rename,
        remove,
      ]),
      E('h4', {}, _('Manage and transfer profiles')),
      row(_('Import a profile file (JSON, up to 1 MiB)'), file.id, [
        file,
        importButton,
      ]),
      row('', '', [exportButton]),
      E(
        'p',
        { class: 'cbi-section-descr' },
        _(
          'Exported profiles contain passwords and keys. Keep the downloaded file private.',
        ),
      ),
      E('h4', {}, _('Previous configuration')),
      row('', '', [restore]),
      restoreHint,
    );
    const controller = new ProfilePanelController(command, (state) => {
      if (generation !== mountId) return;
      if (JSON.stringify(last?.entries) !== JSON.stringify(state.entries)) {
        const chosen = preferredSelection || select.value;
        select.replaceChildren(
          E('option', { value: '' }, _('Select a saved profile')),
          ...state.entries.map((entry) =>
            E(
              'option',
              { value: entry.id },
              entry.name +
                (entry.invalid ? ' (' + _('Invalid profile') + ')' : ''),
            ),
          ),
        );
        select.value = state.entries.some((entry) => entry.id === chosen)
          ? chosen
          : '';
        renameName.value =
          state.entries.find((entry) => entry.id === select.value)?.name || '';
        preferredSelection = '';
      }
      last = state;
      if (state.committed) reloadAfterConfigurationCommit();
      const preview = state.preview;
      output.replaceChildren(
        ...(!state.entries.length && !state.busy && !state.error
          ? [
              E(
                'p',
                {},
                _(
                  'No saved profiles yet. Enter a name and create a profile from the saved configuration.',
                ),
              ),
            ]
          : []),
        ...(state.error
          ? [
              E(
                'p',
                { class: 'alert-message warning' },
                profileErrorMessage(state.error),
              ),
            ]
          : []),
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
        ...(selectedEntry()?.invalid
          ? [
              E(
                'p',
                { class: 'alert-message warning' },
                _(
                  'This saved profile is invalid. Delete it or import a valid file.',
                ),
              ),
            ]
          : []),
        ...(preview
          ? [
              E('h4', {}, _('Profile differences')),
              E(
                'p',
                {},
                _(
                  'Only changed section and option names are shown; values are hidden.',
                ),
              ),
              ...(!preview.applicable
                ? [
                    E(
                      'p',
                      { class: 'alert-message warning' },
                      _(
                        'The profile cannot be used with the current configuration and components.',
                      ),
                    ),
                  ]
                : []),
              ...(preview.changes.length
                ? [
                    E('table', { class: 'table cbi-section-table' }, [
                      E('tr', { class: 'tr table-titles' }, [
                        E('th', { class: 'th' }, _('Section')),
                        E('th', { class: 'th' }, _('Option')),
                        E('th', { class: 'th' }, _('Change')),
                      ]),
                      ...preview.changes.map((change) =>
                        E('tr', { class: 'tr' }, [
                          E('td', { class: 'td' }, change.section),
                          E('td', { class: 'td' }, change.option || '—'),
                          E(
                            'td',
                            { class: 'td' },
                            (
                              {
                                added: _('Added'),
                                removed: _('Removed'),
                                changed: _('Changed'),
                              } as Record<string, string>
                            )[change.change] || _('Changed'),
                          ),
                        ]),
                      ),
                    ]),
                  ]
                : [
                    E(
                      'p',
                      {},
                      _('This profile matches the saved configuration.'),
                    ),
                  ]),
            ]
          : !state.error &&
              !state.running &&
              selectedEntry() &&
              !selectedEntry()?.invalid
            ? [
                E(
                  'p',
                  { class: 'cbi-section-descr' },
                  _('Show differences before applying the selected profile.'),
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
        if (generation === mountId && !last.running && !last.error)
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
