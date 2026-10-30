# Disclaimer and privacy notes

YooTrack is early-stage software. Please review these limitations before using it, installing the optional collector, or connecting sensitive accounts.

## Measurements and battery estimates

YooTrack reports sampled readings and estimates; it does not measure the complete energy caused by each app. Processor energy excludes some graphics, display, shared service, and other hardware activity. Counters may be unavailable, incomplete, or inconsistent, and sampling gaps and time-range boundaries can affect results.

Battery loss is expressed in **percentage points**: for example, 80% to 79% is one point. Observed loss adds decreases across eligible samples, so it can differ from the net change between the beginning and end of a period, particularly if the battery charges during that period. An app’s estimated battery contribution uses only intervals that meet the app’s attribution checks; check the displayed coverage before interpreting it. Treat the figures as guides for finding patterns, not precise billing or battery-health measurements.

## Privileged collector and security

The optional collector runs with administrator privileges. The October 30, 2026 [security audit](SECURITY_AUDIT.md) identified an unresolved trust-boundary risk in its installation process. Basic monitoring works without it. The app and collector have not received an independent security assessment, and the current build process uses ad-hoc signing. Use your judgment before installing or granting administrator authorization.

## Local information and network access

The app stores process history and, if used, spending, budgets, and holdings locally. These databases can contain sensitive information and are not separately encrypted by the app. Process names, executable paths, working directories, open paths, and filtered arguments may reveal private details; filtering is heuristic and does not guarantee that secrets have been removed. Review information before sharing screenshots, diagnostic files, or copied text.

YooTrack currently checks for locally available Cursor, Codex, and Claude sessions and usage logs automatically and may send the relevant credentials to the corresponding service to retrieve usage. There is no separate per-provider opt-in before this access in the current version. Saved provider credentials and Plaid access tokens are stored in macOS Keychain.

Plaid connectivity requires you to configure and connect it; its service receives the information needed for account linking and synchronization. Jev categorization is off by default. If you enable it and request categorization, payee names are sent to Jev’s service. Third-party services have their own terms, privacy policies, availability, and security practices.

## Financial information

The Money tab is a personal tracking tool, not financial, investment, tax, or legal advice. Transactions, categories, balances, and holdings can be incomplete, delayed, or incorrect. Verify important information with your financial institution and an appropriate professional before making decisions.

## Warranty

The software is provided “as is,” without warranty, as described in the [MIT License](LICENSE). Nothing in this document guarantees accuracy, availability, privacy, or security.
