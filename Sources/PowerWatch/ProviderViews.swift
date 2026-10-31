import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

enum ProviderDisplay {
    static func left(_ window: QuotaWindow) -> String {
        guard let remaining = window.remaining else { return "—" }
        switch window.unit {
        case "%": return String(format: "%.0f%% left", remaining)
        case "USD": return String(format: "$%.2f left", remaining)
        default:
            if remaining >= 1000 { return String(format: "%.1fk left", remaining / 1000) }
            return String(format: "%.0f left", remaining.rounded())
        }
    }
    static func remaining(_ provider: ProviderStatus) -> String {
        if let window = provider.headline { return left(window) }
        if provider.source == "Checking…" { return "…" }
        return "Set up"
    }
    static func used(_ window: QuotaWindow) -> String {
        guard let used = window.used, let limit = window.limit else { return "Limit unavailable" }
        if window.unit == "%" { return String(format: "%.0f%% used", used) }
        if window.unit == "USD" { return String(format: "$%.2f of $%.2f", used, limit) }
        return String(format: "%.0f of %.0f %@", used, limit, window.unit)
    }
    static func reset(_ date: Date?) -> String {
        guard let date else { return "No reset time" }
        if date.timeIntervalSinceNow <= 0 { return "Resets soon" }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Resets \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "Resets tomorrow \(time)" }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        let when = sameYear ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : date.formatted(date: .abbreviated, time: .shortened)
        return "Resets \(when)"
    }
    /// One line when every window resets together, otherwise one line per window.
    static func resets(_ windows: [QuotaWindow]) -> [String] {
        let dated = windows.filter { $0.resetAt != nil }
        let unique = Set(dated.compactMap { $0.resetAt?.timeIntervalSince1970 })
        if unique.count <= 1 { return dated.first?.resetAt.map { [reset($0)] } ?? [] }
        return dated.map { "\($0.label) \(reset($0.resetAt))" }
    }
    static func count(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 10_000 { return String(format: "%.1fk", value / 1000) }
        return String(format: "%.0f", value)
    }
    static func tint(_ percent: Double?) -> Color {
        guard let percent else { return .gray }
        if percent >= 50 { return .teal }
        if percent >= 20 { return .orange }
        return .red
    }
    static func rates(_ provider: ProviderStatus) -> String {
        let rates = provider.rateWindows
        if rates.count > 1 { return rates.map { "\($0.label) \(left($0))" }.joined(separator: " · ") }
        return provider.headline?.label ?? provider.source
    }
    static func amount(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}

struct RemainingBar: View {
    /// Percent still remaining. The bar fills with the amount already used.
    var percent: Double?
    private var used: Double { percent.map { max(0, min(100, 100 - $0)) } ?? 0 }
    var body: some View {
        Capsule().fill(.quaternary).overlay(alignment: .leading) {
            GeometryReader { geo in
                Capsule().fill(ProviderDisplay.tint(percent)).frame(width: max(0, geo.size.width * CGFloat(used / 100)))
            }
        }.frame(height: 6).accessibilityLabel(percent.map { String(format: "%.0f percent left", $0) } ?? "Usage unavailable")
    }
}

