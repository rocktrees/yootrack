# Technology

YooTrack is a native Apple silicon menu bar app. macOS 15 or later. Swift tools 6, Swift language mode 5. No third-party runtime packages.

| Piece | Used for |
| --- | --- |
| SwiftUI and AppKit | Menu bar window, details window, settings |
| libproc, IOKit | Process, energy, and GPU counters |
| powermetrics via the privileged helper | Energy Impact, network rates, hardware watts |
| SQLite | `~/Library/Application Support/YooTrack/history.sqlite` for battery history, mode inherited from the app. `ledger.sqlite` in the same folder is mode `0600` and holds spending, budgets, and holdings. Read-only open of Cursor's `state.vscdb` for `cursorAuth/accessToken` when the CLI keychain item is missing |
| Security / Keychain | Optional provider overrides, service `ai.powerwatch.providers`. Money uses a separate service, `ai.powerwatch.ledger`, for the Plaid client ID, secret, access tokens, and an optional Jev key. YooTrack does not read other apps' keychain items |
| UserDefaults | `ai.powerwatch.providerSettings`: monthly USD budgets and manual allowances. Secrets are not stored here |
| URLSession | Provider usage requests, and Plaid or Jev only after the user saves those credentials. Cache is bypassed. Plaid and Jev errors omit response bodies |
| Foundation Models | On-device process summaries when the user asks, using live process identity, git project folder, working directory, parent/child process tree, and CPU/memory/power telemetry. No cloud model fallback |

Provider endpoints, OAuth first:

- Cursor login (app and agent CLI share it): read `cursorAuth/accessToken` from Cursor's `state.vscdb`. This is the same OAuth session and does not prompt for the login keychain. Then `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` with body `{}` and `Connect-Protocol-Version: 1`. `autoPercentUsed` is the in-house Auto and Composer limit. `apiPercentUsed` is the third-party API-model limit. Plan name from `GetPlanInfo`. `GET https://api2.cursor.sh/auth/usage` only when the dashboard body has no window.
- Codex ChatGPT login: `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization` and `ChatGPT-Account-Id`. Token and account id come from `~/.codex/auth.json`.
- Claude login token (`sk-ant-oat…` or a non-API credential): `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`. An `sk-ant-api…` login is an API organization and does not report a remaining plan window.
- Admin spend, only when the login cannot report a window: Anthropic `GET https://api.anthropic.com/v1/organizations/cost_report`, OpenAI `GET https://api.openai.com/v1/organization/costs`.

Local files, when present: `~/.codex/auth.json`, `~/.claude.json` (`oauthAccount.billingType`), `~/.claude/.credentials.json`, `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl`. Log reads keep the newest 12 files and the last 128 KB of each.

Money stays on this Mac. Manual spending, budgets, and holdings are in `ledger.sqlite` (`0600`). Categories come from on-device merchant memory and keyword rules, applied only at confidence 0.7 or higher. Plaid is optional: sandbox or production, Hosted Link, `/transactions/sync`, and `/investments/holdings/get`. Access tokens stay in Keychain. Jev (`POST https://api.typesafe.ai/v1/systemone`, model `jev-latest`, decisions-style `input` and `options`) is off until the user turns it on, and then it receives payee names only.
