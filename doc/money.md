# Money tracking

[← Back to the README](../README.md)

The optional **Money** tab lets you enter spending or income, set monthly category limits, and record holdings. YooTrack displays budget and portfolio charts based on the data it has. It is a personal tracking tool, not financial advice; transactions, classifications, and balances can be incomplete or incorrect.

The menu-bar popover has a **Budget** section with this month's category spending and any limits. Financial amounts are shown when that section is open; the menu-bar icon itself does not display them. Select a category or **Open Details** to open Money. Like the full budget view, the summary uses up to the most recent 2,000 ledger entries.

## Local data and categories

Manual entries, budgets, synced transactions, and holdings are stored in a local SQLite ledger at `~/Library/Application Support/YooTrack/ledger.sqlite`. The app does not separately encrypt that database. Local category suggestions use merchant memory and rules; suggestions below the app’s confidence threshold are not automatically applied. You can also choose a category yourself.

## Optional Plaid sync

Plaid is not needed for manual tracking. To use it, provide your own Plaid client ID and secret, choose the sandbox or production environment, and follow the hosted account-linking flow. After linking, request **Sync** to retrieve transactions and, when available, investment holdings. Production connects to live institutions; sandbox is for testing.

Plaid credentials and access tokens are stored in macOS Keychain. The synced financial data is stored in the local ledger. Plaid receives the information needed for linking and synchronization and has its own terms and privacy practices.

## Optional Jev categorization

Jev is off by default. If you enable it, save a key, and explicitly request categorization, YooTrack sends payee names and the available category choices to the service. It does not send transaction amounts or account numbers for that request. The local categorizer does not require Jev.

Read the [disclaimer](../DISCLAIMER.md) and [security audit](../SECURITY_AUDIT.md) before connecting sensitive accounts or sharing financial information.
