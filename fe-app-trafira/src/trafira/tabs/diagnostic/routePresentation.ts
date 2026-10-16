import type { ExplainDecision, RouteConnection } from './routeExplanation';

export function routeOutcome(
  decision: ExplainDecision,
  connection?: RouteConnection | null,
) {
  if (decision.status === 'indeterminate')
    return {
      title: decision.missing.includes('multiple_destination_routes')
        ? _('The route depends on the server address')
        : _('Cannot determine the route yet'),
      reason: decision.missing.includes('multiple_destination_routes')
        ? routeReason('multiple_destination_routes')
        : _(
            'See what prevented the check below. An incomplete answer does not mean that the website is unavailable.',
          ),
    };
  if (decision.status === 'blocked')
    return {
      title: _('Connection blocked'),
      reason: _('A Trafira rule blocks this connection.'),
    };
  if (decision.status === 'direct')
    return {
      title: _('Direct connection'),
      reason: _(
        'Trafira does not send this connection through a proxy or VPN. Other system VPN and firewall rules may still apply.',
      ),
    };
  const name =
    connection?.label || decision.outbound || _('Selected connection');
  const matched = decision.trace.find(
    (row) => row.index === decision.rule_index,
  );
  return {
    title: _('Via %s').replace('%s', name),
    reason: matched?.origin?.section
      ? _('A rule in section "%s" selected this connection.').replace(
          '%s',
          matched.origin.section,
        )
      : _('This connection is selected by the Trafira routing settings.'),
  };
}

export function routeReason(reason: string): string {
  const messages: Record<string, string> = {
    dns_partial_answer: _(
      'One DNS query did not finish. Results below apply only to the addresses that were returned. Try again to check all addresses.',
    ),
    multiple_destination_routes: _(
      'This website has several server addresses with different routing results. See the result for each address below.',
    ),
    dns_answer_limit: _(
      'This website returned more addresses than can be checked at once. Results below apply only to the displayed addresses. Enter one address in Additional settings to check it separately.',
    ),
    dns_timeout: _(
      'The configured DNS server did not respond in time. Try again, or enter a known real server IP in Additional settings.',
    ),
    dns_no_address: _(
      'The configured DNS server returned no usable address for this website and selected IP family. Check the website name or enter a known real IP in Additional settings.',
    ),
    dns_fakeip: _(
      'DNS returned a virtual FakeIP instead of a real server address. The address cannot be used to check IP rules. Restart Trafira after updating, or enter a known real IP in Additional settings.',
    ),
    dns_unavailable: _(
      'Automatic address lookup is unavailable in the running configuration. Restart Trafira after updating, or enter a known real IP in Additional settings.',
    ),
    dns_failed: _(
      'The configured DNS server could not resolve this website. Try again, or enter a known real IP in Additional settings.',
    ),
    legacy_router_output_rules: _(
      'Router application routing is disabled. Select a LAN device to check its route. To analyze router applications, Router application routing must be enabled and applied in Settings. Other firewall and system VPN routes are not calculated here.',
    ),
    router_destination_address_needed: _(
      'The server IP could not be determined automatically. Try again, or enter a known real destination IP in Additional settings.',
    ),
    incoming_interface_missing: _(
      'Select a detected device, or enter its incoming interface, usually br-lan, under Device MAC and incoming interface.',
    ),
    alice_device_details_missing: _(
      'Device routing needs this device MAC or incoming interface. Select a detected device, or enter the missing details.',
    ),
    applied_capture_state_unavailable: _(
      'The applied routing state is unavailable. Start Trafira and try again.',
    ),
    router_settings_not_applied: _(
      'Router application routing has not been applied. Save and apply the Trafira settings first.',
    ),
    router_capture_not_running: _(
      'Router application routing is not active. Restart Trafira and try again.',
    ),
    router_bootstrap_snapshot_unavailable: _(
      'Router routing data is unavailable. Restart Trafira and try again.',
    ),
    local_destination_check_nft_exclusions: _(
      'This is a local destination. Its route depends on the router firewall exclusions.',
    ),
    wifi_calling_bypass_depends_on_real_destination: _(
      'Wi-Fi Calling bypass depends on the real destination IP. Enter it in the form above.',
    ),
    wifi_calling_bypass: _(
      'This UDP connection is excluded from Trafira interception by Wi-Fi Calling bypass.',
    ),
    ntp_bypass: _(
      'This UDP 123 connection is excluded from Trafira interception by NTP bypass.',
    ),
    ntp_bypass_depends_on_real_destination: _(
      'Enter the real destination IP to check the NTP bypass for this packet.',
    ),
    packet_address_family_mismatch: _(
      'For this UDP bypass check, select a device address in the same IP family as the destination: IPv4 with IPv4, or IPv6 with IPv6.',
    ),
    fakeip_is_not_real_destination: _(
      'The entered address is a FakeIP. Enter the real destination IP instead.',
    ),
    alice_bypass: _(
      'Device routing sends this device directly, bypassing Trafira.',
    ),
    interface_not_captured: _(
      'Trafira does not intercept traffic from this incoming interface.',
    ),
    router_bootstrap_dns: _(
      'This DNS connection is excluded from router application routing.',
    ),
    router_bootstrap_ntp: _(
      'This time synchronization connection is excluded from router application routing.',
    ),
    router_vpn_transport: _(
      'This VPN transport connection is excluded to prevent a routing loop.',
    ),
    destination_ip: _(
      'An earlier rule checks destination addresses. Enter the real destination IP in the form above and check again.',
    ),
    source_ip: _('Enter the device IP address, or select a detected device.'),
    source_mac_address: _(
      'Enter the device MAC address under Device MAC and incoming interface.',
    ),
    protocol: _(
      'An earlier rule checks the application protocol. Select the protocol to continue.',
    ),
    evaluation_limit: _(
      'The rule set is too complex to evaluate within the diagnostic limits.',
    ),
    ruleset_decode_failed: _(
      'sing-box could not export a saved list for this calculation. Some binary lists, including AdGuard lists, cannot be exported. Downloading the same copy again may not help.',
    ),
    ruleset_changed: _('A saved list changed during the check. Try again.'),
    ruleset_decode_timeout: _(
      'This saved list could not be decoded within its preparation timeout. Its rules were not skipped; the route remains unconfirmed.',
    ),
    ruleset_size_limit: _(
      'This saved list exceeds the diagnostic memory or size budget. Its rules cannot be confirmed.',
    ),
    ruleset_job_timeout: _(
      'Preparation reached the background time budget before this list could be processed. Try again to reuse already prepared lists.',
    ),
    ruleset_limit: _(
      'Some lists exceed the diagnostic size or time limits. Their rules cannot be confirmed by this check.',
    ),
  };
  if (messages[reason]) return messages[reason];
  if (reason.startsWith('unsupported_action:'))
    return _(
      'This part of the diagnostic cannot simulate a configured action. This is a limitation of the check, not a connection failure.',
    );
  if (reason.startsWith('rule_set:'))
    return _(
      'A required saved list is missing or unreadable. Download or update copies in Saved rule sets, then try again.',
    );
  if (reason.startsWith('unsupported:') || reason.startsWith('unsupported_'))
    return _(
      'An earlier rule uses a condition this diagnostic cannot evaluate. The route cannot be confirmed.',
    );
  return _(
    'An earlier rule needs additional data. See the rule evaluation details below.',
  );
}

