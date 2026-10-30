import SwiftUI
import Charts
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

struct MoneyListDraft { var payee = ""; var amount = ""; var income = false }
struct MoneyOverviewDraft {
    var limitCategory = LedgerCategory.all[0]; var limitAmount = ""; var symbol = ""; var holdingValue = ""
    var clientID = ""; var plaidSecret = ""; var jevKey = ""
}

struct BudgetMenuSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("This month's budget").font(.caption.bold())
                Spacer()
                if model.menuBudgetLoading { Text("Loading…").font(.caption2).foregroundStyle(.secondary) }
            }
            if model.menuBudgetRows.isEmpty {
                if !model.menuBudgetLoading {
                    Text("Add spending or monthly limits in Money to see your budget here.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.menuBudgetRows) { row in
                            Button {
                                model.requestedHubTab = 3
                                model.openDetails()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(row.category).font(.caption.weight(.medium))
                                        Spacer()
                                        Text("$" + MoneyMath.dollars(row.spentCents) + (row.limitCents > 0 ? " / $" + MoneyMath.dollars(row.limitCents) : " spent"))
                                            .font(.caption).monospacedDigit()
                                    }
                                    if row.limitCents > 0 {
                                        RemainingBar(percent: max(0, min(100, Double(row.remainingCents) / Double(row.limitCents) * 100)))
                                        Text(row.remainingCents >= 0 ? "$" + MoneyMath.dollars(row.remainingCents) + " left" : "$" + MoneyMath.dollars(-row.remainingCents) + " over limit")
                                            .font(.caption2).foregroundStyle(row.remainingCents < 0 ? Color.orange : Color.secondary)
                                    } else {
                                        Text("No monthly limit").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 2)
                            }.buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("menu.budget." + row.category)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 260)
            }
        }.onAppear { model.setMenuBudgetVisible(true) }
            .onDisappear { model.setMenuBudgetVisible(false) }
            .accessibilityIdentifier("menu.budget.section")
    }
}

struct MoneyList: View {
    @ObservedObject var model: AppModel
    @Binding var draft: MoneyListDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New spending stays on this Mac.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            HStack {
                TextField("Payee", text: $draft.payee).textFieldStyle(.roundedBorder).accessibilityIdentifier("money.payee")
                TextField("0.00", text: $draft.amount).textFieldStyle(.roundedBorder).frame(width: 80).accessibilityIdentifier("money.amount")
                Toggle("Income", isOn: $draft.income).toggleStyle(.checkbox).font(.caption)
                Button("Add") { model.addSpend(payee: draft.payee, amount: draft.amount, income: draft.income); draft.payee = ""; draft.amount = "" }.accessibilityIdentifier("money.add")
            }.padding(.horizontal, 12)
            HStack {
                Button("Categorize on this Mac") { model.categorizeMoneyLocally() }.disabled(model.moneyBusy)
                Spacer()
            }.padding(.horizontal, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.ledgerEntries.isEmpty {
                        Text(model.moneyLoading ? "Loading spending…" : "No spending recorded yet.").foregroundStyle(.secondary).padding()
                    }
                    ForEach(Array(model.ledgerEntries), id: \.id) { entry in
                        MoneyRow(entry: entry) { category in model.setSpendCategory(id: entry.id, category: category) }
                        Divider()
                    }
                }
            }
        }
    }
}

private struct MoneyRow: View {
    var entry: LedgerEntry
    var choose: (String) -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.payee).lineLimit(1)
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(MoneyMath.dollars(entry.cents)).monospacedDigit().foregroundStyle(entry.cents < 0 ? Color.primary : Color.teal)
            Picker("Category", selection: Binding(get: { entry.category ?? "" }, set: choose)) {
                Text("Uncategorized").tag("")
                ForEach(LedgerCategory.all, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 130)
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }
    private var caption: String {
        var text = entry.posted.formatted(date: .abbreviated, time: .omitted)
        if entry.pending { text += " · pending" }
        if let mask = entry.accountMask { text += " · •" + mask }
        return text
    }
}

