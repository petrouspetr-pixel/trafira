import { validateDomain } from './validateDomain';
import { isIPv4, isIPv6 } from './validateIp';

export type ParsedHostPort = {
  host: string;
  port: string;
};

export function unbracketHost(host: string): string {
  if (host.startsWith('[') && host.endsWith(']')) {
    return host.slice(1, -1);
  }

  return host;
}

export function isValidHost(host: string): boolean {
  const normalizedHost = unbracketHost(host);

  if (isIPv4(normalizedHost) || isIPv6(normalizedHost)) {
    return true;
  }

  // A connection address is a host, not a URL or a domain/path expression.
  if (
    /[\s\\/?#@:%[\]]/.test(normalizedHost) ||
    [...normalizedHost].some(
      (char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127,
    )
  ) {
    return false;
  }

  // Some providers publish DNS server labels with underscores. Check their
  // shape without changing the saved address or relaxing TLD/domain rules.
  const labels = normalizedHost.split('.');
  const domainForValidation = labels
    .map((label, index) =>
      index < labels.length - 1 ? label.replace(/_/g, 'a') : label,
    )
    .join('.');
  return validateDomain(domainForValidation).valid;
}

export function isValidPort(port: unknown): boolean {
  const normalized = String(port ?? '');
  const value = Number(normalized);
  return /^\d+$/.test(normalized) && value >= 1 && value <= 65535;
}

export function parseHostPort(value: string): ParsedHostPort | null {
  if (!value) {
    return null;
  }

  if (value.startsWith('[')) {
    const end = value.indexOf(']');
    if (end <= 1 || value.slice(end + 1, end + 2) !== ':') {
      return null;
    }

    const parsed = {
      host: value.slice(1, end),
      port: value.slice(end + 2),
    };
    return isValidHost(parsed.host) ? parsed : null;
  }

  const firstColon = value.indexOf(':');
  const lastColon = value.lastIndexOf(':');
  if (firstColon < 0 || firstColon !== lastColon) {
    return null;
  }

  const parsed = {
    host: value.slice(0, firstColon),
    port: value.slice(firstColon + 1),
  };
  return isValidHost(parsed.host) ? parsed : null;
}
