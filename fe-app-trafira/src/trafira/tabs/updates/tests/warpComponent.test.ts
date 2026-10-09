import { describe, expect, it } from 'vitest';
import { warpActions } from '../warpComponent';
describe('WARP optional family actions', () => {
  it('does not offer installation without a compatible release', () => {
    expect(warpActions(false, null)).toEqual(['check_update']);
    expect(warpActions(false, 'unavailable')).toEqual(['check_update']);
  });
  it('only installs after a verified release check', () => {
    expect(warpActions(false, 'outdated')).toEqual(['check_update', 'install']);
    expect(warpActions(true, 'latest')).toEqual(['check_update', 'remove']);
    expect(warpActions(true, 'outdated')).toEqual([
      'check_update',
      'install',
      'remove',
    ]);
  });
});
