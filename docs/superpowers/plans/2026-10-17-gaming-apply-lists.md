# Gaming preset apply without remote-list refresh

Scope: code and automated tests only. No release or router installation.

Observed in LuCI 3.1.7: creating Steam+Epic and cleaning them up caused one reload each, but both started a complete remote-list update. The catalog remained disabled while that writer held the operation lock.

Root causes: local-only sections contribute to list/cron signatures; every nft rebuild requests a list update; catalog discovery unnecessarily shares the runtime operation lock despite reading an isolated configuration snapshot.

Implementation:

1. Ignore sections without list-update sources in list/cron signatures. Include mixed inline destinations so old elements cannot survive an edit.
2. For unchanged list identity only, snapshot current remote destination sets, bounded in size, and restore them in the same atomic nft rebuild. Missing, oversized or incompatible snapshots select the existing rebuild plus update path before any writes. A failed transaction remains a failure, never a successful fallback.
3. Read catalog configuration from its existing isolated, digest-checked snapshot without acquiring the writer lock. Mutating actions retain the exclusive lock and digest checks.
4. Prove local edits skip downloads, source changes invalidate reuse, IPv4/IPv6 elements survive, packet priority is unchanged, and catalog reads work during a writer while mutations remain blocked. Retain native Save/Apply/Reset behavior.

Verification: reproduce failures before implementation; run complete backend suite against source and compact installed sources, network tests with kernel nft and real sing-box, and frontend suite. Verify generated assets stay in sync.
