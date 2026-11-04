# Profile dependency check implementation plan

> For agentic workers: use superpowers:executing-plans for inline execution. The user approved a small first stage of issue #105.

**Goal:** Let an administrator check a selected saved profile for known external file and component dependencies before transferring it, without creating backups or applying settings.

**Architecture:** A bounded ucode inspector accepts a validated profile and read-only environment probes. A privileged `profile_action dependencies` endpoint loads the saved profile under its existing reader lock and does not take the global configuration operation lock. LuCI displays a compact native report on explicit request. The existing private JSON profile remains unchanged.

**Tech stack:** ucode, TypeScript, native LuCI E()/tables, existing profile RPC, Vitest and backend CI.

- [x] Add failing tests for missing dependencies, privacy, bounded JSON handling, report permissions, and explicit UI action.
- [x] Add config/profile_dependencies.uc: section counts, required sing-box/DPI components, known certificate/key/local-list paths, optional dependencies of disabled entries, bounded custom JSON inspection and explicit incomplete-analysis warnings. No content reads of referenced files, downloads, execution of profile data, archive creation, or configuration changes.
- [x] Add a writer-only dependency action that bypasses the global mutation lock; preserve existing reader ACL/privacy boundaries.
- [x] Add a native report and Check dependencies button to Profiles. Guard stale results/unmounts; use existing busy state and translate every new message.
- [x] Document private profile vs external files/packages, automatic HWID considerations, caches, transfer limitations and DNS/firewall handover in docs/profile-transfer.md; link it from README.
- [ ] Run frontend checks, backend tests against original/compacted sources, permission and locking checks, independent review and CI. Open a PR without a release or router deployment. Use Refs #105 because cross-stack migration/converters are outside this first stage.