private struct ProviderContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ProviderMenuSection: View {
    @ObservedObject var model: AppModel
    var onNavigate: (() -> Void)? = nil
    @State private var contentHeight: CGFloat = 0
    private var maxContentHeight: CGFloat {
        // Leave room for the menu header, section picker and footer on the current screen.
        max(150, (NSScreen.main?.visibleFrame.height ?? 800) - 220)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Usage left").font(.caption.bold())
                Spacer()
                if model.providerBusy { Text("Refreshing").font(.caption2).foregroundStyle(.secondary) }
            }
            if model.providers.isEmpty {
                Button("Set up AI usage") { model.focusProvider(nil); onNavigate?() }.font(.caption).accessibilityIdentifier("menu.provider.setup")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.providers) { provider in
                            Button { model.focusProvider(provider.id); onNavigate?() } label: {
                                let windows = provider.rateWindows.isEmpty ? provider.windows : provider.rateWindows
                                VStack(alignment: .leading, spacing: 3) {
                                    if windows.isEmpty {
                                        HStack { Text(provider.name); Spacer(); Text(ProviderDisplay.remaining(provider)).foregroundStyle(.secondary) }
                                    } else {
                                        if windows.count > 1 { Text(provider.name).font(.caption) }
                                        ForEach(windows) { window in
                                            HStack(spacing: 8) {
                                                Text(windows.count > 1 ? window.label : provider.name).lineLimit(1).frame(width: 120, alignment: .leading).help(windows.count > 1 ? window.label : provider.name)
                                                RemainingBar(percent: window.percentRemaining)
                                                Text(ProviderDisplay.left(window)).font(.caption2).monospacedDigit().lineLimit(1).frame(width: 80, alignment: .trailing)
                                            }
                                        }
                                        ForEach(ProviderDisplay.resets(windows), id: \.self) { line in
                                            Text(line).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }.padding(.vertical, 3)
                            }.buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("menu.provider." + provider.id)
                                .help(provider.error ?? provider.source)
                            Divider()
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ProviderContentHeightKey.self, value: geometry.size.height)
                        })
                }
                .frame(height: min(max(contentHeight, 1), maxContentHeight))
                .onPreferenceChange(ProviderContentHeightKey.self) { contentHeight = $0 }
            }
        }
    }
}

struct ProviderListDraft { var name = ""; var used = ""; var limit = ""; var unit = "USD" }
struct ProviderDetailDraft { var providerID: String?; var secret = ""; var budgetText = ""; var manualUsed = ""; var manualLimit = "" }

struct ProviderList: View {
    @ObservedObject var model: AppModel
    @Binding var draft: ProviderListDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Provider").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Left").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.providers) { provider in
                        Button { model.selectedProvider = provider.id } label: {
                            let windows = provider.rateWindows.isEmpty ? provider.windows : provider.rateWindows
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(provider.name).fontWeight(.medium).lineLimit(1)
                                    Spacer()
                                    if windows.isEmpty { Text(ProviderDisplay.remaining(provider)).font(.caption).monospacedDigit() }
                                }
                                if windows.isEmpty {
                                    Text(provider.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                ForEach(windows) { window in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(window.label).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(ProviderDisplay.left(window)).monospacedDigit()
                                        }.font(.caption2)
                                        RemainingBar(percent: window.percentRemaining)
                                            .accessibilityIdentifier("provider.window." + provider.id + "." + window.id)
                                    }
                                }
                                ForEach(ProviderDisplay.resets(windows), id: \.self) { line in
                                    Text(line).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(10).background(model.selectedProvider == provider.id ? Color.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("provider.row." + provider.id)
                        Divider()
                    }
                }.padding(.horizontal, 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Track another allowance").font(.caption.bold())
                HStack {
                    TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder)
                    TextField("Used", text: $draft.used).textFieldStyle(.roundedBorder).frame(width: 70)
                    TextField("Limit", text: $draft.limit).textFieldStyle(.roundedBorder).frame(width: 70)
                    Picker("Unit", selection: $draft.unit) { Text("USD").tag("USD"); Text("Requests").tag("requests"); Text("Tokens").tag("tokens") }.labelsHidden().frame(width: 110)
                    Button("Add") { add() }.disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(12)
        }
    }
    private func add() {
        if model.addAllowance(name: draft.name, used: ProviderDisplay.amount(draft.used) ?? 0, limit: ProviderDisplay.amount(draft.limit) ?? 0, unit: draft.unit) { draft.name = ""; draft.used = ""; draft.limit = "" }
    }
}

