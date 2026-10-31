# Installation, development, and releases

[← Back to the README](../README.md)

## Requirements

YooTrack targets Apple silicon Macs running macOS 15 or later. Building from source requires Xcode 26 or later and Swift 6; the resulting app still targets macOS 15 or later. Optional on-device process summaries require a supported system and Apple Intelligence availability. Features and available counters can differ by Mac and macOS version.

## Install a release

Download the latest Apple silicon disk image from [GitHub Releases](https://github.com/rocktrees/yootrack/releases), open it, and drag YooTrack to Applications. The release also provides an app ZIP and SHA-256 checksums. Quit an older running version before replacing it.

The current release builds are **ad-hoc signed and not notarized**. macOS Gatekeeper may block an app downloaded from the internet. Review the [security audit](../SECURITY_AUDIT.md) before installation; the optional privileged collector has an unresolved security finding and is not installed automatically.

## Build from source

```sh
git clone https://github.com/rocktrees/yootrack.git
cd yootrack
/bin/sh scripts/install-local.sh
open -a YooTrack
```

Quit an older running version before installing. The installer updates `/Applications/YooTrack.app` if it exists; otherwise it uses `~/Applications/YooTrack.app`. If both copies exist, the local build script updates both. On first launch, YooTrack moves its existing history and money data to the YooTrack data folder. Existing settings and Keychain entries retain their internal identifiers. If both data folders already exist, YooTrack uses its own folder and leaves the earlier one untouched. Check launch-at-login settings after upgrading.

Click YooTrack in the menu bar to open its popover. You can also use **Open Menu** in the main window if the menu-bar icon is hidden. Closing the details window leaves the app running; use **Quit YooTrack** in the menu to stop it.

## Optional collector

Basic monitoring works without the collector. The collector requires administrator authorization and adds measurements such as network rates, Energy Impact, and hardware power. **Its current installer has an unresolved security finding and has not had an independent security review.** Read the [security audit](../SECURITY_AUDIT.md) before choosing to install it.

If you choose to use it, select **Install Collector** in the details window and approve the macOS administrator prompt. Remove it through **Settings → Remove Collector**. Rebuilding or updating the app can require **Repair Collector** because the collector checks the app’s exact signature.

## Development and releases

Run the core tests with `/bin/sh scripts/test.sh`, or open `PowerWatch.xcodeproj` in Xcode. The [repository map](structure.md), [technology notes](../TECH.md), and [earlier technical reference](REFERENCE.md) provide more detail.

The canonical app version is in `Resources/Info.plist` and follows `MAJOR.MINOR.PATCH`. Make changes in a branch and open a pull request to `main`; update both version fields to a new, unreleased version before merging. A push to `main` runs the release workflow on an Apple silicon runner: it tests and packages that exact commit, then publishes a GitHub release with a matching tag, disk image, app ZIP, and SHA-256 checksums. The release is published only after the files upload. Existing release tags are never overwritten, so a merge with a reused version fails and needs a version bump.

The existing release workflow can also build assets for a manually published release or be run manually for an existing release tag. The automatic workflow can be retried from GitHub Actions if a draft upload is interrupted.

To produce the artifacts locally on an Apple silicon Mac:

```sh
/bin/sh scripts/release.sh v1.0.0
```

The script checks that the tag matches both app version fields, runs the core tests, and writes artifacts to `build/releases/v1.0.0/`. Use the intended version in place of `v1.0.0` for later releases. See [AGENTS.md](../AGENTS.md) for the project’s versioning and release rules.
