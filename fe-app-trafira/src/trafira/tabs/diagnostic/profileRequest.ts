import { executeShellCommand } from '../../../helpers/executeShellCommand';

export async function callProfileCommand<T extends { action: string }>(
  request: T,
): Promise<Record<string, unknown>> {
  const readOnly = request.action === 'list' || request.action === 'status';
  for (let attempt = 0; ; attempt++) {
    const result = await executeShellCommand({
      command: '/usr/bin/trafira-config',
      args: ['profile_action', JSON.stringify(request)],
      timeout: 30000,
    });
    let parsed: Record<string, unknown> | null = null;
    try {
      const value: unknown = JSON.parse(result.stdout);
      if (value && typeof value === 'object' && !Array.isArray(value))
        parsed = value as Record<string, unknown>;
    } catch {
      /* RPC/permission failures may have no JSON body. */
    }
    if (
      readOnly &&
      attempt === 0 &&
      (result.failure === 'rpc' ||
        result.failure === 'timeout' ||
        parsed?.error === 'busy')
    ) {
      await new Promise<void>((resolve) => setTimeout(resolve, 250));
      continue;
    }
    if (
      parsed &&
      typeof parsed.success === 'boolean' &&
      (!result.code || parsed.success === false)
    )
      return parsed;
    throw new Error(result.failure || 'invalid_response');
  }
}
