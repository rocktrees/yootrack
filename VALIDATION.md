# Local validation

Test machine: Apple silicon, macOS 26.4.1. Local ad-hoc signed Release app installed at `/Users/josh/Applications/Power Watch.app`.

## Verified

- SwiftPM Release build and native Xcode Release build succeed.
- 24 automated tests pass, covering counter deltas, units, unavailable counters, PID reuse, exits, grouping, battery attribution, charging and AC transitions, sampling gaps, history persistence, compaction, pruning, metadata updates after caching/clearing/pruning, malformed plist streams, bytewise input and recovery, signature requirements, and protected process controls.
- A controlled CPU workload registered approximately 95% of one core, 2.744 processor watts, and 5.539 joules.
- The installed full collector also observed a 45-second disposable CPU workload over three samples: 99.36% of one core and 5.721 estimated processor watts, with a stable PID/start identity. After it exited, two history buckets retained 171.646 joules. The recorded result is `build/live-workload-check.json`.
- Disposable applications verified normal quit, a cancelled quit remaining alive, and force quit. Disposable background processes verified SIGTERM, SIGKILL, and rejection of changed identity.
- Kernel-enforced XPC authentication accepts the expected signature and rejects a different signature. The installed root helper also rejected the separately signed probe.
- Administrator installation succeeded on this Mac. The app connects to the installed helper and displays live CPU/GPU/Neural Engine estimates and process Energy Impact.
- Live Power Watch grouping includes the app, root collector, and its persistent `powermetrics` subprocess, with individual rows available on expansion.
- Search, process expansion, settings, window closing, reopening, and persisted history were checked in the installed app.
- Closing the interface switches sampling to 15 seconds; open views use 5 seconds. The first hardware reading after a cadence change needs a new collector sample.
- Stopping the app stopped its `powermetrics` subprocess; the root helper remained idle. Restarting retained history. A rebuilt app was rejected by the old signing pin until collector repair, as intended.
- The exited collector PID 12773 retained three history buckets and 2.082 joules of recorded processor energy after exiting.

## Background overhead

The ten-minute basic-mode Release measurement completed in 600.06 seconds with 55 observations. It used 2.97 CPU seconds, averaging **0.495% of one core**. Peak app physical memory footprint was **20.64 MiB**; peak RSS was **74.28 MiB**. No administrator collector was running in that measurement.

The raw basic-mode report is `build/overhead-final.json`. Memory targets use `ri_phys_footprint`, which is also displayed by the app; RSS is reported separately. These readings measure this Mac and workload, not a guarantee for other machines.

The initial full-mode ten-minute baseline averaged **4.848% of one core**, above target. Its report is `build/overhead-full-before-parser.json`. That earlier reporter could not read root-process footprint and incorrectly wrote zero for those fields; those zero fields are **unavailable measurements**, not zero memory. Its RSS measurements remain usable. The reporter now explicitly marks missing footprint readings as unknown and supports the app's authenticated diagnostic snapshot for root-process memory.

The growing plist buffer was repeatedly rescanned for its NUL delimiter. The optimized parser uses a native byte search and scans each incoming byte once, retaining chunked frames and recovery after malformed frames. The first optimization reduced the ten-minute average to **1.717% of one core** with **77.05 MiB app footprint** and **22.13 MiB combined collector footprint**, as recorded in `build/overhead-full-after-parser.json`. Memory passed; CPU remained above target.

The final build also caches executable names and bundle roots, skips re-encoding unchanged process metadata, and removes redundant coalition reporting from Apple's collector. App grouping still uses verified process relationships and bundle ownership. Both build paths and all 24 tests pass.

The final full-mode Release measurement completed in **600.07 seconds**, with **61 observations**, **15-second background sampling**, and the interface closed. It measured **11.05 CPU seconds**, averaging **1.841% of one core**. The complete report is `build/overhead-full.json`.

| Final full-mode result | Observed peak | Target | Result |
| --- | ---: | ---: | --- |
| App physical footprint | 63.67 MiB | <100 MB | Pass |
| Helper + powermetrics footprint | 20.50 MiB | <75 MB | Pass |
| App RSS, including resident shared pages | 144.80 MiB | Reported separately | — |
| Helper + powermetrics RSS | 29.89 MiB | Reported separately | — |
| Combined average CPU | 1.841% of one core | <1% of one core | **Not met** |

All three processes remained observable; root-process memory was supplied by the app's fresh authenticated diagnostic snapshots. Hardware readings and Energy Impact were available during background operation. The hardware stream was additionally checked at 15, 15, and 16-second intervals in `build/hardware-cadence-check.json`.

