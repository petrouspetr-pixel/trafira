# Audit fixes implementation plan

> For agentic workers: use subagent-driven-development for independent tasks and review each result.

**Goal:** Correct all six defects confirmed in the comparison with Gavr1024 and Screamshow, without a release.
**Architecture:** Preserve existing runtime interfaces and version compatibility. Make destructive update steps transactional, retain rollback data, preserve external DNS changes, and split independent route alternatives.
**Tech Stack:** ucode, BusyBox shell, OpenWrt apk/opkg, sing-box, shell regression tests.
**Spec:** User-approved six findings in this conversation on 2026-09-30, based on Trafira main 375eef55.

## Global constraints
- No releases, tags, router changes, or upstream Forkop writes.
- Preserve checksum verification, storage preflight, and older sing-box support.
- Do not blindly transplant fork-specific features or weaken installation safety.

## Review focus
- Upgrade versus remove must preserve manually installed compressed binaries only for replacement.
- Offline or partial list downloads must leave prior materialized rules intact.
- Failed package installation must restore the exact staged prior package without a network fetch.
- DNS rollback must preserve external changes and propagate actual failures.
- Mixed domain/address lists must preserve both routing alternatives and DNS semantics on old and new sing-box.

## Tasks
- [ ] Add failing regression tests for service/package.uc upgrade preservation and dns/apply.uc rollback ownership/errors; implement scoped fixes and review.
- [ ] Add failing generator/rule-set tests for inline-plus-list OR matching and mixed DNS list handling; preserve source/port filters and legacy versions; implement and review.
- [ ] Add failing component action tests for offline rollback from Tiny/stable/Extended; stage exact previous packages before stopping/removing; validate dependencies and space; implement and review.
- [ ] Add failing list-update transaction test for successful existing list followed by partial/failed replacement; stage and atomically publish per-section lists with preserved nft consistency; implement and review.
- [ ] Run full backend CI and ShellCheck; run official sing-box runtime probes; obtain independent final review.
- [ ] Merge checked code into Trafira main, verify final CI and clean checkout. Do not release.

## Execution ledger
- Reusing the clean task-specific checkout on a new branch. Parallel tasks own disjoint production modules; root integrates tests and CI.
