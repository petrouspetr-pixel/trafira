export function routeReason(reason: string): string {
  const messages: Record<string, string> = {
    legacy_router_output_rules: _(
      'Router application routing is disabled. Select a LAN device to check its route. To analyze router applications, Router application routing must be enabled and applied in Settings. Other firewall and system VPN routes are not calculated here.',
    ),
    router_destination_address_needed: _(
      'Enter the real destination IP in the form above. A domain alone cannot determine the router firewall route.',
    ),
    incoming_interface_missing: _(
      'Select a detected device, or enter its incoming interface, usually br-lan, under Device MAC and incoming interface.',
    ),
    alice_device_details_missing: _(
      'Alice Mode needs this device MAC or incoming interface. Select a detected device, or enter the missing details.',
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
    fakeip_is_not_real_destination: _(
      'The entered address is a FakeIP. Enter the real destination IP instead.',
    ),
    alice_bypass: _(
      'Alice Mode sends this device directly, bypassing Trafira.',
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
    ruleset_limit: _(
      'Some lists exceed the diagnostic size or time limits. Their rules cannot be confirmed by this check.',
    ),
  };
  if (messages[reason]) return messages[reason];
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
            ['decode_failed', 'changed', 'limit'].includes(detail.reason)
            ? `ruleset_${detail.reason}`
            : reason,
        );
      }),
    ),
  ];
}

export function routeError(error: string): string {
  const messages: Record<string, string> = {
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
