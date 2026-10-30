# Technical reference

> This reference preserves the project's earlier technical notes. For current installation guidance and known security limitations, see the [README](../README.md), [disclaimer](../DISCLAIMER.md), and [security audit](../SECURITY_AUDIT.md). Details below may describe an earlier build or a particular test machine.

# YooTrack

A native Apple silicon Mac menu bar app for battery use and private money tracking. Built with SwiftUI, AppKit, libproc, IOKit, and SQLite; no third-party runtime dependencies. Provider quotas, and Plaid or Jev only if you connect them, are the network calls.

## Open the app

The installed local build is `~/Applications/YooTrack.app`. Open it to show the details window. Closing that window leaves the app running in the menu bar; **Quit YooTrack** stops monitoring. The app has no Dock icon.

The menu shows battery level and discharge watts on battery. Its popover separates Processes (Live and History), AI Usage, and Budget. History includes period selection, processor energy, average power, and each app’s processor-energy share. Budget shows this month's category spending and limits when selected, but the menu-bar icon does not display amounts. The detail window offers searchable processes, app groups, individual process information, live readings, history, and a Money tab. Money stays in a local ledger. You can add spending by hand, set monthly limits, and chart holdings. Plaid sync is optional and keeps its tokens in Keychain. Categories are decided on this Mac. Jev is off unless you turn it on, and then only payee names are sent.

The menu also shows remaining usage for Cursor, Anthropic, and OpenAI, including the date and time each limit resets. Cursor shows two limits: in-house models (Auto and Composer) and third-party API models. The token is the Cursor app session in `state.vscdb`, shared with the agent CLI, and YooTrack does not ask for the keychain password. Codex uses the ChatGPT login in `~/.codex/auth.json`. A saved key is only a fallback and stays in Keychain. Quotas refresh about once a minute while a window is open.

The compact menu is 520 points wide. Click App, CPU, Memory, GPU, Network, or Power in the menu or Live list to sort; click the same header again to reverse. An arrow marks the current direction. Network sorts by combined download/upload rate, and missing readings stay last in either direction. Expanded processes follow the same sort. Hover over a shortened menu name to see its full name.

## Enable the full collector

Click **Install Collector** in the details window, and approve the macOS administrator prompt. Basic processor and native GPU activity monitoring work before installing it. Energy Impact and CPU/GPU/Neural Engine hardware readings require the collector.

The installer places these root-owned files:

- `/Library/PrivilegedHelperTools/ai.powerwatch.collector`
- `/Library/PrivilegedHelperTools/ai.powerwatch.collector.plist` (allowed user and app signing requirement)
- `/Library/LaunchDaemons/ai.powerwatch.collector.plist`

The helper authenticates XPC peers against the installed app's exact code signature and the configured user. It only reads metrics and accepts fixed sample/stop operations. Process termination stays in the user-level app. The collector launches on demand, stops its `powermetrics` subprocess when disconnected or paused, and has a watchdog for missing requests.

**After rebuilding or updating the app, use Install or Repair Collector again.** Local ad-hoc signatures change between builds, so the old installation intentionally rejects a different app build. Do not install a helper from the Xcode build and then run a different SwiftPM build without repairing it.

Terminal installation is also supported:

```sh
sudo /bin/sh scripts/install-helper.sh "$HOME/Applications/YooTrack.app" "$(id -u)"
```

Remove it through Settings → Remove Collector, or:

```sh
sudo /bin/sh scripts/uninstall-helper.sh
```

Removal retains the app and history. Launch at login is optional in Settings. No Accessibility, Full Disk Access, or screen recording permission is needed by YooTrack.

## What the numbers mean

| Metric | Meaning |
| --- | --- |
| Processor power, W | Difference in macOS `ri_energy_nj` process counters divided by elapsed time. A processor-energy estimate, not total hardware power caused by an app. |
| Battery level, % | macOS reported charge level, matching the menu bar; raw capacity is kept separately for drain calculations. |
| CPU, % | CPU time across cores; 100% means one core fully occupied. |
| Memory | Physical memory footprint, summed once across grouped processes. |
| GPU, % | Driver-reported GPU execution time divided by elapsed time × 100, grouped across an app’s reporting clients. Concurrent GPU work can exceed 100%. This is not per-app GPU watts or a percentage share of the device graph. |
| Device GPU, % | Graphics driver’s total device utilization, shown separately in the menu and details header/overview. |
| Network, ↓/↑ | Bytes received/sent per second from the collector, summed across grouped processes. |
| Energy Impact | Apple's relative activity score from `powermetrics`, normalized per second. It is not watts. |
| Battery discharge, W | Battery voltage × discharge current; available when the Mac is using its battery. |
| Processor energy, Wh | Accumulated observed process energy, including processes that later exit. |
| Estimated share of drain | App processor energy divided by battery discharge energy, restricted to valid discharge intervals. |
| Battery contribution, points | The app's estimated share × observed battery percentage-point loss, calculated interval by interval. |
| Hardware and unattributed | The remaining battery energy, including graphics, screen, hardware, inaccessible processes, and missed short-lived work. |

