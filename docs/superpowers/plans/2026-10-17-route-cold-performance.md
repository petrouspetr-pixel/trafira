# Cold routing analysis performance implementation plan

> Execute inline with superpowers:executing-plans; obtain one final independent review.

**Goal:** reduce first-query work without changing route decisions, ordering, unsupported-rule uncertainty or resource limits.

**Evidence:** isolated profiling of the installed code on the physical router (no installed-file/config changes): ya.ru 20.8s; 10 native matches 4.6s; 15 decode/compile calls 6.4s; 60 interpreter matches 2.9s; 55 cache publications 2.6s. Core identity hashes the executable once (~2.9s); preserve that content check. Ten local source lists contain only version 3 and pure ip_cidr arrays. Timed system() itself is not the bottleneck (noop ~1ms; native match ~720ms with either system or popen).

**Architecture:** fast path only for a strictly checked version-3 pure IP source subset, after the installed core has compiled a minimal version-3 capability probe once per analysis. Unsupported shapes/core versions retain the existing compiler path. Publish bounded cache entries with one directory inventory per batch, retaining per-entry digest and atomic replacement. Skip duplicate evaluation of the current address when preparing alternate DNS scenarios.

**Constraints:** no release; no router installation or production-code deployment. No provider-list downloads, decoded cross-query caches, metadata-only executable trust, weakened deadlines, altered source/port checks or changes to routing precedence.

- [ ] RED: source-list compilation count, invalid/unknown shapes and core rejection, batch directory scans/bounds/corruption, repeated current-address evaluation.
- [ ] Implement strict pure-IP source reader and per-analysis version probe, preserving native fallback and cleanup.
- [ ] Implement batch cache publication with replacement/eviction/failure checks; skip duplicate current-scenario match.
- [ ] GREEN: focused tests, full original/compacted backend, frontend and real sing-box/network CI; independent review and integration.

Ruling: keep executable hashing once per query. Reusing only inode/size/timestamps could miss an in-place replacement and weaken invalidation; its measured cost is retained.
