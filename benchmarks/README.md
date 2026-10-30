# Swift / Rust evaluation

This is an isolated performance experiment, not a replacement app. The installed YooTrack app and authenticated helper are unchanged. All existing features remain in the Swift app.

## Result on this Mac (2026-10-11)

Eight alternating-order trials per language, 200 warmed process-collection passes per trial, identical logged-in-user privileges. Swift 6.3.1: `-O -whole-module-optimization`; Rust 1.99.0: opt-level 3, fat LTO, one codegen unit; SDK C layout shim: `-O3`. No third-party runtime crates.

| Median | Swift | Rust prototype |
| --- | ---: | ---: |
| CPU milliseconds / process pass | 1.837 | 1.849 |
| Wall milliseconds / process pass | 1.851 | 1.868 |
| Standalone benchmark physical footprint | 3.46 MiB | 2.77 MiB |
| Observed processes | 620 | 620 |
| Readable CPU counters | 620 | 620 |

Rust was about 0.7% slower in the median, well inside observed run-to-run variation. This test found no meaningful process-collection speed improvement. Its standalone footprint was about 0.69 MiB lower. This does not predict the app UI's memory use.

Swift-only phase checks: GPU counter reads 1.56 CPU ms / pass; native process + GPU + battery + grouping/deltas + JSON encoding 9.45 CPU ms / pass. Three trials per phase, 50 passes per trial. These exclude Apple powermetrics, XPC, JSON decoding, SQLite and UI, and use fewer accessible processes than the production root helper. They are not a full-app battery benchmark.

Installed-app background CPU breakdown (60.41 seconds, interface closed): app **0.36%**, helper **0.48%**, Apple powermetrics **0.51%** of one core; combined **1.36%**. No component restarted during this check. Approximately 38% of observed CPU was Apple's executable, which a language rewrite cannot optimize internally. This is a brief component profile; the original below-1% acceptance target remains unmet.

A second independent batch of eight trials per language measured Swift **1.790 ms** vs Rust **1.771 ms** CPU/pass across about 627 readable processes. Rust was 1.0% faster in that batch, versus 0.7% slower initially. The direction changed within the observed variance, reinforcing that no meaningful collection speedup was demonstrated. Standalone footprints were 3.46 vs 2.73 MiB. The JSON artifact stores the repeat's raw trials plus the first batch's logged summary.

A read-only 20-second background stack sample (`build/app-background-profile.txt`) captured history recording, SQLite writes/checkpoints, grouping, JSON decoding, and menu-bar update work. It identifies work worth profiling more closely; stack sample counts include waiting and must not be read as exact CPU percentages. History write batching and sample transport/decoding are better next experiments than changing language based only on this collection benchmark.

## What is and is not compared

Both process passes enumerate via libproc; read BSD identity, rusage CPU/energy/physical footprint and executable path; maintain PID/start-time keyed name/path caches; and verify identity again after collection. Warmup is ten passes. Missing rusage/path data is kept missing. CPU ticks use the actual Mach timebase. Both retain structured readings and consume a checksum so the loop cannot be removed.

Rust owns enumeration, caches, reading objects and iteration. A small C shim uses macOS SDK structures for BSD and rusage field layouts. This includes C marshalling overhead and is not a mathematically identical source translation. It gives the prototype the same kernel-call coverage and identity checks. Neither benchmark elevates privileges or prints process paths/arguments.

The Rust prototype does **not** implement GPU, battery, grouping, history, XPC security, powermetrics parsing, process controls, UI or on-device summaries. No feature-complete Rust app speedup has been demonstrated. A migration must preserve and revalidate these semantics, particularly unknown counters, GPU client identity, sleep, charging, attribution and safe termination.

## Feasible architecture

A Rust core can expose a C-compatible interface to Swift; Swift already interoperates with C APIs. Keep SwiftUI/AppKit menu/window integration, Apple's Foundation Models, and the authenticated XPC/security shell in Swift. Move collection/math/storage behind a bounded C interface only if further profiles find a worthwhile bottleneck. The Rust ABI must not expose native Rust strings/collections directly; define ownership, nullable metrics, errors and threading explicitly.

Apple's powermetrics is a separate executable. Rewriting YooTrack's code cannot change the work inside that executable. Its cadence/samplers/serialization architecture need separate evaluation if they dominate.

Sources: [Rust FFI documentation](https://doc.rust-lang.org/nomicon/ffi.html), [Swift's default C interoperability](https://www.swift.org/documentation/cxx-interop/).

## Reproduce

```sh
/bin/sh benchmarks/build.sh
python3 benchmarks/run-comparison.py
```

A Rust compiler is required. This run installed the official minimal toolchain under `build/rust-toolchain/` without modifying shell PATH or installing global toolchain settings. It is only a build dependency; it is not added to YooTrack's runtime. Build artifacts are `build/benchmark-swift`, `build/benchmark-rust`, `build/rust-swift-comparison.json` and its log.

For installed component CPU costs, close all YooTrack windows and the menu, let its background cadence settle, then run:

```sh
python3 benchmarks/component-overhead.py
```

This observes 60 seconds, not a ten-minute acceptance run. Restarts are reported; first-observed CPU from new processes is omitted and can underestimate totals. Current system workloads continue, so repeat before treating small differences as improvements.
