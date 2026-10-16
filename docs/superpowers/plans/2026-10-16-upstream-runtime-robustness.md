# Upstream runtime robustness implementation plan

Goal: close the four code-confirmed Forkop risks in Trafira without a release or router changes.

Architecture: keep DNS listeners fail-closed; store only explicit selector choices in a small atomic persistent file; coalesce list-update requests under a stable lock; prepare missing startup lists with bounded downloads through the configured egress, preserving validated copies and never silently using direct instead of a proxy.

Spec: user request and preceding upstream audit, main 05b25ee5.

Constraints: OpenWrt ucode, no added router dependencies, no private data in logs, no empty list substitutions, preserve all user routing choices. Test on CI, not the physical router. Existing unrelated untracked files must remain.

## Tasks

- [x] DNS guard: extend singbox/route.uc and backend tests. DNS hijacking precedes reject(source-dns-in); reject precedes routing and is absent without that inbound. Cover TCP/UDP and existing Alice guard.
- [x] Selector persistence: focused singbox module plus diagnostics/runtime.uc, service/lifecycle.uc and generator.uc integration. Save successful explicit choices atomically, validate current members, fall back for deleted nodes, tolerate malformed state, preserve choices through reboot with RAM cache. Cover failed writes, failed API and API HTTP status.
- [x] List-update coalescing: components/updates.uc stable request lock/pending marker, coalesce requests and hand pending work to a fresh process with a fresh UCI cursor. Test concurrent request, normal run, failures and owner death. Preserve bounded downloads.
- [x] Startup rule sets: investigate real sing-box startup ordering, then implement bounded pre-start preparation/fallback that cannot use empty lists or leak via direct. Reuse cached copies; test unavailable first proxy, available alternate, offline with copy, corrupt/missing copy and total timeout.
- [x] Run backend/network/frontend quality checks and independent review. Integrate only after checks pass; no release or installation.

## Review focus

- Persistent selector file corruption, concurrent writes and deleted/renamed candidates.
- Late update requests at lock-release boundary and aborted owners.
- Proxy privacy, bootstrap DNS dependency cycles and startup process cleanup.
- Offline first boot cannot invent rules; retain a prior valid runtime or fail clearly rather than opening routing.
- Persistent cache quota and memory/time caps remain enforced.

## Verification and rulings

- RED baseline 38895918709: source-dns guard absent; persistent selector module absent. RED 38896290448 and 38896420126: list queue and startup bootstrap absent.
- GREEN source fe103992: Backend CI 38898005577 (all 164 shell-test entries), Differential ShellCheck 38898005446, isolated network CI 38898005396. Network checks use SHA256-pinned real sing-box 1.12.12 for transport and 1.14.2 for actual main startup, including dead default and cached offline startup; direct HTTP counter stays zero. Frontend: 731 tests / 67 files passed locally.
- Independent review caught and closed temporary-disabled selector state pruning, cached UCI reuse, queue storage error reporting, metadata digests, validation supervision, cache quota serialization and publication races for reused old snapshots.
- Ruling: queue repeats in a fresh process so native UCI cursor cannot reuse stale configuration. A stable short gate covers pending marker and worker release.
- Ruling: startup must not silently bypass configured proxy or substitute empty routing lists. It retains verified copies, bounds missing-list preparation to 90 seconds and eight candidate members, and refuses publication if required copies remain unavailable.
- Scope: initial_path preparation applies to sing-box >=1.14. Older cores retain their existing download behavior. Cold preparation does not clone native WireGuard/endpoints (to avoid duplicate interface/peer side effects); those require valid snapshots already available. Existing OS-interface outbounds remain usable.
- No release and no physical router operations were performed.
