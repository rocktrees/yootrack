# YooTrack

**See what is using your Mac’s battery, processor, memory, network, and GPU—right from the menu bar.**

YooTrack is a native macOS app for understanding what is running on your Mac and how its activity changes over time. Open the menu for a quick look, or open the details window to explore individual apps, processes, and history. It also includes AI service usage tracking and an optional personal money dashboard.

> **Early-stage software:** YooTrack can automatically read locally available Cursor, Codex, and Claude credentials and usage logs to check your usage. Its optional full collector requires administrator access and has known security limitations. Read the [disclaimer](DISCLAIMER.md) and [security audit](SECURITY_AUDIT.md) before installing or connecting sensitive accounts.

## What you can do

- **See live activity:** Check battery level, processor power, CPU, memory, GPU activity, and network rates for apps and processes.
- **Explore history:** Compare recorded processor energy and average power across time ranges, including from the menu bar.
- **Understand processes:** Expand an app to see its processes and inspect available launch context. On supported Macs, you can request an on-device summary.
- **Check AI usage:** See available Cursor, Anthropic, and OpenAI usage information and reset times, or track a manual allowance.
- **Track money locally:** Enter spending, budgets, and holdings. Plaid account sync and Jev payee categorization are optional.

## How it works

YooTrack samples system and process counters provided by macOS, groups related processes, and stores history locally. Basic monitoring works without administrator access. An optional privileged collector uses Apple’s `powermetrics` tool to provide additional measurements, including Energy Impact, network rates, and hardware power.

The numbers are useful for spotting patterns, but they are **estimates, not a complete accounting of the energy caused by each app**. Shared system services, graphics, the display, and other hardware cannot always be attributed to an individual app. See [Understanding the numbers](#understanding-the-numbers) and the [disclaimer](DISCLAIMER.md).

## Requirements

- A Mac with Apple silicon running macOS 15 or later.
- Xcode with Swift 6 to build from source.
- Apple Intelligence and a supported macOS version for optional on-device process summaries; availability depends on the device and system settings.

The project has no third-party runtime packages. Features and available counters can vary by Mac and macOS version.

## Install a release

Download the latest Apple silicon `.dmg` from [GitHub Releases](https://github.com/rocktrees/yootrack/releases), open it, and drag YooTrack to Applications. A ZIP of the app and SHA-256 checksums are also provided. Quit an older running version before replacing it.

Release builds are currently **ad-hoc signed and not notarized**. macOS Gatekeeper may block an app downloaded from the internet. Check the [security audit](SECURITY_AUDIT.md) before installing; the optional privileged collector has an unresolved security finding. Releases do not install the collector automatically.

## Build and run from source

1. Clone the repository and enter its directory:

   ```sh
   git clone https://github.com/rocktrees/yootrack.git
   cd yootrack
   ```

2. If an earlier version is running, quit it. Build and install the app into `~/Applications`:

   ```sh
   /bin/sh scripts/build.sh
   /bin/sh scripts/install-app.sh
   open "$HOME/Applications/YooTrack.app"
   ```

3. Click the **YooTrack** icon in the menu bar. Use **Live** or **History** in the popover, and choose **Open Details** for the full window. Closing that window leaves the app running; use **Quit YooTrack** in the menu to stop it.

If you used an earlier version, the installer renames its app bundle when needed. On first launch, YooTrack moves its existing history and money data to the YooTrack data folder. Existing settings and Keychain items retain their internal identifiers. If both data folders already exist, YooTrack uses its own folder and leaves the earlier one untouched. Check your launch-at-login setting after upgrading.

These scripts produce a locally ad-hoc-signed build, not a Developer ID–signed and notarized release. See the [security audit](SECURITY_AUDIT.md) for distribution limitations.

### Optional: full collector

Basic monitoring works without the collector. The full collector requires administrator authorization and adds measurements such as network rates, Energy Impact, and hardware power. **The current collector installer has an unresolved security finding and has not had an independent security review.** Review the [security audit](SECURITY_AUDIT.md) before choosing to install it.

If you choose to use it, select **Install Collector** in the details window and approve the macOS administrator prompt. To remove it later, choose **Settings → Remove Collector**. After rebuilding the app, the collector may require **Repair Collector** because it checks the app’s exact signature.

## Understanding the numbers

| Reading | What it means |
| --- | --- |
| Processor power (W) | An estimate based on process energy counters, not the app’s total impact on all hardware. |
| Processor energy (Wh) | Processor energy accumulated over the selected period, including time plugged in. |
| Battery discharge (W) | The estimated rate at which the battery is losing energy. |
| Battery loss (percentage points) | Accumulated observed decreases in battery charge. A drop from 80% to 79% is one percentage point. This total may differ from the net change over a period. |
| Estimated battery contribution | An estimate of the charge loss associated with an app’s processor activity, using suitable battery-only intervals. The displayed attribution coverage shows how much monitored time was usable. |
| CPU / GPU (%) | Sampled activity. CPU can exceed 100% across cores; GPU activity is not per-app GPU power. |
| Energy Impact | Apple’s relative activity score, not watts. |

A dash means a reading is unavailable or needs another sample. History is recorded locally for up to seven days, subject to storage limits. Range boundaries and attribution are approximate.

## Privacy and connections

- **History and money data:** Process history and the money ledger are stored locally in `~/Library/Application Support/YooTrack/`. The ledger is not separately encrypted by the app. Saved credentials and access tokens are stored in macOS Keychain.
- **AI usage:** YooTrack automatically looks for available local Cursor, Codex, and Claude sessions and usage logs and contacts the corresponding services. This happens without a separate per-provider opt-in in the current version.
- **Plaid and Jev:** Plaid is used only when you configure and connect it. Jev is off by default; if enabled and requested, it receives payee names for categorization.
- **Process details:** Paths and filtered launch arguments can contain sensitive information. Treat anything you copy or share from the app as potentially private.

See [DISCLAIMER.md](DISCLAIMER.md) for measurement, privacy, financial, and security limitations, and [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for the review and open findings.

## Development

Run the core tests with:

```sh
/bin/sh scripts/test.sh
```

Open `PowerWatch.xcodeproj` to build in Xcode. For the repository layout, implementation details, and earlier validation notes, see [the repository map](doc/structure.md), [TECH.md](TECH.md), and the [technical reference](doc/REFERENCE.md).

### Releases and versioning

The app version is recorded in `Resources/Info.plist` and follows `MAJOR.MINOR.PATCH`. To prepare a release, update both version fields, commit the changes, and create a GitHub release with a matching tag such as `v1.0.0`. Publishing the release runs GitHub Actions on an Apple silicon runner; after tests pass, it attaches a `.dmg`, app ZIP, and SHA-256 checksums. Assets appear after the workflow finishes.

To build the same artifacts locally on an Apple silicon Mac, run:

```sh
/bin/sh scripts/release.sh v1.0.0
```

The script checks that the tag matches the app version, runs the core tests, and places the artifacts in `build/releases/v1.0.0/`. See [AGENTS.md](AGENTS.md) for the project’s versioning and release rules.

## License

YooTrack is available under the [MIT License](LICENSE).