No app estimates are scaled up to total 100%. Inconsistent counters disable attribution for that interval. Charging, power-source transitions, counter resets, sleep, and sampling gaps do not create battery-loss attribution. A battery can discharge while plugged in: YooTrack shows and records that physical drain, but excludes it from per-app battery attribution because the adapter also supplies energy. CPU can exceed 100% when multiple cores are active. A dash means unavailable or awaiting a baseline; a supported zero counter means idle.

YooTrack groups helpers by app bundle and verified parent relationships. Work performed by shared system services remains separately identified. Descriptions use local metadata and a small built-in service glossary; unknown executables are not assigned invented explanations.

## Identify what is actually running

Expand an app and select a process. Chrome/Electron renderer, graphics, network, audio, and storage roles are recognized from executable names and filtered launch arguments. Python modules and script entry points are shown when exposed. **Launch context** shows the working directory, account, start time, executable path, and verified current parent chain. **Refresh context** rechecks this evidence. A current parent may differ from the original launcher; renderer IDs do not reveal browser tab titles or websites.

Context is inspected only for selected/expanded apps, stays in memory, and is discarded when the interface closes. Arguments use a small allowlist; inline source, secret-bearing options, URLs, and environment values are omitted. macOS may deny inspection of protected processes; unavailable fields are explicit.

**Summarize app processes** and **Summarize this process** use Apple's on-device Foundation Models when available on macOS 26. Verified launch facts are displayed separately from the AI role explanation; parent relationships and directories are never generated by AI. Inference runs only when requested, with no API key or cloud fallback. The app checks eligibility, Apple Intelligence enablement, and model readiness before enabling the button. See [Apple's model availability documentation](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel). Very large sets of distinct roles may require selecting a smaller group. AI descriptions remain interpretations.

