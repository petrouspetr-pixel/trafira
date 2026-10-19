# Trafira uninstall wizard implementation plan

**Goal:** Provide an SSH removal wizard with a verified backup, separate settings/component choices, and native package-manager cleanup.

**Architecture:** A repository-root POSIX `uninstall.sh` uses Trafira's lifecycle helper before removing registered Trafira packages. Defaults keep settings and components. Purge removes only Trafira configuration/data; the external backup and other services' configuration remain. No automatic dependency cleanup or forced removal. A narrowly scoped lifecycle environment flag preserves managed sing-box binary variants when requested.

**Tech stack:** POSIX sh, apk/opkg, tar/gzip, Python unittest with disposable filesystem and package/service fixtures.

- [x] Add failing integration tests: apk/opkg, keep/purge, components, cancellation/dry-run, backup/cleanup/package failures, repeated calls, unsafe test roots, legacy managed variants.
- [x] Implement wizard and keep-components lifecycle flag. Verify package removal and restore saved configuration on failure.
- [x] Update README with download/run command, defaults, flags, backup and restoration instructions. Add tests to CI.
- [ ] Run fixture tests, shell syntax/static checks, lifecycle contract checks and review the exact deletion paths. Do not run on the physical router, publish or release.

Rulings: keep the helper outside installed backend packages to avoid flash growth. Always retain the verified backup even with --purge. Components are a fixed allowlist; uninstall failure stops further cleanup. Existing uncommitted profile improvements are preserved.

Validation: 21 real-shell fixture tests passed for the standalone script; shell syntax and package_prerm_shell.sh passed. Added a managed-core keep/remove lifecycle fixture to CI; its execution requires ucode, unavailable locally. Exact cleanup targets reviewed. No physical router changes or release.
