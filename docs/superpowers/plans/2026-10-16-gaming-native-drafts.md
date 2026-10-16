# Gaming presets native drafts Implementation Plan

Goal: fix shared-device routing and stage all preset operations for native LuCI Save/Apply.
Architecture: pure backend planner plus client operation queue, native map hooks and existing UCI sections.
Tech stack: ucode, TypeScript, LuCI form/uci, Vitest, runtime/network CI.
Spec: docs/superpowers/specs/2026-10-16-gaming-native-drafts-design.md

Constraints: no release; no router installation or configuration changes; preserve manual rules and secrets, native permissions and edited-rule protection.

Review focus: multiple platforms and priorities on overlapping IPv4/IPv6 hosts; no restart before Apply; pending state across tab changes and Reset; Save retry and ordinary form edits; readonly planning cannot mutate UCI/runtime.

- [ ] Backend: add failing combined-platform/legacy ordering and read-only batch tests; implement group ordering, pure batch planner and ACL routing; run runtime CI.
- [ ] Frontend: add failing draft queue, Save/Reset/failed-save integration and editor tests; implement adapter, queued operations and native map hooks; remove obsolete per-preset apply UI/polling.
- [ ] UX/RU: simple Add/Edit/Delete draft controls, human conflict explanations, synchronized catalogs and production bundle.
- [ ] Verification: full frontend suite/lint/typecheck, backend ordinary+compacted runtime and network CI, native map simulation, independent review; preserve no-deploy scope.

Ledger: User specified the full save/apply interaction; proceed with standard LuCI and no additional confirmation. Backend and frontend implementation can be worked independently against the agreed batch contract.
