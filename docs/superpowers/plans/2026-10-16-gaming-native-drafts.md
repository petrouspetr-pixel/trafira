# Gaming presets native drafts Implementation Plan

Goal: fix shared-device routing and stage all preset operations for native LuCI Save/Apply.
Architecture: pure backend planner plus client operation queue, native map hooks and existing UCI sections.
Tech stack: ucode, TypeScript, LuCI form/uci, Vitest, runtime/network CI.
Spec: docs/superpowers/specs/2026-10-16-gaming-native-drafts-design.md

Constraints: no release; no router installation or configuration changes; preserve manual rules and secrets, native permissions and edited-rule protection.

Review focus: multiple platforms and priorities on overlapping IPv4/IPv6 hosts; no restart before Apply; pending state across tab changes and Reset; Save retry and ordinary form edits; readonly planning cannot mutate UCI/runtime.

- [x] Backend: add failing combined-platform/legacy ordering and read-only batch tests; implement group ordering, pure batch planner and ACL routing; run runtime CI.
- [x] Frontend: add failing draft queue, Save/Reset/failed-save integration and editor tests; implement adapter, queued operations and native map hooks; remove obsolete per-preset apply UI/polling.
- [x] UX/RU: simple Add/Edit/Delete draft controls, human conflict explanations, synchronized catalogs and production bundle.
- [ ] Verification: full frontend suite/lint/typecheck, backend ordinary+compacted runtime and network CI, native map simulation, independent review; preserve no-deploy scope.

Ledger: User specified the full save/apply interaction; proceed with standard LuCI and no additional confirmation. Backend and frontend implementation can be worked independently against the agreed batch contract.

Verification record:
- Frontend: 745 tests passed, lint/typecheck and production bundle contract passed.
- Native map tests model separate UCI caches, parse-before-flush, one Save/Apply, Reset, cancelled/failed Save, retry and private option preservation.
- Independent review found and resolved priority reset and incorrect rollback of deletion markers. Sixteen focused tests passed independently.
- First CI exposed a ucode forward reference; helper order corrected in 5b652025. Repeat CI is recorded on PR #64 (must pass before completion).
- No router mutations, release publication or package installation.
