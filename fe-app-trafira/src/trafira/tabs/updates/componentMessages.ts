import type { Trafira } from '../../types';

export function componentSuccessMessage(
  result: Pick<Trafira.ComponentActionResult, 'component' | 'action'>,
) {
  const names: Record<Trafira.ComponentName, string> = {
    trafira: 'Trafira',
    sing_box: 'sing-box',
    zapret: 'Zapret',
    zapret2: 'Zapret2',
    byedpi: 'ByeDPI',
  };
  const variants: Partial<Record<Trafira.ComponentAction, string>> = {
    install_stable: 'sing-box',
    install_tiny: 'sing-box-tiny',
    install_extended: 'sing-box-extended',
    install_extended_compressed: 'sing-box-extended compressed',
  };
  const name = variants[result.action] || names[result.component];
  return (
    result.action === 'remove'
      ? _('%s has been removed')
      : _('%s has been installed')
  ).replace('%s', name);
}

// Translate at presentation time: raw errors are also used to detect pending jobs
// and transient RPC failures. Keep additional package-manager details intact.
export function componentErrorMessage(message: string) {
  const translations: Record<string, string> = {
    'Failed to execute': _('Failed to execute'),
    'Failed to create temporary directory': _(
      'Failed to create temporary directory',
    ),
    'Failed to update package lists': _('Failed to update package lists'),
    'Failed to install Trafira release packages': _(
      'Failed to install Trafira release packages',
    ),
    'Failed to install Trafira package': _('Failed to install Trafira package'),
    'Failed to install LuCI app package': _(
      'Failed to install LuCI app package',
    ),
    'Failed to install LuCI Russian i18n package': _(
      'Failed to install LuCI Russian i18n package',
    ),
    'Failed to install sing-box-extended packages': _(
      'Failed to install sing-box-extended packages',
    ),
    'Failed to download Trafira release packages': _(
      'Failed to download Trafira release packages',
    ),
    'Failed to check Trafira updates': _('Failed to check Trafira updates'),
    'Another component action is already running': _(
      'Another component action is already running',
    ),
    'Component action job is stale or the worker process exited unexpectedly':
      _(
        'Component action job is stale or the worker process exited unexpectedly',
      ),
    'Unpin the core before changing its variant': _(
      'Unpin the core before changing its variant',
    ),
    'Pinned core is unavailable from its configured source': _(
      'Pinned core is unavailable from its configured source',
    ),
  };
  for (const [source, translated] of Object.entries(translations)) {
    if (message === source || message.startsWith(source + ':'))
      return translated + message.slice(source.length);
  }
  if (Object.values(translations).includes(message)) return message;
  const fallback = _('Failed to execute component action');
  return message ? fallback + ': ' + message : fallback;
}
