import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { routeError, routeReason, routeReasons } from '../routePresentation';

beforeEach(() => vi.stubGlobal('_', (text: string) => text));
afterEach(() => vi.unstubAllGlobals());

describe('route explanation messages', () => {
  it('gives the router scenario an actionable destination hint', () => {
    expect(routeReason('legacy_router_output_rules')).toContain(
      'Select a LAN device',
    );
    expect(routeReason('router_destination_address_needed')).toContain(
      'real destination IP',
    );
    expect(routeReason('incoming_interface_missing')).toContain('br-lan');
  });
  it('groups unavailable lists into one useful instruction', () => {
    expect(routeReasons(['rule_set:one', 'rule_set:two'])).toEqual([
      'A required saved list is missing or unreadable. Download or update copies in Saved rule sets, then try again.',
    ]);
  });
  it('does not expose unknown condition names or raw command errors', () => {
    expect(routeReason('unsupported:private_value')).not.toContain(
      'private_value',
    );
    expect(routeError('token=secret')).not.toContain('secret');
    expect(routeError('configuration_changed_retry')).toContain('Try again');
  });
  it('distinguishes a decoder failure from a missing download', () => {
    const messages = routeReasons(
      ['rule_set:ads'],
      [{ tag: 'ads', reason: 'decode_failed' }],
    );
    expect(messages[0]).toContain('AdGuard');
    expect(messages[0]).not.toContain('Download or update');
  });
  it.each([
    ['timeout', 'time limit'],
    ['permission_denied', 'access'],
    ['command_failed', 'command'],
    ['rpc_failed', 'LuCI'],
    ['invalid_response', 'invalid response'],
    ['render_failed', 'display'],
  ])('shows a safe useful explanation for %s', (category, fragment) => {
    expect(routeError(category)).toContain(fragment);
    expect(routeError(category)).toContain(`(${category})`);
  });
});
