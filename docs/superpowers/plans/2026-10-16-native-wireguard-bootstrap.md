# Native WireGuard bootstrap

Goal: support cold preparation of missing rule-set snapshots through native WireGuard endpoints without creating conflicting system interfaces or a second live peer. No release or physical router changes.

- [x] Regression: endpoint-only selection, nested selector and proxy-detour dependencies; preserve credentials/peers/address/MTU, clone as userspace with ephemeral port, leave original configuration untouched; reject unsupported endpoint types and cycles.
- [x] Implement endpoint graph support in singbox/ruleset_bootstrap.uc. Keep the existing DNS, time, file size, cache, supervision and metadata protections.
- [x] Detect another running sing-box in the same network namespace before starting a native endpoint bootstrap core. Refuse conflicting preparation; cached startup must still work. Do not duplicate an active native peer.
- [x] Isolated network regression with real sing-box 1.14.2 and a WireGuard server: empty cache download through the encrypted tunnel; zero direct HTTP packets; no temporary system interface; actual main startup with the resulting snapshot; cached/offline startup, failed cold fetch and active-core protection.
- [x] Full backend, frontend and network checks plus independent review, then integrate in main. No release or installation.

The configured native endpoint is changed only in the private temporary configuration: system=false, no name, listen_port=0, no idle keepalive. Cryptographic profile and routing destination stay unchanged. Another active core in the same namespace prevents a duplicate handshake when snapshots are missing.

Validation: frontend 731 tests in 67 files; Backend Runtime Checks 38900403683, Failure Policy Network 38900403483 (real sing-box 1.14.2 + kernel WireGuard server), Differential ShellCheck 38900403583 all passed. Independent review found no actionable issues. No release or router changes.
