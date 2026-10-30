# Power Watch optimization notes

Last updated: 2026-10-14.

This is the ongoing performance log for this repository. Update it when performance experiments, implementation changes, or measurements produce new evidence. Record what changed, test conditions, results, feature coverage, and the next decision. Keep measurements separate from hypotheses; do not mark targets achieved based on short smoke checks.

## Objective and constraints

- Preserve all existing features: menu bar and details interface, CPU/memory/GPU/network readings, Energy Impact, battery estimates, process grouping and identification, history, safe process controls, and optional on-device AI summaries.
- Target a Release build with the interface closed for ten minutes: combined monitoring CPU below 1% of one core, app physical footprint below 100 MB, and combined collection footprint below 75 MB.
- Keep data local, missing counters explicit, process identity checks intact, helper connections authenticated, and process termination at user level.
- Preserve historical data and measurement correctness. A smaller workload or missing feature is not a like-for-like performance improvement.

## Current decision: optimize before rewriting

Rust is a feasible choice for a monitoring/math/storage core while Swift retains SwiftUI/AppKit, Foundation Models, and the macOS XPC/security integration. A bounded C-compatible interface can connect the languages. This architecture could preserve the feature set, but it has not been implemented or validated as a complete replacement.

The process-collection experiments found no meaningful speed advantage for Rust. Keep the existing app in Swift for now. Consider migration only when a measured bottleneck and a representative prototype demonstrate a worthwhile improvement after integration overhead and feature parity are included.

## Swift versus Rust experiment

Two independent batches, each with eight alternating-order trials per language and 200 warmed passes per trial. Both executables ran as the same logged-in user. Approximately 620–628 processes were readable. Swift 6.3.1 used `-O -whole-module-optimization`; Rust 1.99.0 used opt-level 3, fat LTO, and one codegen unit. Rust used a small `-O3` C shim for macOS SDK structure layouts.

| Measurement | Swift | Rust prototype |
| --- | ---: | ---: |
| Initial median CPU time per process pass | 1.837 ms | 1.849 ms |
| Repeat median CPU time per process pass | 1.790 ms | 1.771 ms |
| Repeat standalone physical footprint | 3.46 MiB | 2.73 MiB |

Rust was approximately 0.7% slower initially and 1.0% faster on repeat. The direction changed within observed run-to-run variation. The prototype saved approximately 0.7 MiB in standalone benchmark memory; this does not predict the full app's memory use.

The matched work covered libproc enumeration, CPU/energy/memory counters, executable/name caches, and PID/start-time identity verification. The Rust prototype does **not** implement GPU, battery, grouping, history, XPC security, powermetrics parsing, process controls, UI, or local AI. No feature-complete Rust app speedup has been demonstrated.

Swift-only checks measured GPU reads at 1.56–1.60 CPU ms per pass and native process/GPU/battery collection plus grouping, deltas, app aggregation, and JSON encoding at 8.21–9.45 CPU ms per pass. These exclude powermetrics, XPC, JSON decoding, SQLite writes, and UI. User-level process coverage also differs from the production root helper.

Evidence and reproduction:

- [Detailed benchmark methodology](benchmarks/README.md).
- [Build script](benchmarks/build.sh) and [comparison runner](benchmarks/run-comparison.py).
- Results: `build/rust-swift-comparison.json`, `build/rust-swift-comparison.log`, and `build/rust-swift-comparison-repeat.log`. The JSON contains repeat raw trials and the first batch's logged summary.
- The official minimal Rust toolchain is isolated in `build/rust-toolchain/`; it did not change shell PATH or add a runtime dependency to Power Watch.

## Installed app baseline

The original ten-minute full-collector Release check measured 1.841% of one core, app footprint 63.67 MiB, and collection footprint 20.50 MiB. The CPU target remains unmet. See [validation notes](VALIDATION.md).

A later native-GPU smoke check over 40.06 seconds measured 1.623% of one core, app footprint 99.27 MiB, and collection footprint 20.84 MiB. This was not a ten-minute acceptance run.

The language evaluation's component check ran for 60.41 seconds with the interface closed:

| Component | Average CPU, % of one core |
| --- | ---: |
| Power Watch app | 0.364% |
| Collection helper | 0.480% |
| Apple's powermetrics | 0.513% |
| Combined | 1.357% |

