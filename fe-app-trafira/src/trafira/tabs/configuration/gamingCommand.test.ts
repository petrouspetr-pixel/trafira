import { afterEach, expect, it, vi } from 'vitest';
import { executeShellCommand } from '../../../helpers/executeShellCommand';
import { gamingCommand } from './gamingDraft.service';

vi.mock('../../../helpers/executeShellCommand', () => ({
  executeShellCommand: vi.fn(),
}));
const reply = (result: unknown) => ({
  code: 0,
  stdout: JSON.stringify(result),
  stderr: '',
});
afterEach(() => {
  vi.useRealTimers();
  vi.resetAllMocks();
});

it('recovers a catalog read after a brief writer without repeating mutations', async () => {
  vi.useFakeTimers();
  vi.mocked(executeShellCommand)
    .mockResolvedValueOnce(reply({ success: false, error: 'busy' }))
    .mockResolvedValueOnce(reply({ success: true, presets: [] }));
  const result = gamingCommand({ action: 'catalog' });
  await vi.runAllTimersAsync();
  await expect(result).resolves.toEqual({ success: true, presets: [] });
  expect(executeShellCommand).toHaveBeenCalledTimes(2);
});

it('stops retrying a catalog while a long operation remains active', async () => {
  vi.useFakeTimers();
  vi.mocked(executeShellCommand).mockResolvedValue(
    reply({ success: false, error: 'busy' }),
  );
  const result = expect(gamingCommand({ action: 'catalog' })).rejects.toThrow(
    'busy',
  );
  await vi.runAllTimersAsync();
  await result;
  expect(executeShellCommand).toHaveBeenCalledTimes(3);
});

it.each(['plan', 'apply', 'remove'])('does not retry %s', async (action) => {
  vi.mocked(executeShellCommand).mockResolvedValue(
    reply({ success: false, error: 'busy' }),
  );
  await expect(gamingCommand({ action })).rejects.toThrow('busy');
  expect(executeShellCommand).toHaveBeenCalledTimes(1);
});

it('does not retry unrelated catalog errors', async () => {
  vi.mocked(executeShellCommand).mockResolvedValue(
    reply({ success: false, error: 'catalog_unavailable' }),
  );
  await expect(gamingCommand({ action: 'catalog' })).rejects.toThrow(
    'catalog_unavailable',
  );
  expect(executeShellCommand).toHaveBeenCalledTimes(1);
});
