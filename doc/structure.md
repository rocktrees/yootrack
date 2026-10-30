# Repository map

Power Watch is one Swift package. The Xcode project is generated from the same sources by `scripts/generate-xcode-project.py`.

## Apps and tools

| Path | Role |
| --- | --- |
| `Sources/PowerWatch/` | Menu bar app: window, lists, settings, sampling cadence |
| `Sources/PowerWatchCore/` | Measurement, history, process context, provider usage, and the private money ledger. History keeps per-process processor energy while plugged in. Launch context names each git repo. The ledger stores spending, budgets, and holdings locally; Plaid tokens stay in Keychain |
| `Sources/PowerWatchHelper/` | Root collector. Reads metrics and does not track AI providers |
| `Sources/PowerWatchProbe/` | Local checks for load, quit, and XPC |
| `Tests/PowerWatchCoreTests/` | Parser, history, and usage math |
| `Tests/PowerWatchUITests/` | Native UI checks against fixture data |

## Provider usage

`Sources/PowerWatchCore/ProviderUsage.swift` turns Cursor, Anthropic, OpenAI, and manual allowances into one `ProviderStatus` list. Cursor's token comes from `state.vscdb`, not the login keychain. `autoPercentUsed` and `apiPercentUsed` are the in-house and third-party limits. Codex uses `~/.codex/auth.json`.

`Sources/PowerWatch/AppModel.swift` polls that list about every 60 seconds while a window is open and every 5 minutes in the background. Battery sampling stays on its own timer.

`Sources/PowerWatch/MoneyViews.swift` is the Money tab: manual spending, a monthly budget chart, portfolio value, and optional Plaid sync. Categorization runs on this Mac. Jev is a collapsed opt-in that sends payee names only.

## Scripts

| Script | Role |
| --- | --- |
| `scripts/test.sh` | `swift test --disable-sandbox` |
| `scripts/build.sh` | Release app in `build/Power Watch.app` |
| `scripts/install-app.sh` | Copies that app to `~/Applications` |
| `scripts/install-helper.sh` / `uninstall-helper.sh` | Administrator collector |
| `scripts/test-ui.sh` | Regenerates the Xcode project and runs the UI scheme |
| `scripts/generate-xcode-project.py` | Rebuilds `PowerWatch.xcodeproj` from `Sources/` and `Tests/PowerWatchUITests/` |
| `scripts/measure-overhead.py` | Ten-minute CPU and memory check |

`doc/` describes how the pieces fit together. `TECH.md` lists the system frameworks and provider endpoints.
