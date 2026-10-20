# List update failure reporting

**Goal:** Identify the failed list/stage and whether its previous snapshot remains, without changing download policy, routing or update order.

**Architecture:** Keep the existing boolean cache API. Add an optional failure callback with bounded diagnostic codes, never raw URLs or command output. Updates log callback events and stage/section failures through the existing logger; overall failure uses error severity.

**Stack:** ucode, shell regression fixtures, existing Backend CI.

- [ ] Add failing tests for timeout, missing/kept snapshot, rejected input, storage limits and stage summary.
- [ ] Implement optional cache diagnostics, preserving atomic replacement and old callers.
- [ ] Add stage/section reporting and specific built-in subnet nft failures.
- [ ] Run focused tests in isolated RAM fixtures and full CI, including compacted installed sources.
- [ ] Apply only the logging changes after verification; do not restart, refresh live lists, alter routing or create backups.
