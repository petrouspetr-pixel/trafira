import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { GamingDraft } from './gamingDraft';

export async function gamingCommand(
  request: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const response = await executeShellCommand({
    command: '/usr/bin/trafira-config',
    args: ['gaming_preset_action', JSON.stringify(request)],
    timeout: 30000,
  });
  if (response.code) throw Error('request_failed');
  const result = JSON.parse(response.stdout);
  if (!result || result.success !== true)
    throw Error(
      typeof result?.error === 'string' ? result.error : 'request_failed',
    );
  return result;
}
export const gamingDraft = new GamingDraft((sections, operations) =>
  gamingCommand({ action: 'plan', sections, operations }),
);