Native GPU activity uses public read-only IOKit registry APIs to read driver-defined IOAccelerator statistics and per-client accumulated GPU time. This Mac exposes those counters even though powermetrics omits process GPU timing. Client registry IDs plus PID/start-time identities protect against reused processes. New clients, counter resets, changed arrays, pause/sleep, and gaps over 30 seconds establish new baselines. Missing data is a dash; a measured zero is idle. Partially readable groups show the available subtotal; missed clients are not reconstructed. These driver-defined keys can change with macOS. Their interpretation is also described in [ActivityMonitor’s measurement documentation](https://github.com/wieslawsoltes/ActivityMonitor/blob/main/docs/METRICS.md); YooTrack validates its own implementation against a real Metal workload on this Mac. No subprocess or administrator privilege is needed for GPU activity; total GPU watts still require the collector. Network collection includes the network sampler and reports received/sent bytes per second. Stale collector frames are excluded from live rates and explicitly identified.

GPU percentages describe sampled activity, not battery attribution. The existing historical charts show processor energy; graphics energy remains in hardware and unattributed consumption.

History offers **1 minute, 5 minutes, 30 minutes, last hour, today, seven days, and custom** ranges.

## History and overhead

Samples run every 15 seconds in the background and 5 seconds while a view is open. Sleep pauses collection and waking restarts baselines. History stays in `~/Library/Application Support/YooTrack/history.sqlite`, using sparse 15-second buckets for the latest hour, one-minute buckets for the latest day, and five-minute buckets afterward (compacted during hourly maintenance). Retention is seven days with oldest-first pruning at a 250 MB limit, checked during maintenance. The UI shows the actual available range. Queries at bucket edges are approximate; gaps are not interpolated as activity.

The monitor's app, helper, and its own `powermetrics` process appear together as **YooTrack**. Independent instances of `powermetrics` remain separate. Its memory and processor power are visible like any other app.

To repeat the ten-minute Release overhead check, close the details window and popover, then run:

```sh
python3 scripts/measure-overhead.py --seconds 600 --output build/overhead.json
```

The report measures cumulative CPU time, peak physical memory footprint (the same metric displayed in the app), and peak RSS separately, including the helper and its collector subprocess when installed. Targets are <1% of one core on average, <100 MB app footprint, and <75 MB combined collector footprint. RSS also includes resident shared library pages and can exceed the footprint; both are reported. The report records whether full or basic collection was present. Opening the interface during the test changes the workload.

Your account may be unable to read the root collector's footprint directly. In that case, quit the app, launch it with local diagnostics, and supply that snapshot to the reporter:

```sh
open "$HOME/Applications/YooTrack.app" --args --background --diagnostics-path "$PWD/build/live-sample.json"
python3 scripts/measure-overhead.py --seconds 600 --diagnostics build/live-sample.json --output build/overhead-full.json
```

Missing memory readings are reported as unknown and prevent a passing result. Diagnostic snapshots are optional development files and are not written during ordinary launches. See [VALIDATION.md](../VALIDATION.md) for the local checks and measured results.

The final full-mode ten-minute check on this Mac measured **1.841% of one core**, **63.67 MiB app footprint**, and **20.50 MiB combined collector footprint**. Memory targets passed; the <1% CPU target remains unmet. Basic mode measured 0.495% of one core. Full collector results and separate RSS figures are documented in the validation report.

## Build and test

Requires Xcode/Swift 6 and Apple silicon; minimum deployment target macOS 15. The local implementation is tested on macOS 26.4.1.

```sh
/bin/sh scripts/test.sh
/bin/sh scripts/build.sh
/bin/sh scripts/install-app.sh
open "$HOME/Applications/YooTrack.app"
```

Alternatively open `PowerWatch.xcodeproj`, select the **PowerWatch** scheme, and build. It contains native app and helper targets, each compiling the shared measurement sources. SwiftPM provides the same shared library, executables, and tests. Regenerate the Xcode project after adding sources with `python3 scripts/generate-xcode-project.py`.

Development checks:

```sh
.build/release/PowerWatchProbe --load-check
.build/release/PowerWatchProbe --quit-check
.build/release/PowerWatchProbe --xpc-check
/bin/sh scripts/install-helper.sh --validate "$HOME/Applications/YooTrack.app" "$(id -u)"
```

The quit check creates disposable fixture apps and verifies normal quit, a cancelled quit, and force quit. The XPC check verifies real signature matching and rejection using an anonymous listener, without installing a system service. Unit tests cover energy/counter math, grouping, battery attribution, history persistence/compaction/retention, plist streams, and process identity checks. The included plist fixtures are representative parser fixtures; live root collection requires administrator setup.

For local development only, launch with `--diagnostics-path /absolute/path.json` to write the current sample and collection mode to a local file. `--background` starts without opening a details window; opening the app again still opens details. Normal launches do not write diagnostic snapshots.

## Service explanations and responsiveness

Recognized macOS services have a “What is this service?” card with their role, shared scope, executable location, service account and observed parent PID. “Show executable in Finder” reveals the file. WindowServer is the shared window management/compositing/event-routing service; its work cannot reliably be assigned to one app. This glossary is available without AI.

macOS may permit the collector to list a service while restricting user-level launch inspection. Local summaries use the monitoring metadata in that case and mark launch details unavailable; this does not mean the process exited. Actual exits and PID replacement remain separate.

Selection changes update details immediately; launch context and history follow asynchronously. Icons, app totals and sorting are cached, rows are created lazily, and measurement grouping runs off the main thread. Ongoing results and limitations are recorded in [optimize.md](../optimize.md).


History shows **Processor share** separately from **Est. drain share**. Processor share compares recorded processor energy across the listed apps, including time plugged in; it excludes GPU and other hardware. Battery drain share is available only for valid battery-only discharge intervals. A message above History explains why the selected range has no usable attribution. Monitor while unplugged and select a range covering that time to collect battery-share estimates.


On-request process summaries keep observed launch context separate from AI explanations. If Apple Intelligence is unavailable, fails, or returns an unusable answer, YooTrack shows **Built-in role explanation** with a brief inline notice. Built-in descriptions explain recognized roles; unknown executable purposes remain unidentified.


### Repeatable interaction tests

Run `/bin/sh scripts/test.sh` for the core measurement/history/summary tests.
Run `/bin/sh scripts/test-ui.sh -resultBundlePath build/interaction-check.xcresult` for native XCTest UI checks (choose a new result path for each run).

The UI suite launches an explicitly titled fixture app with 1,000 synthetic processes across 250 groups, isolated temporary history and monitoring disabled. It checks empty space, edges and padding in app rows, expanded process rows and History rows, confirms the disclosure control stays independent, verifies compact menu width and column sorting, and alternates Live/History 24 times. The quick-menu test hosts the same popup content in a normal fixture window to avoid status-item targeting problems; it does not test the status item’s opening behavior. These tests drive native controls systematically and need an unlocked, undisturbed desktop. They do not require Codex computer mode.

Timing attachments measure the interval from the app's tab handler to its SwiftUI view update / next main-loop callback. They exclude XCTest round-trip overhead and final display presentation; synthetic fixtures do not establish latency for every real workload. `python3 benchmarks/tab-latency.py <test-log> [other-log]` summarizes captured timings. Ordinary app launches do not write interaction logs.