struct MoneyOverview: View {
    @ObservedObject var model: AppModel
    @Binding var draft: MoneyOverviewDraft
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Budget").font(.title.bold())
                Text("This month’s spending. Limits are optional and stay on this Mac.").foregroundStyle(.secondary)
                if model.budgetRows.isEmpty { Text(model.moneyLoading ? "Loading budget…" : "Add a purchase or a monthly limit to see the chart.").font(.caption).foregroundStyle(.secondary) }
                else {
                    Chart(model.budgetRows) { row in
                        if row.limitCents > 0 { BarMark(x: .value("Category", row.category), y: .value("Limit", Double(row.limitCents) / 100)).foregroundStyle(.gray.opacity(0.25)) }
                        BarMark(x: .value("Category", row.category), y: .value("Spent", Double(row.spentCents) / 100)).foregroundStyle(row.limitCents > 0 && row.spentCents > row.limitCents ? .orange : .teal)
                    }.frame(height: 180).accessibilityIdentifier("money.budget")
                }
                HStack {
                    Picker("Category", selection: $draft.limitCategory) { ForEach(LedgerCategory.all, id: \.self) { Text($0).tag($0) } }.frame(width: 160)
                    TextField("Monthly limit", text: $draft.limitAmount).textFieldStyle(.roundedBorder).frame(width: 120)
                    Button("Save limit") { model.setBudget(category: draft.limitCategory, amount: draft.limitAmount); draft.limitAmount = "" }
                }
                Text("Portfolio").font(.title2.bold())
                let total = model.holdings.reduce(0) { $0 + $1.valueCents }
                Text(model.holdings.isEmpty ? (model.moneyLoading ? "Loading portfolio…" : "No holdings yet.") : "Latest value " + MoneyMath.dollars(total)).foregroundStyle(.secondary)
                if model.portfolioPoints.count > 1 {
                    Chart(model.portfolioPoints) { point in
                        LineMark(x: .value("Day", point.day), y: .value("Value", Double(point.valueCents) / 100)).foregroundStyle(.teal)
                    }.frame(height: 160).accessibilityIdentifier("money.portfolio")
                }
                if !model.holdings.isEmpty {
                    Chart(model.holdings.prefix(8)) { holding in
                        BarMark(x: .value("Symbol", holding.symbol), y: .value("Value", Double(holding.valueCents) / 100)).foregroundStyle(.teal)
                    }.frame(height: 140)
                }
                HStack {
                    TextField("Symbol", text: $draft.symbol).textFieldStyle(.roundedBorder).frame(width: 100)
                    TextField("Value", text: $draft.holdingValue).textFieldStyle(.roundedBorder).frame(width: 100)
                    Button("Add holding") { model.addManualHolding(symbol: draft.symbol, amount: draft.holdingValue); draft.symbol = ""; draft.holdingValue = "" }
                }
                Text("Accounts").font(.title2.bold())
                Text(model.plaidEnvironment == "production" ? "Production talks to your live Plaid app. Transactions are stored only in the local ledger." : "Sandbox is for Plaid test institutions. Nothing is sent except to Plaid, and only after you connect.").font(.caption).foregroundStyle(.secondary)
                Picker("Environment", selection: Binding(get: { model.plaidEnvironment }, set: { model.setPlaidEnvironment($0) })) { Text("Sandbox").tag("sandbox"); Text("Production").tag("production") }.pickerStyle(.segmented).frame(width: 240)
                Text(model.moneyLoading ? "Checking saved credentials…" : model.plaidReady ? "A client ID and secret are already in Keychain." : "Save your own Plaid client ID and secret. They are not shown again.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    SecureField("Client ID", text: $draft.clientID).textFieldStyle(.roundedBorder)
                    SecureField("Secret", text: $draft.plaidSecret).textFieldStyle(.roundedBorder)
                    Button("Save") { model.saveLedgerSecret(draft.clientID, account: "plaid-client-id"); model.saveLedgerSecret(draft.plaidSecret, account: "plaid-secret"); draft.clientID = ""; draft.plaidSecret = "" }.disabled(model.moneyBusy)
                }
                HStack {
                    Button(model.moneyBusy ? "Working…" : "Connect accounts") { model.connectPlaid() }.disabled(model.moneyBusy)
                    Button("Check connection") { model.finishPlaidLink() }.disabled(model.moneyBusy)
                    Button("Sync") { model.syncPlaid() }.disabled(model.moneyBusy)
                }
                DisclosureGroup("Jev categorization") {
                    Text("Off by default. Turning this on sends payee names, not amounts or account numbers, to TypeSafe when you ask. The local categorizer does not.").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    Toggle("Allow Jev to see payee names", isOn: Binding(get: { model.jevEnabled }, set: { model.setJevEnabled($0) }))
                    HStack {
                        SecureField("Jev API key", text: $draft.jevKey).textFieldStyle(.roundedBorder)
                        Button("Save key") { model.saveLedgerSecret(draft.jevKey, account: "jev"); draft.jevKey = "" }
                        Button("Categorize with Jev") { model.categorizeWithJev() }.disabled(model.moneyBusy || !model.jevEnabled)
                    }
                }.font(.callout)
            }.padding(4)
        }
    }
}
