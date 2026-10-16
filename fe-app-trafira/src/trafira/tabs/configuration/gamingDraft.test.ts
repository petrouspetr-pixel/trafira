import { expect, it, vi } from 'vitest';
import {
  GamingDraft,
  projectGamingSections,
  gamingUciChanges,
  type GamingSection,
} from './gamingDraft';

const base = (): GamingSection[] => [
  {
    '.name': 'settings',
    '.type': 'settings',
    gaming_presets_enabled: '1',
    dns_server: ['private'],
  },
  {
    '.name': 'vpn',
    '.type': 'section',
    action: 'connection',
    enabled: '1',
    outbound_jsons: ['secret'],
  },
];
const add = {
  action: 'upsert' as const,
  preset: 'steam',
  device_ips: ['192.0.2.5'],
  proxy_section: 'vpn',
  placement: 'before-device-routes',
};
const store = {
  '.name': 'game_store',
  '.type': 'section',
  preset_owner: 'game_steam_x',
  preset_platform: 'steam',
  action: 'connection',
};
it('stages several operations without writing UCI and saves the batch once', async () => {
  const write = vi.fn();
  const plan = vi.fn(async (sections, operations) => ({
    success: true,
    config: [...sections, ...(operations.length ? [store] : [])],
  }));
  const draft = new GamingDraft(plan);
  draft.bind({ read: base, write });
  await draft.stage(add);
  await draft.stage({ ...add, preset: 'epic' });
  expect(write).not.toHaveBeenCalled();
  const persist = vi.fn(async () => {
    await draft.flush();
  });
  await draft.save(persist);
  expect(persist).toHaveBeenCalledTimes(1);
  expect(plan.mock.calls[plan.mock.calls.length - 1][1]).toHaveLength(2);
  expect(write).toHaveBeenCalledTimes(1);
  expect(draft.pending).toBe(0);
});
it('Reset discards queued operations and cannot resurrect a late planner response', async () => {
  let finish!: (value: unknown) => void;
  const draft = new GamingDraft(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const write = vi.fn();
  draft.bind({ read: base, write });
  const staging = draft.stage(add);
  draft.reset();
  finish({ success: true, config: [...base(), store] });
  await staging;
  expect(draft.pending).toBe(0);
  expect(draft.sections()).toHaveLength(2);
  expect(write).not.toHaveBeenCalled();
});
it('keeps the draft after a failed Save and replans against fresh ordinary edits', async () => {
  let sections = base();
  const write = vi.fn();
  const plan = vi.fn(async (input) => ({
    success: true,
    config: [...input, store],
  }));
  const draft = new GamingDraft(plan);
  draft.bind({ read: () => sections, write });
  await draft.stage(add);
  await expect(
    draft.save(async () => {
      await draft.flush();
      throw Error('save failed');
    }),
  ).rejects.toThrow('save failed');
  expect(draft.pending).toBe(1);
  sections = [{ ...sections[0], alice_mode_enabled: '1' }, sections[1]];
  await draft.save(async () => {
    await draft.flush();
  });
  expect(plan.mock.calls[plan.mock.calls.length - 1][0][0]).toMatchObject({
    alice_mode_enabled: '1',
  });
  expect(draft.pending).toBe(0);
});
it('does not enqueue a rejected plan and never sends unrelated credentials', async () => {
  const draft = new GamingDraft(async () => ({
    success: false,
    error: 'preset_edited',
  }));
  draft.bind({ read: base, write: vi.fn() });
  await expect(draft.stage(add)).rejects.toThrow('preset_edited');
  expect(draft.pending).toBe(0);
  const projected = projectGamingSections(base());
  expect(JSON.stringify(projected)).not.toMatch(/secret|private/);
  expect(base()[1].outbound_jsons).toEqual(['secret']);
});
it('produces only local UCI changes, preserves unprojected options and detects order changes', () => {
  const before = projectGamingSections(base());
  const after = [before[0], store, before[1]];
  const changes = gamingUciChanges(before, after);
  expect(changes.removed).toEqual([]);
  expect(changes.added).toEqual([store]);
  expect(changes.edits).toEqual([]);
  expect(changes.order).toEqual(['settings', 'game_store', 'vpn']);
});

it('serializes Save through editor preparation and retains a cancelled draft', async () => {
  const draft = new GamingDraft(async (input) => ({
    success: true,
    config: input,
  }));
  draft.bind({ read: base, write: vi.fn() });
  let finish!: () => void;
  draft.setPrepare(
    () =>
      new Promise<void>((resolve) => {
        finish = resolve;
      }),
  );
  const persist = vi.fn(async () => {});
  const save = draft.save(persist);
  await expect(draft.save(persist)).rejects.toThrow('busy');
  finish();
  await save;
  expect(persist).toHaveBeenCalledTimes(1);
  draft.setPrepare(async () => {
    throw Error('editor_cancelled');
  });
  await expect(draft.save(persist)).rejects.toThrow('editor_cancelled');
  expect(persist).toHaveBeenCalledTimes(1);
  expect(draft.busy).toBe(false);
});

it('strips LuCI create metadata from managed sections but keeps their fingerprint fields', () => {
  expect(
    projectGamingSections([
      {
        ...store,
        '.create': 'game_store',
        '.index': 3,
        enabled: '1',
        preset_original_digest: 'original',
      },
    ])[0],
  ).toEqual({ ...store, enabled: '1', preset_original_digest: 'original' });
});
