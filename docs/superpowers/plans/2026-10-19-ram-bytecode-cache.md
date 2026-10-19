# Bounded RAM bytecode cache implementation plan

**Goal:** Avoid reparsing hot entry modules without changing installed source payloads or requiring another package.
**Architecture:** Optional core.bytecode.run() holds a nonblocking private cache lock through execution. Four allowlisted entry modules only; exact source and proof copies detect content changes/corruption. Runtime executable identity invalidates ABI. Cache payload <=512 KiB, sources <=128 KiB, compiled files <=128 KiB. Only tmpfs in production, root-owned mode 0700. Low-memory, lock contention, compilation or validation failures immediately fall back to the source dispatcher; application failure is never retried.
**Tech stack:** ucode/fs, existing POSIX compiler invocation, Python isolated integration tests, GitHub Actions ucode runtime.
**Constraints:** No router changes or release. Existing uncommitted features preserved. No mandatory package dependencies. No full-library RAM mirror.

- [ ] Write and run failing isolated cache tests in CI.
- [ ] Implement bytecode helper, dispatch integration and cache security/limits.
- [ ] Verify cold/warm, source/runtime invalidation, corruption, lock contention/crash, permissions, resource limits and no application retry.
- [ ] Benchmark actual integrated dispatch (cache disabled/cold/warm); retain only useful optimization.
- [ ] Run complete backend CI on source and compacted payloads, frontend checks and ShellCheck; document limits.
