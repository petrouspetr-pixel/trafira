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
- [x] Add failing regression tests for service/package.uc upgrade preservation and dns/apply.uc rollback ownership/errors; implement scoped fixes and review.
- [x] Add failing generator/rule-set tests for inline-plus-list OR matching and mixed DNS list handling; preserve source/port filters and legacy versions; implement and review.
- [ ] Add failing component action tests for offline rollback from Tiny/stable/Extended; stage exact previous packages before stopping/removing; validate dependencies and space; implement and review.
- [x] Add failing list-update transaction test for successful existing list followed by partial/failed replacement; stage and atomically publish per-section lists with no nft changes before successful parsing; implement and review.
- [ ] Run full backend CI and ShellCheck; run official sing-box runtime probes; obtain independent final review.
- [ ] Merge checked code into Trafira main, verify final CI and clean checkout. Do not release.

## Execution ledger
- Reusing the clean task-specific checkout on a new branch. Parallel tasks own disjoint production modules; root integrates tests and CI.

- CI reproduced the six original regression groups before their fixes. Additional review covered source-aware bypass DNS, custom resolver selection, absent UCI options, and stale service markers.
- Official sing-box 1.14.1 loopback probes confirm OR route alternatives, real-answer evaluation followed by FakeIP, dnsmasq local answers for bypass, and rejection of cached FakeIP for bypass. No legacy DNS address-filter warning in these configurations.
- List failures retain the previous materialized JSON. If post-publication nft application fails, restore that JSON and retain a recovery copy if restoration itself fails. This is not a transaction over all nft chunks: chunks already accepted by nft can remain, and the error is reported.
- Arbitrary remote binary rule-set contents are not fetched and classified by the generator; the classification covers the known mixed community lists and locally readable JSON/plain lists.
- Package rollback uses exact installed dependency versions and validates archive metadata/content. Unavailable exact packages cause an early abort. Live OpenWrt package operations have not been performed in this task.