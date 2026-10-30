# How AI usage tracking works

[← Back to the README](../README.md)

The AI Usage list shows each available usage window separately. For example, Cursor's in-house and third-party allowances have individual bars and remaining amounts, so one exhausted allowance does not make the others appear exhausted. Bars fill with the amount used; spending caps and monthly budgets remain in the provider detail when rate windows are available.

YooTrack can show usage windows, remaining allowances, and reset times for Cursor, Anthropic, and OpenAI/Codex, along with allowances you enter yourself. The menu bar gives a quick view; open **AI Usage** in the details window for each provider’s available information and settings.

## Important privacy detail

In the current version, YooTrack **automatically looks for locally available provider sessions and usage logs** and may use credentials to request usage information from the corresponding service. There is no separate per-provider opt-in before that access. It starts checking when the app launches and refreshes approximately every minute while a YooTrack view is open, or every five minutes in the background. A refresh can also be requested from the app.

The local logs can contain sensitive information. YooTrack reads them to extract usage data; the provider usage requests described below send authentication information to the respective provider, not the log contents. Saved overrides are stored in macOS Keychain. See the [privacy notes](../DISCLAIMER.md#local-information-and-network-access) and [security audit](../SECURITY_AUDIT.md) before using this feature.

## Cursor

YooTrack attempts to read the Cursor session token from Cursor’s local `state.vscdb` database. It uses that token to request the current-period usage and plan information from Cursor’s service. If the main response does not contain readable usage windows, it tries a legacy usage endpoint. An optional token saved in YooTrack’s Keychain service is used as a fallback.

When Cursor reports the relevant fields, YooTrack shows separate **In-house** and **3rd party** windows, plus reset and spend-limit information where available. The names and values reflect the data Cursor returns; they are not a measurement of each individual request.

## Anthropic and Claude

YooTrack checks for Claude Code credentials in `~/.claude/.credentials.json` and plan information in `~/.claude.json`. It also reads recent local Claude project logs from `~/.claude/projects/` to derive available token totals and usage windows. When an OAuth token is available, YooTrack requests current usage from Anthropic. A saved credential can be used as a fallback; an Anthropic admin key can be used to request organization cost information.

A regular Anthropic API key does not necessarily provide a remaining subscription usage window. The information shown depends on the credential, account, and response available.

## OpenAI and Codex

YooTrack checks `~/.codex/auth.json` for a Codex ChatGPT session and account ID, and reads recent local session logs under `~/.codex/sessions/`. With a usable session it requests account usage from ChatGPT’s usage endpoint. If a session cannot provide a window, an optional saved OpenAI admin key can be used to request organization cost information.

Session and weekly windows appear when the provider supplies them. An OpenAI API organization cost report and a ChatGPT subscription quota are different sources; one should not be assumed to represent the other.

## Local token totals and limits

For Claude and Codex, YooTrack looks at up to 300 JSON or JSONL files encountered while scanning each log directory, selects up to 12 of those by modification time, and reads up to the last 128 KiB of each. It extracts recognizable token and usage fields and shows available totals for today and this month. Because it reads only a limited set of file tails, these totals can miss activity; they are not a complete billing record. Some log-derived usage windows may remain visible when a live request fails.

A usage bar fills according to the amount **used**, while its label shows the amount **left**. Reset dates, percentages, and costs depend on the information the provider returns. Missing, delayed, or changed provider data can result in an unavailable or outdated reading.

## Manual allowances

In **AI Usage**, add an allowance by entering its name, used amount, limit, and unit. YooTrack stores those values in local preferences and calculates the remaining amount from what you entered. Manual allowances are not synchronized with the provider.
