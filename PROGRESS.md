# Power Watch project status

Ongoing performance decisions and experiments are tracked in [optimize.md](optimize.md). Update that file as optimization work progresses.

Updated: 2026-10-11. This is a native, local-only Apple silicon Mac menu bar app for understanding process resource use and estimated battery drain. SwiftUI/AppKit, libproc, IOKit, SQLite, and Apple's powermetrics collector; no third-party runtime services.

## Built and verified previously

- Menu bar, process/app grouping, details, local history, safe quit/stop controls.
- Root collector with exact code-signature authentication, administrator install/repair/removal.
- Installed app: `/Users/josh/Applications/Power Watch.app`; build: `build/Power Watch.app`.
- 24 core tests previously passed. Full collector ten-minute Release measurement: 1.841% of one core, app footprint 63.67 MiB, collection footprint 20.50 MiB. CPU target below 1% remains unmet; see VALIDATION.md.

## Current work

- [x] Correct displayed battery percentage to match macOS (keep raw gauge for drain calculations).
- [x] Separate CPU, memory, GPU activity, and network columns in quick menu and detail list.
- [x] Add 1-minute, 5-minute, and 30-minute history with finer recent buckets.
- [x] Test, build, update installed app, repair authenticated collector, and check live UI/readings.
- [x] Improve process identification: executable, owner, verified ancestry, launch arguments and working directory when accessible; distinguish browser renderer/GPU/utility roles using evidence.
- [x] Check Apple Foundation Models availability on this Mac, implement optional on-device summaries if supported. Do not guess browser tab identity when macOS does not expose it.
- [x] Verify process identification and summary availability/error paths; document limitations. Background memory smoke check completed; see below.

## Working principles

Missing readings stay unavailable rather than zero. GPU activity is execution time, separate from total GPU watts. App battery shares are conservative estimates and charging is excluded. Process control stays user-level and checks PID plus start time. Preserve history across updates. Avoid collecting secrets from command arguments or writing them to diagnostics/history.

## Latest validation

- 34 tests pass, including raw/display battery separation, GPU/network units and missing values, PID reuse, one-minute buckets, legacy history transition, compaction conservation, argument filtering, live inspection, and parent-direction preservation. Log: `build/tests-resource-context.log`.
- Live system battery and app both report 99%; raw gauge remains separate.
- Live network counters were positive across monitored processes after enabling the network sampler.
- This Mac omits process GPU time from powermetrics. A follow-up found native IOAccelerator per-client GPU counters; the current GPU work uses those directly instead. Total GPU power remains separate.
- Chrome inspection identified renderer/network/storage/GPU roles and an agent-browser ancestor with an AutoPal working directory.
- Apple's Foundation Models availability on this Mac is `available`. Initial AI generation demonstrated relationship errors; the final design keeps launch facts deterministic and constrains AI to guided role explanations. The final installed app inspected all 24 Chrome processes, displayed their verified current parent chains and working directories, and generated a guided role explanation without invented ancestry. Both individual and app summary paths were exercised; availability and collection limitations are documented.

- Post-AI background smoke measurement (40.07 seconds, not a ten-minute acceptance run): 1.572% of one core, app physical footprint 65.66 MiB, combined collector footprint 13.89 MiB. Memory targets passed; original CPU target is still unmet. Report: `build/overhead-resource-context-smoke.json`.
- Final individual guided explanation was verified after normalizing role labels: it explains web rendering without treating unavailable tab metadata as a browser defect. Final app is running normally with diagnostics disabled.
- Live UI selections for one minute, five minutes and thirty minutes were verified.

## Remaining improvements

- Bring combined full-collector background CPU below the original 1% target; the previous ten-minute result remains 1.841%. The new features have not yet received a new ten-minute benchmark.
- Explore reliable browser tab mapping only if a browser exposes a supported interface. Current renderer IDs are explicitly not tab identities.
- Per-process GPU timing depends on macOS/hardware support; keep unavailable values explicit.


## Native GPU follow-up

- [x] Read device utilization and per-process accumulated GPU time directly from IOKit.
- [x] Track client/process identity, zero vs missing, resets, array changes, duplicate clients, and pause/sleep baselines.
- [x] Show a separate device utilization reading and app/process GPU percentage columns.
- [x] Validate against a real Metal workload, update the installed app/collector, and verify the live UI.
- [x] 40 core tests pass. Metal load: 60.623% process activity, then 0% idle. Native readings observed 28 reporting processes.
- [x] Collector repair completed and live GPU sorting/percentage columns were verified in the installed app, with total utilization and GPU watts separate.

- Native GPU background smoke check (40.06 seconds, full collector, 15-second cadence): 1.623% of one core, app footprint 99.27 MiB, combined collector footprint 20.84 MiB. Memory targets passed; the original below-1% CPU target remains unmet. This is a brief smoke check, not a new ten-minute acceptance run. Report: `build/overhead-gpu-smoke.json`.
- Final app relaunched normally with diagnostic recording disabled; history preserved.

## Swift / Rust performance experiment

