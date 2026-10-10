import { describe, expect, it } from 'vitest';
import {
  parseRouteExplanationResult,
  RouteExplanationError,
} from '../routeExplanation';

const valid = {
  success: true,
  decision: {
    status: 'indeterminate',
    trace: [],
    missing: ['router_destination_address_needed'],
  },
  limitations: ['scenario_not_packet_capture'],
};
function parse(result: {
  stdout: string;
  code?: number;
  failure?: string;
  stderr?: string;
}) {
  return parseRouteExplanationResult(result);
}
function category(result: Parameters<typeof parse>[0]) {
  try {
    parse(result);
  } catch (error) {
    if (error instanceof RouteExplanationError) return error.category;
    throw error;
  }
}
describe('route response boundary', () => {
  it('accepts the router response with its actionable missing-address reason', () => {
    expect(parse({ code: 0, stdout: JSON.stringify(valid) })).toEqual(valid);
  });
  it.each([
    ['timeout', 'timeout'],
    ['permission_denied', 'permission_denied'],
    ['rpc', 'rpc_failed'],
  ])(
    'distinguishes transport %s from a command failure',
    (failure, expected) => {
      expect(
        category({ code: 1, stdout: '', stderr: 'token=secret', failure }),
      ).toBe(expected);
    },
  );
  it('recognizes the strict reader denial while preserving ordinary command failures', () => {
    expect(
      category({
        code: 1,
        stdout: '{"success":false,"error":"permission_denied"}',
      }),
    ).toBe('permission_denied');
    expect(
      category({
        code: 2,
        stdout: '',
        stderr: 'https://user:secret@example.org',
      }),
    ).toBe('command_failed');
  });
  it.each([
    '',
    'not-json',
    'null',
    '{}',
    '{"success":true}',
    JSON.stringify({ ...valid, decision: { status: 'direct' } }),
    JSON.stringify({
      ...valid,
      dns_policy: { status: 'direct', trace: 'wrong', missing: [] },
    }),
    'x'.repeat(262145),
  ])('rejects malformed or oversized output before rendering', (stdout) => {
    expect(category({ code: 0, stdout })).toBe('invalid_response');
  });
  it('keeps recognized backend rejections and masks unrecognized details', () => {
    expect(
      parse({
        stdout: '{"success":false,"error":"configuration_changed_retry"}',
      }),
    ).toEqual({ success: false, error: 'configuration_changed_retry' });
    expect(
      category({ stdout: '{"success":false,"error":"token=secret"}' }),
    ).toBe('command_failed');
  });
});