No component restarted during this check. Approximately 38% of measured CPU came from Apple's executable; rewriting Power Watch cannot optimize its internal work. This short check does not establish a new acceptance baseline. Results: `build/component-overhead-rust-evaluation.json`; runner: [component overhead script](benchmarks/component-overhead.py).

A read-only 20-second stack profile captured history recording, SQLite writes/checkpoints, grouping, JSON decoding, and menu bar updates. Stack counts include waiting and are not exact CPU percentages. Profile: `build/app-background-profile.txt`.

## Next experiments

- [ ] Measure history recording separately; test prepared-statement reuse, avoiding repeated grouping/key construction, and write batching. Check energy conservation, retention, exited-process history, and persistence before accepting changes.
- [ ] Measure sample encoding/decoding and XPC transfer separately; compare transport representations while preserving nullable metrics, timestamps, identity, authentication, and failure handling.
- [ ] Profile the helper's powermetrics parsing and the collector's sampler/cadence costs. Retain every required metric and explicit gaps; do not count reduced coverage as a performance win.
- [ ] Profile visible-window sorting, aggregation, and rendering separately from background monitoring. Cache repeated work where measured; preserve live updates and all columns.
- [ ] Repeat the ten-minute Release acceptance check after a proven optimization, with windows/popover closed and normal diagnostics disabled. Record app/helper/powermetrics CPU and physical footprint separately, including restarts and collection failures.
- [ ] Revisit a Rust core only if a representative prototype improves an identified bottleneck. Include integration costs and all relevant correctness/feature tests.

## Future experiment log

For each experiment, append: date, hypothesis, affected feature/path, before/after build and conditions, test coverage, measured CPU/memory and duration, limitations, and whether the change was retained. Update the current decision and outstanding checklist when evidence warrants it.

## Responsiveness and service metadata fixes (2026-10-11)

