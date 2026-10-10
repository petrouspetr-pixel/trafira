import { ExplainReport } from '../routeExplanation';

// Sanitized shape of the 3.0.5 router CLI response: no digest or private tags.
export const routerRouteReport: ExplainReport = {
  success: true,
  generated_at: 1700000000,
  decision: {
    status: 'indeterminate',
    outbound: null,
    trace: [],
    missing: ['router_destination_address_needed'],
  },
  dns_policy: {
    status: 'indeterminate',
    rule_index: 5,
    trace: [
      {
        index: 0,
        match: 'no',
        action: 'reject',
        origin: {
          kind: 'system',
        },
        shadowed: false,
        missing: [],
      },
      {
        index: 1,
        match: 'no',
        action: 'reject',
        origin: {
          kind: 'system',
        },
        shadowed: false,
        missing: [],
      },
      {
        index: 2,
        match: 'no',
        action: 'route',
        origin: {
          kind: 'system',
        },
        shadowed: false,
        missing: [],
      },
      {
        index: 3,
        match: 'no',
        action: 'route',
        origin: {
          kind: 'section',
          section: 'section-1',
          list_tag: 'available-list',
        },
        shadowed: false,
        missing: [],
      },
      {
        index: 4,
        match: 'no',
        action: 'route',
        origin: {
          kind: 'section',
          section: 'section-2',
          list_tag: 'available-list',
        },
        shadowed: false,
        missing: [],
      },
      {
        index: 5,
        match: 'unknown',
        action: 'route',
        origin: {
          kind: 'section',
          section: 'section-2',
          list_tag: 'available-list',
        },
        shadowed: false,
        missing: [
          'rule_set:list-2',
          'rule_set:list-9',
          'rule_set:list-10',
          'rule_set:list-11',
          'rule_set:list-14',
          'rule_set:list-15',
        ],
      },
    ],
    missing: [
      'rule_set:list-2',
      'rule_set:list-9',
      'rule_set:list-10',
      'rule_set:list-11',
      'rule_set:list-14',
      'rule_set:list-15',
    ],
  },
  dns_query: {
    performed: false,
    origin: 'none',
  },
  selector: null,
  rule_sets: {
    basis: 'saved_snapshots',
    live_verified: false,
    available: 13,
    unavailable: 28,
    unavailable_reasons: [
      {
        tag: 'list-1',
        reason: 'limit',
      },
      {
        tag: 'list-2',
        reason: 'limit',
      },
      {
        tag: 'list-3',
        reason: 'limit',
      },
      {
        tag: 'list-4',
        reason: 'limit',
      },
      {
        tag: 'list-5',
        reason: 'limit',
      },
      {
        tag: 'list-6',
        reason: 'limit',
      },
      {
        tag: 'list-7',
        reason: 'limit',
      },
      {
        tag: 'list-8',
        reason: 'limit',
      },
      {
        tag: 'list-9',
        reason: 'limit',
      },
      {
        tag: 'list-10',
        reason: 'limit',
      },
      {
        tag: 'list-11',
        reason: 'limit',
      },
      {
        tag: 'list-12',
        reason: 'limit',
      },
      {
        tag: 'list-13',
        reason: 'limit',
      },
      {
        tag: 'list-14',
        reason: 'limit',
      },
      {
        tag: 'list-15',
        reason: 'limit',
      },
      {
        tag: 'list-16',
        reason: 'limit',
      },
      {
        tag: 'list-17',
        reason: 'limit',
      },
      {
        tag: 'list-18',
        reason: 'limit',
      },
      {
        tag: 'list-19',
        reason: 'limit',
      },
      {
        tag: 'list-20',
        reason: 'limit',
      },
      {
        tag: 'list-21',
        reason: 'limit',
      },
      {
        tag: 'list-22',
        reason: 'limit',
      },
      {
        tag: 'list-23',
        reason: 'limit',
      },
      {
        tag: 'list-24',
        reason: 'limit',
      },
      {
        tag: 'list-25',
        reason: 'limit',
      },
      {
        tag: 'list-26',
        reason: 'limit',
      },
      {
        tag: 'list-27',
        reason: 'limit',
      },
      {
        tag: 'list-28',
        reason: 'limit',
      },
    ],
  },
  limitations: [
    'scenario_not_packet_capture',
    'rule_set_loading_limit',
    'saved_rule_sets_may_differ_from_running_core',
    'router_dns_assumes_local_forwarder',
  ],
};
