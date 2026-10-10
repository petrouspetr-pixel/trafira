import { COMMAND_TIMEOUT } from '../constants';
import { withTimeout } from './withTimeout';

interface ExecuteShellCommandParams {
  command: string;
  args: string[];
  timeout?: number;
}

interface ExecuteShellCommandResponse {
  stdout: string;
  stderr: string;
  code?: number;
}

// Mirror the server read dispatcher for routing only; the dispatcher enforces
// the permission boundary even when callers bypass this helper entirely.
const readCommands: Record<string, number> = {
  check_dns_available: 0,
  check_fakeip: 0,
  check_nft_rules: 0,
  check_zapret_runtime: 0,
  check_zapret2_runtime: 0,
  check_byedpi_runtime: 0,
  check_inbounds_config: 0,
  check_sing_box: 0,
  check_inbounds: 0,
  check_logs: 0,
  check_sing_box_logs: 0,
  get_status: 0,
  get_outbound_metadata: 1,
  get_subscription_metadata: 1,
  get_sing_box_status: 0,
  get_zapret_status: 0,
  get_zapret2_status: 0,
  get_byedpi_status: 0,
  get_system_info: 0,
  get_alice_devices: 0,
  get_server_capabilities: 0,
  get_ui_capabilities: 0,
  get_ui_state: 0,
  service_action_status: 1,
  latency_test_status: 1,
  component_action_status: 1,
  subscription_update_status: 1,
  component_update_check_cache: 0,
  show_version: 0,
  show_sing_box_version: 0,
  show_sing_box_config: 1,
  global_check: 1,
  route_explain: 1,
  subscription_preview: 1,
  get_tls_certificate_sha256: 1,
  failure_policy_status: 0,
  ruleset_snapshot_report: 0,
  validate_nfqws_strategy_json: 1,
  validate_nfqws2_strategy_json: 1,
  validate_byedpi_strategy_json: 1,
};
const readClash: Record<string, number> = {
  get_proxies: 0,
  get_connections: 0,
  get_proxy_latency: 2,
  get_proxy_latencies: 2,
  get_group_latency: 2,
};
const readConfig: Record<string, string[]> = {
  profile_action: ['list', 'status', 'preview', 'export_begin', 'export_read'],
  core_action: ['catalog', 'status'],
  gaming_preset_action: ['catalog', 'status', 'preview', 'preview_remove'],
};
function readCommand(command: string, args: string[]) {
  if (command === '/usr/bin/trafira') {
    if (Object.prototype.hasOwnProperty.call(readCommands, args[0]))
      return args.length <= readCommands[args[0]] + 1;
    return (
      args[0] === 'clash_api' &&
      Object.prototype.hasOwnProperty.call(readClash, args[1]) &&
      args.length <= readClash[args[1]] + 2
    );
  }
  if (
    command !== '/usr/bin/trafira-config' ||
    args.length !== 2 ||
    !Object.prototype.hasOwnProperty.call(readConfig, args[0])
  )
    return false;
  try {
    const request = JSON.parse(args[1]) as { action?: string } | null;
    return (
      !!request &&
      typeof request.action === 'string' &&
      readConfig[args[0]].includes(request.action)
    );
  } catch {
    return false;
  }
}

export async function executeShellCommand({
  command,
  args,
  timeout = COMMAND_TIMEOUT,
}: ExecuteShellCommandParams): Promise<ExecuteShellCommandResponse> {
  if (readCommand(command, args)) command = '/usr/bin/trafira-read';
  try {
    return await withTimeout(
      fs.exec(command, args),
      timeout,
      [command, ...args].join(' '),
    );
  } catch (err) {
    const error = err as Error & { code?: unknown };
    const code = typeof error?.code === 'number' ? error.code : 1;

    return { stdout: '', stderr: error?.message, code };
  }
}
