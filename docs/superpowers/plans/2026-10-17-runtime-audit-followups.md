# Runtime audit follow-ups implementation plan

Goal: remove redundant validation, recover gaming catalogs after runtime writes, reduce route-check work, and handle GitHub throttling without weakening routing or package checks.

Constraints: no router changes, no package install, no release; preserve unsupported-rule uncertainty, exact rule order, source/IP/port conditions, content/core cache invalidation, resource bounds and fresh install metadata.

1. Snapshot validation: operation-scoped content/format validation memo shared by bootstrap, snapshot protection and failure-policy baseline. Tests count codec calls and replace bytes between checks; no trust based only on existence/mtime.
2. Gaming catalog: retain shared/exclusive backend locks; the UI waits and automatically retries busy reads within a bounded window, clears stale messages after success and cancels polling for disposed hosts. Never replay mutations.
3. Route speed: cheap AND guards before lazy list reads; canonical domain-only community sets use native matching and domain-only cache keys shared across destination IPs. Mixed/custom sets keep full metadata matching. Retain executable content hashing per query rather than introducing a metadata-only RAM identity shortcut; avoid unbounded decoded caches. Tests compare cold/warm, multiple IPs, changed source/port, list/core replacement and unsupported rules.
4. GitHub limits: classify rate limits from bounded response/headers; respect Retry-After/reset with bounded backoff across retries/pages/readers, show installed/pinned info even on failed catalog. Stale metadata stays display-only; installation requires fresh metadata. Tests cover 403 rate limit, 429, non-rate-limit 403, cooldown, recovery, pagination, frontend translations.
5. Run frontend full suite/lint/build, backend original and compacted suites, ShellCheck and real sing-box network checks in CI. Review diff and test coverage. Do not trigger build/release workflow or touch the router.

Review follow-up: retain exact release-tag metadata requests for rollback, and propagate GitHub cooldown through selected/pinned installs and the final component response. Regression tests reproduced both failures before the fixes. No stale metadata authorizes an installation.