CPU is approximately 62% lower than the initial full-mode baseline, but the requested CPU target remains unmet on this Mac and workload. The final metadata changes reduced memory further; their CPU reading did not improve on the earlier parser-only run. These are measured results, not a claim that all performance targets passed. The optional diagnostic snapshot was enabled during these checks.

## Practical limits

The plist test fixtures are representative fixtures. Live root output has additionally been validated through the installed app; the raw privileged plist stream is not retained. Hardware and Energy Impact readings remain unavailable while the collector starts or when Apple's collector reports a failed sample.

Battery shares are conservative processor-energy estimates. On AC power, including periods when the battery supplements the adapter, app battery attribution stays unavailable. Charging, sleep, counter resets, and missing intervals are excluded. The app explicitly shows these conditions. Seven days of history will accumulate with use; retention and compaction were tested using accelerated fixtures.

Administrator uninstall and reinstall were exercised through Settings on this Mac. Removal deleted the installed helper, retained the app and history, and restored basic monitoring. Reinstallation restored the authenticated full connection; the unauthorized probe was rejected again afterward.

## 2026-10-11 resource columns and process context update

- 34 SwiftPM tests pass (`build/tests-resource-context.log`); Release bundle builds and passes strict ad-hoc signature verification (`build/build-resource-context.log`). Xcode project regenerated for new sources.
- Updated installed bundle at `/Users/josh/Applications/Power Watch.app`; repaired root collector authentication after the signature changed; live diagnostics confirmed connected collection.
- Displayed battery 99% matched `pmset -g batt`; the separate raw gauge was approximately 94–97%. Charging history remains excluded from app drain attribution.
- Separate CPU, memory, GPU execution and network columns compile in the menu and render in the details list; new GPU and network sort options are available.
- Live receive/send rates were positive across several processes. Network sampler is explicitly enabled. Per-process GPU timing is absent from powermetrics on this Mac; the native GPU follow-up below supplies it through IOKit. Total GPU hardware power is available separately. Missing/stale data remains unavailable rather than idle.
- History picker shows 1 minute, 5 minutes, 30 minutes, last hour, today, 7 days, and custom. One-minute UI showed fine recent buckets; tests cover fine-to-minute compaction and legacy minute history transitions without duplicated energy.
- Chrome context inspection distinguished renderers, GPU, network, and storage services. One renderer's verified chain included agent-browser and an AutoPal working directory. Arguments exclude environment and secret-bearing values; live identity checks and filtering are tested.
- Apple Foundation Models reports available on this Mac. Individual and app-wide summary actions were exercised. Final guided app explanation covered 24 inspected processes, with parent chains and directories rendered as deterministic facts and AI limited to role explanations. Earlier unconstrained generation made unsupported relationship claims; the final implementation never supplies ancestry to the model.
- Context/AI work only occurs for visible selections or explicit requests; closing the interface drops their caches. No new ten-minute performance measurement is claimed for this update; the previous target result remains documented above.

Post-AI background smoke check: **40.07 seconds**, **1.572% of one core**, app footprint **65.66 MiB**, collection footprint **13.89 MiB**. Both memory targets passed; CPU target did not. This brief check verifies caches are released after closing the interface and is not a replacement for the original ten-minute benchmark. Report: `build/overhead-resource-context-smoke.json`. The final app is relaunched normally with development diagnostics disabled.

Final individual guided role explanation was verified in the normal app launch. Role labels sent to the model omit monitoring annotations and executable-specific details. One-minute, five-minute, and thirty-minute selections all rendered their corresponding ranges.

## Native GPU follow-up (2026-10-11)

