# Routing check speed and recovery implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, followed by a fresh review.

**Goal:** Faster bounded routing checks, recovery after page refresh, and understandable DNS results.
**Architecture:** Preserve offline routing correctness and memory limits. Avoid DNS-policy re-simulation in background checks, validate missing device details before list processing, reuse per-job file hashes, and avoid redundant core hashing. Make identical active starts idempotent and restore the pending request from tab-scoped browser storage.
**Tech Stack:** ucode, TypeScript, LuCI, Vitest, Bash backend fixtures.
**Spec:** User request on 2026-10-16 and router-route-check-audit-2026-10-16 results outside the source tree.

## Global Constraints
- No release, no router deployment or settings changes.
- No list downloads by diagnostics; retain one-list-at-a-time decoding, bounded cache, worker and memory limits.
- Never invent a confirmed route for missing or unsupported conditions.
- Do not expose a different caller's request when returning an existing job.

## Review Focus
- Cache invalidation after list and executable replacement, including changes during analysis.
- Same active request resumes; a different request remains busy.
- Blocked session storage cannot break manual checks; expired requests do not auto-run.
- DNS lookup success is separate from DNS policy simulation and website reachability.
- instagram.com/facebook.com through AWG and youtube.com through Zapret2 preserve section order and IP rules.

### Task 1: Regression coverage
- [ ] Add failing backend checks for repeated active starts, absent background DNS simulation, core hashing bounds, early device validation, and three requested domains.
- [ ] Add failing frontend checks for restored pending forms, transient polling failures and DNS presentation.
- [ ] Run focused frontend tests and backend CI to record expected failures.

### Task 2: Background calculation
- [ ] Implement same-request job attachment without weakening lock ownership or cleanup.
- [ ] Skip speculative DNS-policy calculation for background checks; keep actual DNS lookup and per-address routing.
- [ ] Remove repeated per-scenario hashes and redundant executable reads, keeping final integrity checks.
- [ ] Avoid repeated cache-directory scans on every hit; retain bounded validation and eviction.

### Task 3: Browser recovery and presentation
- [ ] Persist pending request in sessionStorage with an expiry and restore form on mount.
- [ ] Retry transient status failures against the same job within its original deadline.
- [ ] Label rule actions descriptively; separate DNS lookup result from connection route; translate all added copy.

### Task 4: Verification
- [ ] Run frontend suite, lint, type checks, production bundle checks and translation checks.
- [ ] Run backend runtime tests on readable and compacted source via CI.
- [ ] Review branch, fix findings and report actual evidence; no release or router installation.
