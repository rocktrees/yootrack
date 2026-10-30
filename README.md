# YooTrack

**See what is using your Mac’s battery, processor, memory, network, and GPU—right from the menu bar.**

YooTrack is a native macOS app for exploring what is running on your Mac and how its activity changes over time. It also shows available AI service usage and includes an optional personal money dashboard.

> **Early-stage software:** YooTrack can automatically read locally available Cursor, Codex, and Claude credentials and usage logs to check usage. Its optional full collector requires administrator access and has known security limitations. Read the [disclaimer](DISCLAIMER.md) and [security audit](SECURITY_AUDIT.md) before installing or connecting sensitive accounts.

## What it does

- **Live activity and history:** See app and process activity, processor energy, and battery estimates. [How power and history work →](doc/power-and-history.md)
- **Process details:** Inspect available launch context and request an on-device summary on supported Macs. [About process details →](doc/power-and-history.md#process-details-and-summaries)
- **AI usage:** See available Cursor, Claude, and OpenAI/Codex usage windows and reset times, or track a manual allowance. [How AI usage is tracked →](doc/ai-usage.md)
- **Money:** Enter spending, budgets, and holdings locally, with optional Plaid sync and Jev categorization. [How money tracking works →](doc/money.md)

## Get started

YooTrack targets **Apple silicon Macs running macOS 15 or later**. Download the latest disk image from [GitHub Releases](https://github.com/rocktrees/yootrack/releases), open it, and drag YooTrack to Applications. You can also build the app from source.

Release builds are currently **ad-hoc signed and not notarized**, so macOS Gatekeeper may block a downloaded app. The optional administrator collector is not installed automatically. See the [installation and development guide](doc/install-and-development.md) for requirements, source builds, upgrades, and collector details.

## How it works

YooTrack samples macOS counters and groups related processes to show live activity and local history. Its power and battery-attribution figures are **estimates**, not a complete accounting of the energy caused by each app. [Understand the readings →](doc/power-and-history.md)

AI usage comes from provider responses and, where available, local session logs. YooTrack checks for existing sessions automatically. [See the sources, refresh schedule, and limitations →](doc/ai-usage.md)

History and money data stay in local databases; saved credentials and access tokens use macOS Keychain. Optional third-party connections have their own data flows. [Read the privacy and financial notes →](DISCLAIMER.md)

## Documentation

- [Installation, development, and releases](doc/install-and-development.md)
- [Power, activity, history, and process details](doc/power-and-history.md)
- [AI usage tracking](doc/ai-usage.md)
- [Money tracking](doc/money.md)
- [Disclaimer and privacy notes](DISCLAIMER.md) · [Security audit](SECURITY_AUDIT.md)
- [Repository map](doc/structure.md) · [Technical notes](TECH.md)

## License

YooTrack is available under the [MIT License](LICENSE).
