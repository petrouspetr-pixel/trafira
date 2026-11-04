type Item = Record<string, unknown>;
const object = (value: unknown): Item =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Item)
    : {};
const text = (value: unknown, maximum = 512) =>
  typeof value === 'string' ? value.slice(0, maximum) : '';
const caption = (
  labels: Record<string, string>,
  key: string,
  fallback: string,
) =>
  Object.prototype.hasOwnProperty.call(labels, key) ? labels[key] : fallback;
export function renderProfileDependencies(value: unknown): HTMLElement {
  const report = object(value);
  if (
    report.schema !== 1 ||
    !Array.isArray(report.files) ||
    !Array.isArray(report.components)
  )
    throw new Error('invalid_response');
  const counts = object(report.counts);
  const kinds: Record<string, string> = {
    settings: _('Settings'),
    section: _('Sections'),
    server: _('Servers'),
    subscription_url: _('Subscriptions'),
    section_interface: _('Interfaces'),
    urltest: 'URLTest',
    priority_group: 'Priority',
    priority_level: _('Priority levels'),
  };
  const names: Record<string, string> = {
    sing_box: 'Sing-box',
    zapret: 'Zapret',
    zapret2: 'Zapret2',
    byedpi: 'ByeDPI',
  };
  const statuses: Record<string, string> = {
    present: _('Found'),
    missing: _('Not found'),
    not_regular: _('Not a regular file'),
    incompatible: _('Incompatible'),
    unknown: _('Not checked'),
  };
  const fileKinds: Record<string, string> = {
    certificate: _('Certificate file'),
    private_key: _('Private key file'),
    rule_set: _('Rule set file'),
    domain_list: _('Domain and IP list file'),
  };
  const warnings: Record<string, string> = {
    custom_json_review: _(
      'Custom JSON may contain additional dependencies. Review it before transferring.',
    ),
    invalid_custom_json: _(
      'Some custom JSON is invalid and could not be inspected.',
    ),
    strategy_files_review: _(
      'Check external files referenced by custom component strategies separately.',
    ),
    inspection_limited: _(
      'The inspection limit was reached. Some dependencies are not listed.',
    ),
    invalid_path: _(
      'Some file paths are invalid and were omitted from this report.',
    ),
  };
  function table(headers: string[], rows: Array<Array<string>>) {
    return E('table', { class: 'table cbi-section-table' }, [
      E('thead', {}, [
        E(
          'tr',
          { class: 'tr table-titles' },
          headers.map((h) => E('th', { class: 'th' }, h)),
        ),
      ]),
      E(
        'tbody',
        {},
        rows.map((cells) =>
          E(
            'tr',
            { class: 'tr' },
            cells.map((c) => E('td', { class: 'td' }, c)),
          ),
        ),
      ),
    ]);
  }
  const components = report.components
    .slice(0, 4)
    .map(object)
    .filter((c) => Object.prototype.hasOwnProperty.call(names, text(c.id)));
  const files = report.files
    .slice(0, 64)
    .map(object)
    .filter((f) => text(f.path).startsWith('/'));
  return E('div', {}, [
    E('h4', {}, _('Profile dependencies')),
    E(
      'p',
      { class: 'cbi-value-description' },
      _(
        'Checked against this router. File contents and live connections are not checked.',
      ),
    ),
    E(
      'p',
      {},
      _('Missing or incompatible required dependencies:') +
        ' ' +
        (Number.isSafeInteger(report.missing) ? report.missing : '—'),
    ),
    E(
      'p',
      {},
      Object.keys(kinds)
        .filter((k) => Number.isSafeInteger(counts[k]) && Number(counts[k]) > 0)
        .map((k) => kinds[k] + ': ' + Number(counts[k]))
        .join(' · '),
    ),
    table(
      [_('Component'), _('Version'), _('State'), _('Required')],
      components.map((c) => [
        names[text(c.id)],
        text(c.version, 96) || '—',
        caption(statuses, text(c.status), statuses.unknown),
        c.required === true
          ? c.requirement === 'extended'
            ? _('Extended required')
            : _('Yes')
          : _('Inactive settings'),
      ]),
    ),
    ...(files.length
      ? [
          table(
            [_('File'), _('Purpose'), _('State'), _('Required')],
            files.map((f) => [
              text(f.path),
              caption(fileKinds, text(f.kind), _('External file')),
              caption(statuses, text(f.status), statuses.unknown),
              f.required === true ? _('Yes') : _('Inactive settings'),
            ]),
          ),
        ]
      : [E('p', {}, _('No known external files are referenced.'))]),
    E(
      'p',
      { class: 'cbi-value-description' },
      _(
        'The JSON profile includes settings, not packages or external files. Transfer those separately.',
      ),
    ),
    ...Array.from(
      new Set(
        Array.isArray(report.warnings)
          ? report.warnings.filter(
              (w) =>
                typeof w === 'string' &&
                Object.prototype.hasOwnProperty.call(warnings, w),
            )
          : [],
      ),
    )
      .slice(0, 8)
      .map((w) =>
        E('p', { class: 'alert-message warning' }, warnings[String(w)]),
      ),
  ]);
}
