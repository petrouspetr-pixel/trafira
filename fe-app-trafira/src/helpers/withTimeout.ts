import { logger } from '../trafira/services/logger.service';

export async function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  operationName: string,
  timeoutMessage = _('Operation timed out'),
): Promise<T> {
  let timeoutId;
  const start = performance.now();

  const timeoutPromise = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(() => {
      const error = new Error(timeoutMessage);
      error.name = 'TimeoutError';
      reject(error);
    }, timeoutMs);
  });

  try {
    return await Promise.race([promise, timeoutPromise]);
  } finally {
    clearTimeout(timeoutId);
    const elapsed = performance.now() - start;
    logger.info('[SHELL]', `[${operationName}] took ${elapsed.toFixed(2)} ms`);
  }
}
