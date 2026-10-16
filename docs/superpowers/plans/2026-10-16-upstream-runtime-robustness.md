# Upstream runtime robustness implementation plan

Goal: close the four code-confirmed Forkop risks in Trafira without a release or router changes.

Architecture: keep DNS listeners fail-closed; store only explicit selector choices in a small atomic persistent file; coalesce list-update requests under a stable lock; prepare missing startup lists with bounded downloads through the configured egress, preserving validated copies and never silently using direct instead of a proxy.

Spec: user request and preceding upstream audit, main 05b25ee5.

Constraints: OpenWrt ucode, no added router dependencies, no private data in logs, no empty list substitutions, preserve all user routing choices. Test on CI, not the physical router. Existing unrelated untracked files must remain.

## Tasks

- [ ] DNS guard: extend singbox/route.uc and backend tests. DNS hijacking precedes reject(source-dns-in); reject precedes routing and is absent without that inbound. Cover TCP/UDP and existing Alice guard.
- [ ] Selector persistence: focused singbox module plus diagnostics/runtime.uc, service/lifecycle.uc and generator.uc integration. Save successful explicit choices atomically, validate current members, fall back for deleted nodes, tolerate malformed state, preserve choices through reboot with RAM cache. Cover failed writes, failed API and API HTTP status.
- [ ] List-update coalescing: components/updates.uc stable request lock/pending marker, drain at most one extra update per pass and keep newly queued changes. Test concurrent request, normal run, failures and owner death. Preserve bounded downloads.
- [ ] Startup rule sets: investigate real sing-box startup ordering, then implement bounded pre-start preparation/fallback that cannot use empty lists or leak via direct. Reuse cached copies; test unavailable first proxy, available alternate, offline with copy, corrupt/missing copy and total timeout.
- [ ] Run backend/network/frontend quality checks and independent review. Integrate only after checks pass; no release or installation.

## Review focus

- Persistent selector file corruption, concurrent writes and deleted/renamed candidates.
- Late update requests at lock-release boundary and aborted owners.
- Proxy privacy, bootstrap DNS dependency cycles and startup process cleanup.
- Offline first boot cannot invent rules; retain a prior valid runtime or fail clearly rather than opening routing.
- Persistent cache quota and memory/time caps remain enforced.