export function routeReasons(
  reasons: string[],
  unavailable: Array<{ tag: string; reason: string }> = [],
): string[] {
  return [
    ...new Set(
      reasons.map((reason) => {
        const detail = reason.startsWith('rule_set:')
          ? unavailable.find((entry) => entry.tag === reason.slice(9))
          : undefined;
        return routeReason(
          detail &&
            [
              'decode_failed',
              'changed',
              'limit',
              'decode_timeout',
              'size_limit',
              'job_timeout',
            ].includes(detail.reason)
            ? `ruleset_${detail.reason}`
            : reason,
        );
      }),
    ),
  ];
}

export function routeError(error: string): string {
  const messages: Record<string, string> = {
    resource_limit: _(
      'The routing check stopped to preserve router memory. Trafira continues running; no route was confirmed. Try again when more memory is available.',
    ),
    timeout: _(
      'The route check exceeded its time limit. The router may still be processing the lists. Wait before trying again.',
    ),
    permission_denied: _(
      'LuCI denied access to the route check. Sign in with an account that has access to Trafira.',
    ),
    command_failed: _(
      'The route diagnostic command failed. Its system output is needed to identify the cause.',
    ),
    rpc_failed: _(
      'LuCI could not receive the route check result. Refresh the page and try again.',
    ),
    invalid_response: _(
      'The route check returned an invalid response. Check that the Trafira backend and LuCI app versions match.',
    ),
    render_failed: _(
      'The route result could not be displayed. Refresh the page; if this repeats, report this display error.',
    ),
    invalid_request: _(
      'Enter a valid domain, destination port and device IP address, or select This router.',
    ),
    configuration_changed_retry: _(
      'The routing configuration changed during the check. Try again.',
    ),
    busy: _(
      'Another route calculation is preparing lists. Wait for it to finish, then try again.',
    ),
    worker_timeout: _(
      'The background route calculation reached its time limit. Already verified lists remain cached for another attempt.',
    ),
    worker_interrupted: _(
      'The background route worker stopped unexpectedly. Try again.',
    ),
    storage_unavailable: _(
      'There is not enough available RAM storage to prepare this route check.',
    ),
    too_many_rule_sets: _(
      'The configuration has more rule sets than this diagnostic can process safely.',
    ),
    configuration_unavailable: _(
      'The sing-box configuration is unavailable. Start Trafira or apply its settings, then try again.',
    ),
  };
  if (
    [
      'timeout',
      'permission_denied',
      'command_failed',
      'rpc_failed',
      'invalid_response',
      'render_failed',
    ].includes(error)
  )
    return `${messages[error]} (${error})`;
  return (
    messages[error] ||
    _('Could not explain route. Check that Trafira is running, then try again.')
  );
}