- User reported 1–2 second selection delays and a false “process exited” summary error for WindowServer.
- Found a 64-entry icon cache that cleared all entries at its ceiling despite a longer list. The pre-change selection stack profile captured repeated `AppModel.icon(for:)`, AppKit icon loading, and sorting on the main thread (`build/selection-before-profile.txt`).
- Shared generic icons, cached by bundle/symbol, and replaced wholesale cache clearing with bounded individual eviction. Cached aggregate metrics and sorted list results; indexed process lookup.
- Moved measurement grouping/deltas and app aggregation onto the sampling queue. Coalesced selection follow-up/history requests, cancelled queued stale queries, skipped redundant overview queries on selection, and batch-published inspection results. Detail selection is immediate; context/history follow asynchronously.
- Consumer rows update only when their data or selection/expansion changes. A first native-table DisclosureGroup/Equatable combination triggered a SwiftUI runtime crash during validation; replaced it with explicit expandable rows. The final list uses lazy rows to avoid eagerly creating every consumer.
- Protected inspection now distinguishes permission restrictions from exits and PID reuse. WindowServer summaries use observed monitoring metadata with explicit inspection limitations rather than claiming it exited. Added deterministic service guides for WindowServer and other recognized macOS services, with executable location, service account, parent PID, shared-work scope, and Finder reveal. Source for WindowServer’s general role: Apple’s bundled `/usr/share/man/man8/WindowServer.8` and [Quartz Window Services](https://developer.apple.com/documentation/coregraphics/quartz-window-services).
- 43 core tests pass, including permission vs exit/replacement classification, system-path service recognition, and aggregate missing/zero/mutation behavior (`build/tests-responsiveness.log`).
- Initial updated warm click measurements (five captured selections): 29–71 ms event-to-detail-view update, with handler-to-view median 32.5 ms and maximum 68.8 ms. These are app instrumentation timings, not final screen presentation or CUA round-trip time. Timing is opt-in (`--interaction-log`) and will be disabled after final verification. Artifact: `build/selection-timing.jsonl`.
- Final installed collector repaired and authenticated. Individual WindowServer summary succeeded; restricted launch context is explicit and observed executable/account/parent metadata remains visible. Full-list app selection and process expansion/selection exercised with all metric columns retained.
- Final post-setup run recorded eight selections: handler-to-detail-view median 30.9 ms, with a first-selection outlier of 1,158.8 ms and another at 143.0 ms (`build/selection-timing-final.jsonl`). After a fresh restart, 20 captured selections measured median 38.2 ms, range 16.7–120.9 ms; the first process selection was 120.9 ms (`build/selection-timing-cold.jsonl`). Native accessibility actions supplied no valid mouse-event timestamps in these runs, so these figures measure handler-to-view update only. The post-setup outlier is retained as an unresolved observation; these checks do not establish a universal latency bound.
- A 15-second cold-selection stack profile captured the restarted app (`build/selection-cold-profile.txt`). Icon loading and sorting still occur when new data/icons arrive, but the prior wholesale icon-cache churn is removed. Stack counts across different runs are not a quantitative speed ratio.
- Final normal relaunch disables interaction logging. No new ten-minute background acceptance benchmark; the previously unmet combined CPU target remains outstanding.


## History drain-share clarity (2026-10-11)

- Investigated the user's five-minute screenshot against the local SQLite history. The range ending 20:20:09 had zero battery discharge energy, zero battery loss and zero valid attribution seconds. `pmset -g batt` reported AC power, charged, 100%. Dashes represented unavailable battery attribution; processor usage was still recorded correctly.
- Added a prominent range-specific explanation above the History list and chart, with separate messages for no history, no usable discharge, and discharge that failed attribution validation. Current external-power status is described as current state, not inferred historical state.
- Added an independent processor-energy share column calculated once per list render from recorded group energy, including AC periods. It explicitly excludes GPU/other hardware and is not presented as battery drain share. No sampling, cadence, history storage or attribution formula changed.
- 44 core tests pass, including mixed battery/external-power history preserving 25% battery share from the valid interval while excluding the external-power energy from attribution. The test uses aligned 15-second buckets; range-edge approximation remains documented. Logs: `build/tests-drain-share.log`, `build/build-drain-share.log`.
- Installed UI verified at five minutes: processor percentages display (Chrome about 83% during this check) while unavailable battery shares retain dashes with the explanation. History preserved. Collector repair completed; the installed signing hash is accepted. Authenticated live hardware readings and five-minute History percentages verified after repair. No new overhead benchmark performed.


## Local summary recovery (2026-10-11)

- User's Chrome summary failed while deserializing a Foundation Models Generable response. This is a supported framework failure mode ([Apple decodingFailure documentation](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/decodingfailure(_:))). The precise cause of that individual generation is not established.
- Replaced the structured one-string response with plain text. Observed process facts are published before generation and remain independent of the model. Short, complete, unformatted output is accepted; empty, oversized, truncated or formatted output falls back to deterministic built-in role descriptions.
- Generation errors and unavailable models now show an explicitly labeled built-in explanation and a readable inline notice. Unknown executables remain unidentified; missing launch details and ancestry are not invented. Cancellation propagates and stale-selection publication guards remain in place. No automatic retry loop, cloud API, background model session or extra polling added.
- 50 core tests pass, including injected decoding failure, malformed/incomplete output, unavailable-model bypass, successful text labeling, cancellation and known-service/unknown-role distinction. Logs: `build/tests-summary-recovery.log`, `build/build-summary-recovery.log`. Xcode project regenerated for shared RoleSummary.swift.
- Installed final build and exercised Chrome app summary across 23 inspected processes. Unusable formatted model output was rejected; the UI rendered built-in descriptions for renderer/GPU/network/storage roles, identified unknown executable purpose as unavailable, retained observed launch context, and showed an inline fallback notice with no modal error. Collector signing-hash repair completed on 2026-10-12; installed signature accepted and authenticated connection verified. No new background overhead benchmark.

- Post-repair Chrome verification (2026-10-12): 25 processes inspected, built-in recovery rendered without a modal, and fresh Energy Impact/network readings plus native GPU and history updates verified. App remains running normally.


## Full-row hit areas and tab switching (2026-10-13)

- User reported that only text/stats selected a row and that Live/History switching felt delayed. Added full rectangular hit regions including spacers/padding, moved process indentation inside the button, removed dead inter-control spacing, and kept the disclosure as its own control. Applies to live groups, individual processes and History.
- Replaced the History native table with lazy rows and built a live-ID set once per render instead of scanning every app for each historical row. Tab state moved into ConsumerBrowser so tab changes do not invalidate the details pane/charts. Previously opened tab view graphs are retained only while the details window is open; hidden tabs reject input and are hidden from accessibility. The window controller releases the hosting graph on close. This trades some visible-window memory for faster switching; no closed-window caches added. No change to sampling cadence, history data or attribution.
- Added a native XCUITest target/scheme and `/bin/sh scripts/test-ui.sh`. Test fixtures contain 1,000 synthetic processes in 250 groups with isolated temporary storage and monitoring disabled; no collector/real history access. Test builds live outside synced Desktop to avoid Finder metadata invalidating signatures. Stable accessibility identifiers and opt-in tab render diagnostics make the checks repeatable.
- Baseline captured six handler-to-view updates (97–159 ms); Mission Control interrupted the remaining clicks, so this is an incomplete baseline, not an app failure or a controlled performance ratio. Artifact: `build/tab-before-partial.jsonl`; failed-run diagnostics: `build/ui-before-native.xcresult`.
- Full-row native UI checks now pass for apps, processes (including indentation) and History; disclosure behavior remains independent. The first test run read macOS static-text labels instead of values; fixed the test assertion to wait for either representation. All four final native tests pass (`build/ui-tabs-cached.xcresult`, `build/ui-tabs-cached.log`). The 24-transition run measured 65.6 ms overall median, 73.2 ms p95, and 128.1 ms maximum (first History open). Remaining warm switches ranged 46.1–73.2 ms. Live median was 65.8 ms; History median 65.4 ms. These are handler-to-view-update/next-main-loop timings, not final display presentation. 50 core tests pass (`build/tests-row-tabs.log`). Release build: `build/build-row-tabs.log`.
- No new ten-minute CPU/memory benchmark; previous overhead target status remains unchanged. Validated Release installed at /Users/josh/Applications/Power Watch.app and launched normally with interaction diagnostics disabled. Existing history rendered after relaunch. Collector repair completed; installed signing hash accepted and authenticated live hardware/network readings verified on 2026-10-13.

- Intermediate complete runs before tab reuse measured roughly 103–107 ms overall medians and 127–133 ms Live medians. A split-timing run showed only 13–26 ms to NSView update and 53–110 ms additional callback delay; tab view reuse reduced the latter. Runs are not a controlled CPU benchmark. Summary: `build/tab-latency-comparison.json`; reproducible parser: `benchmarks/tab-latency.py`. The initial stack-profile attachment attempt did not find the fixture process; no stack-profile conclusion is claimed.


## Compact menu and column sorting (2026-10-14)

- Reduced quick-menu width from 740 to 520 points, with compact metric cells, smaller icons, and single-line names with full-name hover help. CPU, memory, GPU, receive/send rates and processor power remain visible.
- Added clickable App/name, CPU, Memory, GPU, Network and Power headers to the menu and Live list. A second click reverses direction; the arrow and existing sort picker stay synchronized. Expanded processes follow the same sort. Network uses combined known receive/send traffic. Missing readings stay last in both directions; known zero remains a real reading. Menu ranking stays independent of the details search.
- Shared comparator tests cover every metric in both directions, unavailable/zero values, deterministic ties, names, combined network rates and individual processes. All 53 core tests pass (build/tests-compact-sort.log).
- Five native interaction tests passed in build/ui-compact-sort.xcresult (row hit areas, expanded processes, History rows, Live header reversal, tab switching). The initial popup-opening test failed to open the status-item window. The exact QuickMenu view is now hosted in a normal fixture window for deterministic native testing: width and all six headers in both directions pass in build/ui-menu-content.xcresult. This validates popup content, not status-item opening behavior. The fixture window requires both --ui-testing and --test-quick-menu; normal launches are unaffected.
- Final Release built (build/build-compact-sort-final.log), installed at /Users/josh/Applications/Power Watch.app, and launched normally. Existing history retained; no interaction logging enabled. Live CPU, memory and native GPU readings observed. Collector repair approved by the user and completed on 2026-10-14. Installed signing hash matches the root-owned collector configuration. Relaunched the app to load the final executable identity; authenticated full-process collection resumed. A transient powermetrics proc_pidpath error cleared on a subsequent sample; fresh network rates, CPU hardware power (3.35 W), GPU hardware power (0.80 W) and native process GPU readings were verified. Power Watch’s three monitoring processes appear together. The earlier automatic approval rejection was resolved through explicit user confirmation.
- Sorting/filtering remains cached outside view bodies; no sampling or collection cadence change. No new background overhead acceptance benchmark; previous CPU target remains unmet.
