import type { Trafira } from '../../types';
export function warpActions(
  installed: boolean,
  status: string | null,
): Trafira.ComponentAction[] {
  const actions: Trafira.ComponentAction[] = ['check_update'];
  if (status === 'outdated') actions.push('install');
  if (installed) actions.push('remove');
  return actions;
}