struct ProviderDetail: View {
    @ObservedObject var model: AppModel
    @Binding var draft: ProviderDetailDraft
    private var provider: ProviderStatus? { model.providers.first { $0.id == model.selectedProvider } ?? model.providers.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let provider {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.name).font(.title.bold()).accessibilityIdentifier("provider.title")
                        Text((provider.plan.map { $0 + " · " } ?? "") + provider.source).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.providerBusy ? "Refreshing…" : "Refresh") { model.refreshProviders() }.disabled(model.providerBusy)
                }
                if let error = provider.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if provider.windows.isEmpty { Text("No remaining-usage window yet.").foregroundStyle(.secondary) }
                ForEach(provider.windows) { window in windowCard(window) }
                if !provider.tokens.isEmpty { tokens(provider) }
                if let budget = provider.budgetUSD, provider.monthCostUSD == nil, !provider.id.hasPrefix("manual:") {
                    Text(String(format: "Monthly budget $%.2f is saved. Dollar spend appears when the provider returns it.", budget)).font(.caption).foregroundStyle(.secondary)
                }
                connection(provider)
                Text("Updated " + provider.updatedAt.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("AI usage").font(.title.bold())
                Text("Cursor, Anthropic, and OpenAI will appear here after the first check.").foregroundStyle(.secondary)
            }
        }.onAppear { loadDraft() }.onChange(of: model.selectedProvider) { _, _ in loadDraft() }
    }
    private func windowCard(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ProviderDisplay.left(window)).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(ProviderDisplay.tint(window.percentRemaining))
            }
            RemainingBar(percent: window.percentRemaining)
            HStack { Text(ProviderDisplay.used(window)); Spacer(); Text(ProviderDisplay.reset(window.resetAt)) }.font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    private func tokens(_ provider: ProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local tokens").font(.headline)
            ForEach(provider.tokens, id: \.period) { summary in
                HStack(spacing: 12) {
                    Text(summary.period).frame(width: 88, alignment: .leading)
                    Text("In " + ProviderDisplay.count(summary.input))
                    Text("Out " + ProviderDisplay.count(summary.output))
                    Text("Cache " + ProviderDisplay.count(summary.cacheRead + summary.cacheWrite))
                    if let cost = summary.costUSD { Text(String(format: "$%.2f", cost)) }
                }.font(.caption).monospacedDigit()
            }
            Text("Local totals read the newest log tails on this Mac and can miss earlier usage.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func connection(_ provider: ProviderStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider.id.hasPrefix("manual:") ? "Allowance" : "Connection").font(.headline)
            if provider.id.hasPrefix("manual:") {
                HStack {
                    TextField("Used", text: $draft.manualUsed).textFieldStyle(.roundedBorder)
                    TextField("Limit", text: $draft.manualLimit).textFieldStyle(.roundedBorder)
                    Button("Save") { saveManual(provider) }
                    Button("Remove", role: .destructive) { model.removeAllowance(provider.id) }
                }
            } else {
                SecureField(provider.source == "Saved token" || provider.source == "API key" ? "Key saved — enter a replacement" : "Optional key override", text: $draft.secret)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("provider.secret")
                HStack {
                    Button("Save key") { model.updateProviderSecret(provider.id, draft.secret); draft.secret = "" }.disabled(draft.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if provider.source == "Saved token" || provider.source == "API key" {
                        Button("Remove saved key", role: .destructive) { model.updateProviderSecret(provider.id, nil) }
                    }
                }
                HStack {
                    TextField("Monthly budget USD", text: $draft.budgetText).textFieldStyle(.roundedBorder).accessibilityIdentifier("provider.budget")
                    Button("Save budget") { model.updateBudget(id: provider.id, amount: ProviderDisplay.amount(draft.budgetText)) }
                }
                Text("Cursor is read from the app session already on this Mac, so this does not ask for your keychain password. In-house is Auto and Composer. 3rd party is API models. Codex uses the ChatGPT login in its auth file. A saved key is only a fallback and stays in Keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func loadDraft() {
        guard draft.providerID != provider?.id else { return }
        draft.providerID = provider?.id
        draft.secret = ""
        guard let provider else { draft.budgetText = ""; return }
        draft.budgetText = provider.budgetUSD.map { String(format: "%.2f", $0) } ?? ""
        if let window = provider.windows.first, provider.id.hasPrefix("manual:") {
            draft.manualUsed = window.used.map { String(format: "%g", $0) } ?? ""
            draft.manualLimit = window.limit.map { String(format: "%g", $0) } ?? ""
        }
    }
    private func saveManual(_ provider: ProviderStatus) {
        guard let current = model.providerSettings.manual.first(where: { $0.id == provider.id }) else { return }
        let used = ProviderDisplay.amount(draft.manualUsed) ?? 0
        let limit = ProviderDisplay.amount(draft.manualLimit) ?? 0
        model.updateAllowance(ManualAllowance(id: current.id, name: current.name, used: used, limit: limit, unit: current.unit))
    }
}