- Isolated Rust toolchain in the build folder; production app/helper remain unchanged.
- Matched process collector benchmark: Swift 1.837 ms CPU/pass, Rust 1.849 ms; no meaningful speed improvement. Standalone footprints 3.46 / 2.77 MiB. Eight alternating trials per language over 620 readable processes.
- Swift native GPU reads 1.556 ms CPU/pass; partial measurement/serialization pipeline 9.449 ms. These are user-level microbenchmarks, not the root helper or full app.
- See `benchmarks/README.md` and `build/rust-swift-comparison.json`; component overhead evaluation follows.

- Rust evaluation background component check (60.41s): app 0.364%, helper 0.480%, powermetrics 0.513% of one core; combined 1.357%. No restarts. The below-1% target remains unmet. No production language migration made; retain features and use the benchmark evidence to target optimizations. Details: `benchmarks/README.md`.

- Repeat collection benchmark: Swift 1.790 ms vs Rust 1.771 ms CPU/pass. About 1% faster for Rust this time vs 0.7% slower initially: direction changes within run variation. No meaningful improvement demonstrated. Background stacks captured history SQLite/JSON/menu work; no production changes made.

## Selection responsiveness and protected summaries

- Fixed false “exited” reports for live protected services: existence, access restrictions and PID reuse are separate states; launch context remains explicitly unavailable where protected.
- Added local service guides with purpose, shared scope, executable path, service account, parent PID and Finder reveal. WindowServer explanation and app summary verified in the installed app.
- Removed icon-cache churn (64-entry wholesale clearing), cached aggregates/sorting/process lookup, moved measurement processing off the main thread, batch-published contexts, and coalesced history follow-up. Final list uses lazy, explicitly expandable rows.
- 43 tests pass. Final collector repaired and individual WindowServer summary verified with restricted context identified correctly. After restart, 20 recorded selections measured 38.2 ms median, 16.7–120.9 ms range (handler-to-detail-view update). One 1,158.8 ms first-selection outlier immediately after setup is retained in optimize.md; no universal latency bound is claimed. Interaction logging disabled for final normal launch.


## History drain-share clarity

- Five-minute dashes traced to AC power with no battery discharge in the selected range. Attribution calculation remains conservative and unchanged.
- Added visible unavailability explanation and separate processor-energy percentages that work on external power, with explicit exclusion of GPU/other hardware.
- Release installed and five-minute UI verified; 44 tests pass. Collector signing-hash repair completed and authenticated hardware collection verified.


## Local summary recovery

- Replaced Generable decoding for the single explanation string with plain text and bounded output validation.
- Generation failures/unavailable models produce built-in descriptions with a clear source label; observed launch context remains visible independently.
- 50 tests pass. Final installed Chrome UI verified: built-in role explanations and observed launch context render after unusable model output, with no error alert. Collector signing-hash repair completed on 2026-10-12; installed signature accepted and authenticated connection verified.


## Full-row selection and repeatable UI tests

- App/process/History buttons include blank space and padding; disclosure remains separate.
- History uses lazy rows and indexed live membership. Sidebar tab state is isolated from detail rendering.
- Added native XCUITest fixtures and scripts/test-ui.sh. All four native UI tests pass, covering full-row hit areas and 24 tab transitions. With window-local tab reuse: median 65.6 ms, p95 73.2 ms, first History open 128.1 ms; warm range 46.1–73.2 ms. 50 core tests pass. Validated Release installed and launched normally; existing history preserved. Collector repair completed; installed signing hash accepted and authenticated live readings verified on 2026-10-13.


## Compact menu and column sorting (2026-10-14)

- Reduced quick-menu width from 740 to 520 points, with compact metric cells, smaller icons, and single-line names with full-name hover help. CPU, memory, GPU, receive/send rates and processor power remain visible.
- Added clickable App/name, CPU, Memory, GPU, Network and Power headers to the menu and Live list. A second click reverses direction; the arrow and existing sort picker stay synchronized. Expanded processes follow the same sort. Network uses combined known receive/send traffic. Missing readings stay last in both directions; known zero remains a real reading. Menu ranking stays independent of the details search.
- Shared comparator tests cover every metric in both directions, unavailable/zero values, deterministic ties, names, combined network rates and individual processes. All 53 core tests pass (build/tests-compact-sort.log).
- Five native interaction tests passed in build/ui-compact-sort.xcresult (row hit areas, expanded processes, History rows, Live header reversal, tab switching). The initial popup-opening test failed to open the status-item window. The exact QuickMenu view is now hosted in a normal fixture window for deterministic native testing: width and all six headers in both directions pass in build/ui-menu-content.xcresult. This validates popup content, not status-item opening behavior. The fixture window requires both --ui-testing and --test-quick-menu; normal launches are unaffected.
- Final Release built (build/build-compact-sort-final.log), installed at /Users/josh/Applications/Power Watch.app, and launched normally. Existing history retained; no interaction logging enabled. Live CPU, memory and native GPU readings observed. Collector repair approved by the user and completed on 2026-10-14. Installed signing hash matches the root-owned collector configuration. Relaunched the app to load the final executable identity; authenticated full-process collection resumed. A transient powermetrics proc_pidpath error cleared on a subsequent sample; fresh network rates, CPU hardware power (3.35 W), GPU hardware power (0.80 W) and native process GPU readings were verified. Power Watch’s three monitoring processes appear together. The earlier automatic approval rejection was resolved through explicit user confirmation.
- Sorting/filtering remains cached outside view bodies; no sampling or collection cadence change. No new background overhead acceptance benchmark; previous CPU target remains unmet.