- Direct IOKit IOAccelerator reads supply device utilization and per-client `AppUsage[].accumulatedGPUTime` on this Apple silicon Mac. Public read-only registry APIs, driver-defined property names, no GPU subprocess or privileged access required. Direct totals take precedence over arrays; registry client IDs and process PID/start time protect baselines. Two samples are required; resets, changed layouts, disappearance, duplicate registry IDs, pause, and sleep/gaps are handled explicitly.
- GPU columns now show execution time / elapsed time × 100, with total device utilization shown separately in the menu and details header/overview. Concurrent work can exceed 100%; process rates are not a share of device utilization or per-app GPU watts. Missing counters remain unavailable. Existing history charts remain processor energy rather than fabricated GPU energy.
- 40 core tests pass (six new GPU tests). Logs: `build/tests-gpu.log`, `build/build-gpu.log`.
- A real Metal compute workload ran for 5.017 seconds: Metal command buffers reported 3.543 active seconds; the driver counter reported 60.623% process activity (about 3.04 seconds, within the test's 20% tolerance). The next five-second idle interval reported 0%. Device utilization was 91% during the load, with other GPU clients also active. Raw samples: `build/gpu-live-validation.json`; workload log: `build/gpu-workload.log`. This verifies units and response, not exact equivalence between command-buffer timestamps and driver accounting.
- Native collection observed 28 reporting processes during this test, including Chrome GPU helpers, Python, Codex, WindowServer, and the disposable Metal workload. The installed app displayed device GPU utilization and read 26 process rates in basic mode before collector repair.

- Collector repair completed for the rebuilt app. Live authenticated samples include native GPU rates, network rates, Energy Impact, and GPU watts with no collection issue. The installed UI was checked with GPU sorting: WindowServer, Chrome, ChatGPT/Codex, WebKit, Ghostty and Power Watch showed measured GPU values.

- Native GPU background smoke check (40.06 seconds, full collector, 15-second cadence): 1.623% of one core, app footprint 99.27 MiB, combined collector footprint 20.84 MiB. Memory targets passed; the original below-1% CPU target remains unmet. This is a brief smoke check, not a new ten-minute acceptance run. Report: `build/overhead-gpu-smoke.json`.
- Final app relaunched normally with diagnostic recording disabled; history preserved.

- Rust evaluation background component check (60.41s): app 0.364%, helper 0.480%, powermetrics 0.513% of one core; combined 1.357%. No restarts. The below-1% target remains unmet. No production language migration made; retain features and use the benchmark evidence to target optimizations. Details: `benchmarks/README.md`.

- Repeat collection benchmark: Swift 1.790 ms vs Rust 1.771 ms CPU/pass. About 1% faster for Rust this time vs 0.7% slower initially: direction changes within run variation. No meaningful improvement demonstrated. Background stacks captured history SQLite/JSON/menu work; no production changes made.


## Responsiveness and protected summaries (2026-10-11)

- 43 core tests pass; Release app built and installed. New cases cover protected/exited/reused process classification, system-path service-guide recognition, and aggregate nullable/zero/mutation correctness. Logs: `build/tests-responsiveness.log`, `build/build-responsiveness.log`.
- Final collector configuration trusts the installed app's exact signing hash. Live authenticated UI shows Energy Impact, network, native GPU rates and hardware readings. Existing powermetrics proc_pidpath failures can still cause stale frames; the app exposes gaps rather than reusing stale metrics.
- WindowServer app and individual-process summaries succeeded. Restricted inspection is distinguished from an exited process; launch argv/cwd/ancestry are unavailable explicitly. The deterministic guide displays purpose, shared desktop scope, observed executable path, _windowserver account (88), parent PID 1 and a Finder reveal control. System controls remain read-only.
- Full consumer list, expandable process buttons and repeated selections were exercised. Initial warm event-to-view updates were 29–71 ms. Final post-setup handler-to-view median was 30.9 ms over eight records, including a 1,158.8 ms first-selection outlier. A fresh restart captured 20 selections: median 38.2 ms, range 16.7–120.9 ms (first process selection 120.9 ms). Timings end at the detail-view update/main-loop callback, not final display presentation. Post-setup outlier remains documented; these measurements are not a universal bound. Files: `build/selection-timing.jsonl`, `build/selection-timing-final.jsonl`, `build/selection-timing-cold.jsonl`.
- An intermediate native-table DisclosureGroup/Equatable build crashed on launch during validation. Final explicit expandable lazy rows launch successfully and were used for the checks above.
- History preserved; final normal relaunch disables opt-in interaction diagnostics. No new ten-minute background benchmark; the below-1% combined monitoring CPU target remains unmet based on previous measurements.


## History drain-share clarity (2026-10-11)

- Local read-only SQLite check for 20:15:09–20:20:09: zero stored discharge energy, battery loss, valid battery energy and valid attribution seconds. Current macOS battery state: AC power, charged, 100%. Existing drain-share dashes were correct for unavailable attribution.
- Added a visible History explanation plus separate processor-energy share percentages. Five-minute installed UI verified; Chrome displayed about 83% of recorded processor energy and battery shares remained unavailable. These percentages include AC-time processor usage and exclude GPU/other hardware.
- 44 tests pass, including a mixed AC/battery range that retains processor history but attributes only the valid discharge interval. Logs: `build/tests-drain-share.log`, `build/build-drain-share.log`.
- Installed collector repair completed; configuration accepts the updated app's exact signing hash. Authenticated UI displayed fresh CPU hardware power (14.97 W), GPU hardware power (0.58 W), and device utilization (27%) without the disconnected banner. Five-minute processor-energy percentages remain visible alongside the explicit AC/no-discharge explanation. No history cleared, no attribution relaxed and no new background overhead claim.


## Local summary recovery (2026-10-11)

- 50 core tests pass. New coverage injects a decoding failure, rejects malformed/truncated/formatted text, bypasses unavailable generation, verifies source labeling, propagates cancellation, and keeps unknown roles unidentified. Release built; Xcode project regenerated for the shared recovery implementation.
- First plain-text Chrome generation completed without a decoding alert but returned long Markdown despite the short-answer instruction. Final validation rejects that output shape and provides built-in role descriptions.
- Final installed UI verified with 23 Chrome processes: observed context appears before generation and remains visible; unusable model output switches to clearly labeled built-in role descriptions and an inline notice. No error alert. History chart remains available. Authenticated collector repair completed on 2026-10-12; configuration accepts the installed app signing hash and the UI shows a connected collector. All summaries remain local and user-requested; no automatic generation retry or new overhead measurement.

- Post-repair check on 2026-10-12: Chrome summary inspected 25 processes and displayed the labeled built-in explanation after unusable generated output, with observed facts preserved and no error dialog. Fresh authenticated Energy Impact (8378.5) and network rates returned; native per-process GPU rates and new history points were visible. App left running normally.


## Full-row selection and tab switching (2026-10-13)

- 50 core tests pass (`build/tests-row-tabs.log`); Release builds (`build/build-row-tabs.log`).
- New native XCTest UI suite uses 1,000 synthetic processes/250 groups, isolated temporary history and disabled monitoring. It performs real native control clicks on blank space, left/right edges, vertical padding and expanded-process indentation. App, process and History checks pass, including independent disclosure behavior. No Codex computer-mode actions were used for these tests.
- Initial native-table baseline captured six tab updates at 97–159 ms before Mission Control interrupted the desktop. Incomplete baseline retained in `build/tab-before-partial.jsonl`; no complete matched performance ratio claimed. An initial hit-area assertion queried macOS text labels instead of values; corrected the test adapter.
- All four native UI tests pass in build/ui-tabs-cached.xcresult. The final 24-transition run (window-local tab reuse) measured 65.6 ms median, 73.2 ms p95, 128.1 ms maximum on first History open; warm switches 46.1–73.2 ms. Intermediate complete runs before reuse measured 103–107 ms overall median. Summary: build/tab-latency-comparison.json. Native timings exclude test-driver overhead and final display presentation; fixture results do not establish a universal bound. Validated Release installed and launched normally, with interaction logging disabled; existing history rendered after relaunch. Collector repair completed; installed signing hash accepted and authenticated live hardware/network readings verified on 2026-10-13. No new background overhead acceptance benchmark.


## Compact menu and column sorting (2026-10-14)

- Reduced quick-menu width from 740 to 520 points, with compact metric cells, smaller icons, and single-line names with full-name hover help. CPU, memory, GPU, receive/send rates and processor power remain visible.
- Added clickable App/name, CPU, Memory, GPU, Network and Power headers to the menu and Live list. A second click reverses direction; the arrow and existing sort picker stay synchronized. Expanded processes follow the same sort. Network uses combined known receive/send traffic. Missing readings stay last in both directions; known zero remains a real reading. Menu ranking stays independent of the details search.
- Shared comparator tests cover every metric in both directions, unavailable/zero values, deterministic ties, names, combined network rates and individual processes. All 53 core tests pass (build/tests-compact-sort.log).
- Five native interaction tests passed in build/ui-compact-sort.xcresult (row hit areas, expanded processes, History rows, Live header reversal, tab switching). The initial popup-opening test failed to open the status-item window. The exact QuickMenu view is now hosted in a normal fixture window for deterministic native testing: width and all six headers in both directions pass in build/ui-menu-content.xcresult. This validates popup content, not status-item opening behavior. The fixture window requires both --ui-testing and --test-quick-menu; normal launches are unaffected.
- Final Release built (build/build-compact-sort-final.log), installed at /Users/josh/Applications/Power Watch.app, and launched normally. Existing history retained; no interaction logging enabled. Live CPU, memory and native GPU readings observed. Collector repair approved by the user and completed on 2026-10-14. Installed signing hash matches the root-owned collector configuration. Relaunched the app to load the final executable identity; authenticated full-process collection resumed. A transient powermetrics proc_pidpath error cleared on a subsequent sample; fresh network rates, CPU hardware power (3.35 W), GPU hardware power (0.80 W) and native process GPU readings were verified. Power Watch’s three monitoring processes appear together. The earlier automatic approval rejection was resolved through explicit user confirmation.
- Sorting/filtering remains cached outside view bodies; no sampling or collection cadence change. No new background overhead acceptance benchmark; previous CPU target remains unmet.
