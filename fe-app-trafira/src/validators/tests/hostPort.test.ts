import { describe, expect, it } from 'vitest';
import { isValidHost, parseHostPort } from '../hostPort';

const validHosts = [
  'edge_one.example.com',
  '_edge.example.com',
  'edge_.example.com',
  'edge_one.eu_two.example.com',
  'edge_one.xn--p1ai',
  `${'a'.repeat(62)}_.example.com`,
  'EXAMPLE.COM',
  'пример.рф',
  '192.0.2.1',
  '2001:db8::1',
];
const invalidHosts = [
  'bad_host',
  'bad_host..example.com',
  'bad_host.example._om',
  '-bad_host.example.com',
  'bad_host-.example.com',
  `${'a'.repeat(63)}_.example.com`,
  `${Array(4)
    .fill('a'.repeat(62) + '_')
    .join('.')}.com`,
  'bad_host.example.com/path',
  'bad_host.example.com?query',
  'bad_host.example.com#fragment',
  'bad_host.example.com@other.example',
  'bad_host.example.com:443',
  'bad_host.example.com\\path',
  'bad%5fhost.example.com',
  'bad_host.example.com ',
  'bad_host. example.com',
  'bad_host.example.com\n',
  'bad_host.example.com\u0000',
  '999.0.0.1',
];

describe('connection host validation', () => {
  it.each(validHosts)(
    'accepts %s without rewriting the connection address',
    (host) => {
      expect(isValidHost(host)).toBe(true);
      if (!host.includes(':')) {
        expect(parseHostPort(`${host}:443`)).toEqual({ host, port: '443' });
      }
    },
  );
  it.each(invalidHosts)('rejects %s', (host) => {
    expect(isValidHost(host)).toBe(false);
  });
});
