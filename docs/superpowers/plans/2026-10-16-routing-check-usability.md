# Routing check usability implementation plan

Goal: enter a domain and choose a source, then receive a plain-language routing explanation without looking up a destination address manually. Approved in chat. No release or router changes.

Architecture: resolve bounded real addresses through the running Trafira main DNS using the existing loopback health listener (now available with a single DNS server too). Never use a public fallback or FakeIP as a real address. Analyze up to four addresses of the selected source family, sharing bounded per-list evaluation; report differing routes or truncated answers honestly. Manual destination overrides skip DNS. The result is a configuration prediction for current DNS answers, not a website availability test or traffic capture.

UI: native LuCI rows and dropdowns; source/device and website visible, port/protocol/manual IP under Additional settings. Primary result says Direct, Via connection name, Blocked or Cannot determine yet, followed by Why and what to do. DNS addresses and alternate routes are readable; raw evaluation trace is only in Technical details. Russian translations ship with every new string.

- [x] Add failing backend resolver and frontend form/presentation regressions.
- [x] Implement bounded local real-DNS lookup, address-family and FakeIP handling, multiple-address decisions, and shared decoding without list downloads.
- [x] Redesign form, outcome, reason, DNS explanation and technical details; retain native device choices and manual overrides.
- [x] Test frontend, backend, real DNS listener and no-FakeIP behavior; review screenshots on desktop/mobile and run independent code review.
- [x] Integrate checked code. No release or physical router changes.

Review focus: timeout/NXDOMAIN does not masquerade as a route; no random address selected; no real DNS claimed from the selected device; no route claimed complete after a truncated DNS answer; current custom DNS may differ from device DNS; no decoded-list duplication or unbounded output.

Validation: 738 frontend tests in 67 files passed, native LuCI browser flow checked for device/domain, router without manual IP, DNS failure, mixed address routes and desktop/390px layout. Backend checks cover DNS failure, manual override, selected address family and four addresses sharing one list decode; real sing-box 1.14.2 proves real main-DNS lookup while device DNS returns FakeIP. Independent review P2 (failed DNS must not confirm a route) fixed and regression-tested. DNS unavailable in an old configuration remains explicitly disclosed, with restart/manual override guidance. Final CI checks are recorded on PR #56. No release or router changes.
