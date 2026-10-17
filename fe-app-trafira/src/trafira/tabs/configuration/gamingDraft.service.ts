import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { GamingDraft } from './gamingDraft';

export async function gamingCommand(
  request: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  for (let attempt = 0; ; attempt++) {
    const response = await executeShellCommand({
      command: '/usr/bin/trafira-config',
      args: ['gaming_preset_action', JSON.stringify(request)],
      timeout: 30000,
    });
    if (response.code) throw Error('request_failed');
    const result = JSON.parse(response.stdout);
    if (result?.success === true) return result;
    // Only repeat a read. A mutation must never be replayed automatically.
    if (
      request.action === 'catalog' &&
      result?.error === 'busy' &&
      attempt < 2
    ) {
      await new Promise((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
      continue;
    }
    throw Error(
      typeof result?.error === 'string' ? result.error : 'request_failed',
    );
  }
}
export const gamingDraft = new GamingDraft((sections, operations) =>
  gamingCommand({ action: 'plan', sections, operations }),
);
