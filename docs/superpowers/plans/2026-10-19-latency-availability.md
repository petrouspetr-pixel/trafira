# Confirmed node availability in the dashboard

- Keep unmeasured, successful and unavailable results separate.
- A successful sing-box history disappearing is failure evidence only inside the same core instance and saved configuration. PID plus process start ticks resets observations after core restarts/PID reuse; unknown identity disables inference.
- Keep one frontend snapshot, prune removed nodes, do not persist health to flash or start extra latency probes.
- Render status in node cards and URLTest/priority details; confirmed failures are red and translated as «Недоступен».
- A cold browser with no prior check evidence keeps «Нет замера». Empty history alone is ambiguous and must not be called a failure.
- Test unmeasured/failure/recovery, invalid data, removed nodes, process/config resets, UI rendering, nested members, backend process identity, full frontend/backend suites.
- No release, installation or router configuration changes.
