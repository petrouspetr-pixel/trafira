# Routing tools implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development. Check boxes track reviewed deliverables.

**Goal:** Add the four approved opt-in routing and diagnostics improvements without publishing a release.
**Architecture:** Extend the current UCI route/nft generators and LuCI components. Reuse subscription selection and bounded snapshot storage rather than duplicate selection or download policy.
**Tech Stack:** ucode, nftables, sing-box, LuCI JavaScript, TypeScript/Vitest, shell integration tests.
**Spec:** User-approved scope recorded below.

## Global Constraints / Spec
- BitTorrent bypass and Wi-Fi Calling bypass default off; preserve existing behavior when off.
- Torrent recognition is best effort; encrypted peers and HTTPS trackers are not guaranteed to match. Only intercepted LAN traffic receives the override.
- Wi-Fi Calling excludes UDP destination ports 500/4500 from Trafira interception, without bypassing the system firewall or returning FakeIP traffic directly.
- Subscription preview evaluates unsaved filters against locally cached nodes, with no download, save, or service restart. Return names and outcomes, never credentials or raw outbound configuration.
- Saved list panel reports snapshot presence, sizes and dates, total quota, and offers an asynchronous preparation action. Keep proxy selection, atomic storage and quota protections.
- Russian labels use Alice Mode and дашборд consistently. No router changes, upstream comments, or release publication.

## Review Focus
- Disabled switches leave routing unchanged, including Alice DNS protection.
- IPv4/IPv6 and FakeIP handling cannot create a route leak.
- Unsaved filter previews must agree with runtime filter selection, including mixed include/exclude and invalid regex.
- Missing cache or invalid input returns a clear result without network activity or exposing subscription secrets.
- Snapshot jobs remain serialized, survive UI reload, report failures, and never claim readiness from file existence alone.

## Task 1: Routing bypasses
Files: singbox/route.uc, nft/apply.uc, settings.js, default config and state signatures; new tests/routing_bypasses.sh.
- [ ] Pin default-off, rule order, LAN inbound scope, IPv6, UDP port and FakeIP exceptions in tests.
- [ ] Implement exclude_bittorrent and exclude_wifi_calling using existing bool/settings conventions.
- [ ] Add localized opt-in flags and truthful descriptions; run targeted tests and review diff.

## Task 2: Subscription preview
Files: new subscription preview helper/CLI module and tests, section.js filter UI; reuse singbox selection helpers.
- [ ] Pin include/exclude/mixed/disabled and protocol/transport/security filters plus missing cache/malformed requests with fixtures.
- [ ] Implement bounded JSON request and read-only cached preview, names/reasons only.
- [ ] Add preview button reading unsaved form values; show counts, exclusions and explicit unavailable cache state.
- [ ] Verify preview/runtime parity and UI escaping/error handling.

## Task 3: Saved rule-set panel
Files: singbox/ruleset_cache.uc reporting helper, components/updates.uc action, diagnostic panel and tests.
- [ ] Pin missing/present snapshots, unsupported core, quota/report privacy and worker failure/serialization.
- [ ] Add status report and background preparation through existing process/action architecture.
- [ ] Render sizes/dates/status and manual preparation without blocking LuCI or restarting service.
- [ ] Verify existing cache tests still pass and new controller tests handle polling/errors.

## Task 4: Integration
Files: CLI dispatch/ACL as needed, locales, README, generated frontend bundle.
- [ ] Wire interfaces after checking their exact contracts; update translations and user documentation.
- [ ] Run all frontend tests, type check, lint, production build; check diff whitespace and generated file consistency.
- [ ] Run Backend CI and Differential ShellCheck with all tests; independently review full diff and resolve findings.
- [ ] Commit, create/attach PR, merge after green checks, verify main; no release.
