import AppKit
import SwiftUI
import ServiceManagement
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

enum HistoryRange: String, CaseIterable, Identifiable {
    case minute = "1 minute", fiveMinutes = "5 minutes", halfHour = "30 minutes", hour = "Last hour", today = "Today", week = "7 days", custom = "Custom"
    var id: String { rawValue }
}

@MainActor final class AppModel: ObservableObject {
    @Published var sample: MachineSample?
    @Published var interval: UsageInterval?
    @Published var apps: [AppUsage] = [] { didSet { processIndex = Dictionary(apps.flatMap(\.processes).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); rebuildList(); listRevision += 1 } }
    @Published var paused = false
    @Published var sleeping = false
    @Published var helperConnected = false
    @Published var busy = false
    @Published var setupBusy = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var selected: String? { didSet { if oldValue != selected { selectionChanged() } } }
    @Published var selectedProcess: ProcessIdentity? { didSet { if oldValue != selectedProcess { selectionChanged() } } }
    @Published var contexts: [ProcessIdentity: ProcessContext] = [:] { didSet { listRevision += 1 } }
    @Published var expandedApps: Set<String> = []
    @Published var localSummaries: [String: RoleSummary] = [:]
    @Published var summaryFacts: [String: String] = [:]
    @Published var summaryBusy: String?
    private var pendingContexts: Set<ProcessIdentity> = []
    private let contextQueue = DispatchQueue(label: "ai.powerwatch.context", qos: .utility)
    @Published var query = "" { didSet { filterList() } }
    @Published var sort: UsageSort = .watts { didSet { if oldValue != sort { sortDescending = sort != .name } else { rebuildList() } } }
    @Published var sortDescending = true { didSet { rebuildList() } }
    @Published var historyRange: HistoryRange = .hour { didSet { refreshHistory() } }
    @Published var customStart = Date().addingTimeInterval(-3600) { didSet { if historyRange == .custom { refreshHistory() } } }
    @Published var customEnd = Date() { didSet { if historyRange == .custom { refreshHistory() } } }
    @Published var history = HistorySummary()
    @Published var selectedHistory = HistorySummary()
    @Published var historyMembers: [String: [HistoryRow]] = [:]
    @Published var expandedHistory: Set<String> = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var providers: [ProviderStatus] = []
    @Published var providerSettings = ProviderSettings()
    @Published var providerBusy = false
    @Published var hubShowsProviders = false
    @Published var hubShowsMoney = false
    @Published var ledgerEntries: [LedgerEntry] = []
    @Published var budgetRows: [BudgetRow] = []
    @Published var menuBudgetRows: [BudgetRow] = []
    @Published var menuBudgetLoading = false
    @Published var holdings: [Holding] = []
    @Published var portfolioPoints: [PortfolioPoint] = []
    @Published var moneyBusy = false
    @Published var moneyLoading = false
    @Published var plaidEnvironment = UserDefaults.standard.string(forKey: "ai.powerwatch.plaidEnvironment") ?? "sandbox"
    @Published var plaidReady = false
    @Published var jevEnabled = UserDefaults.standard.bool(forKey: "ai.powerwatch.jevEnabled")
    private var ledger: LedgerStore?
    private let moneyQueue = DispatchQueue(label: "ai.powerwatch.money.read", qos: .userInitiated)
    private var moneyGeneration = 0
    private var menuBudgetGeneration = 0
    private var menuBudgetVisible = false
    private let ledgerKeychain = KeychainSecretStore(service: "ai.powerwatch.ledger")
    @Published var selectedProvider: String?
    @Published var requestedHubTab: Int?
    private var providerTimer: Timer?
    private var providerGeneration = 0
    private let service = SamplingService()
    private var processIndex: [ProcessIdentity: ProcessUsage] = [:]
    private(set) var sortedApps: [AppUsage] = []
    private(set) var menuApps: [AppUsage] = []
    private(set) var listRevision = 0
    private var selectionWork: DispatchWorkItem?
    private var historyWork: DispatchWorkItem?
    @Published var historyLoading = false
    private var selectionBegan: Double?
    private var selectionEventBegan: Double?
    private var tabTransition: (tab: Int, began: Double)?
    private let historyQueue = DispatchQueue(label: "ai.powerwatch.history", qos: .utility)
    private var store: HistoryStore?
    private var timer: Timer?
    private var visible: Set<String> = []
    private var lastHistoryRead = Date.distantPast
    private var historyGeneration = 0
    private var samplingGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var icons: [String: NSImage] = [:]
    private let monitoringEnabled: Bool
    private lazy var detailsWindow = DetailsWindowController(model: self)
    private var statusBarController: StatusBarController?
    func openDetails() { detailsWindow.show() }
    func openPreferences() { detailsWindow.showPreferences() }
    func openQuickMenu() { detailsWindow.showQuickMenu() }
    func installStatusBar() {
        guard statusBarController == nil else { return }
        statusBarController = StatusBarController(model: self)
    }
    var cadence: Double { visible.isEmpty ? 15 : 5 }
    var selectedApp: AppUsage? { apps.first { $0.id == selected } }
    var process: ProcessUsage? { selectedProcess.flatMap { identity in processIndex[identity] } }
    var helperInstalled: Bool { FileManager.default.fileExists(atPath: PowerWatchConstants.installedHelper) }
    var menuLabel: String {
        if paused { return "Paused" }
        guard let battery = sample?.battery else { return "YooTrack" }
        let level = "\(Int(battery.percentage.rounded()))%"
        if let watts = battery.dischargeWatts { return "\(level) · \(String(format: "%.1f", watts)) W" }
        return level + (battery.charging ? " · Charging" : battery.onBattery ? "" : " · AC")
    }
    private func rebuildList() {
        menuApps = AppSorting.sorted(apps, by: sort, descending: sortDescending)
        filterList()
    }
    private func filterList() {
        sortedApps = menuApps.filter { app in query.isEmpty || app.name.localizedCaseInsensitiveContains(query) || app.processes.contains { $0.reading.path.localizedCaseInsensitiveContains(query) || String($0.id.pid).contains(query) || $0.reading.name.localizedCaseInsensitiveContains(query) } }
    }
    func sortBy(_ column: UsageSort) { if sort == column { sortDescending.toggle() } else { sort = column } }
    init(monitoringEnabled: Bool = true, historyURL: URL? = nil) {
        self.monitoringEnabled = monitoringEnabled
        do {
            if let historyURL {
                store = try HistoryStore(url: historyURL)
                ledger = try LedgerStore(url: historyURL.deletingLastPathComponent().appendingPathComponent("ledger.sqlite"))
            } else {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let otherInstanceRunning = NSRunningApplication.runningApplications(withBundleIdentifier: PowerWatchConstants.appIdentifier)
                    .contains { $0.processIdentifier != getpid() && !$0.isTerminated }
                let dataDirectory = try DataDirectory.prepare(in: base, allowLegacyMigration: !otherInstanceRunning)
                store = try HistoryStore(url: dataDirectory.appendingPathComponent("history.sqlite"))
                ledger = try LedgerStore(url: dataDirectory.appendingPathComponent("ledger.sqlite"))
            }
        } catch { errorMessage = "Local storage: \(error.localizedDescription)" }
        if let data = UserDefaults.standard.data(forKey: ProviderSettings.defaultsKey), let decoded = try? JSONDecoder().decode(ProviderSettings.self, from: data) {
            providerSettings = decoded
        }
        guard monitoringEnabled else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sleeping = true; self?.suspend() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sleeping = false; self?.schedule(); self?.scheduleProviders() } })
        schedule(); scheduleProviders(); refreshHistory()
    }
    func visibility(_ source: String, isVisible: Bool) {
        let old = cadence
        if isVisible { visible.insert(source) } else { visible.remove(source) }
        if source == "details", !isVisible {
            moneyGeneration += 1; moneyLoading = false
            ledgerEntries = []; budgetRows = []; holdings = []; portfolioPoints = []
        }
        if visible.isEmpty {
            // SwiftUI retains closed-window scenes. Drop their expensive rows, icons and charts explicitly.
            apps = []; interval = nil; history = HistorySummary(); selectedHistory = HistorySummary(); icons.removeAll(); contexts.removeAll(); localSummaries.removeAll(); summaryFacts.removeAll()
            if let sample { self.sample = MachineSample(timestamp: sample.timestamp, uptime: sample.uptime, processes: [], battery: sample.battery, hardware: sample.hardware, gpu: sample.gpu, issues: sample.issues) }
            historyQueue.asyncAfter(deadline: .now() + 1) { _ = malloc_zone_pressure_relief(nil, 0) }
        }
        if old != cadence { schedule(); scheduleProviders(); if isVisible { refreshHistory() } }
    }
    func schedule() {
        timer?.invalidate(); timer = nil
        guard monitoringEnabled, !paused, !sleeping else { return }
        timer = Timer.scheduledTimer(withTimeInterval: cadence, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.collect() } }
        timer?.tolerance = cadence * 0.15
        collect()
    }
    func collect() {
        guard monitoringEnabled, !busy, !paused, !sleeping else { return }
        busy = true; let requestedCadence = cadence; let generation = samplingGeneration
        service.fetch(interval: requestedCadence) { [weak self] sample, usage, groups, connected in
            DispatchQueue.main.async {
                guard let self, generation == self.samplingGeneration, !self.paused, !self.sleeping else { return }
                self.busy = false; self.helperConnected = connected
                self.sample = self.visible.isEmpty ? MachineSample(timestamp: sample.timestamp, uptime: sample.uptime, processes: [], battery: sample.battery, hardware: sample.hardware, gpu: sample.gpu, issues: sample.issues) : sample
                if !self.visible.isEmpty { self.interval = usage; self.apps = groups; self.loadSelectedContexts()
                    let live = Set(usage.processes.map(\.id)); self.contexts = self.contexts.filter { live.contains($0.key) }
                }
                if let store = self.store {
                    self.historyQueue.async {
                        do { try store.record(usage) }
                        catch { DispatchQueue.main.async { self.errorMessage = "History storage: \(error.localizedDescription)" } }
                    }
                }
                // Opt-in local diagnostics for reproducible validation; disabled during ordinary launches.
                let arguments = CommandLine.arguments
                if let index = arguments.firstIndex(of: "--diagnostics-path"), arguments.indices.contains(index + 1) {
                    let path = arguments[index + 1]
                    let diagnostic = DiagnosticSample(sample: sample, collectorConnected: connected, cadence: requestedCadence, visibleViews: self.visible.sorted())
                    self.historyQueue.async { if let data = try? JSONEncoder().encode(diagnostic) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) } }
                }
                if !self.visible.isEmpty, Date().timeIntervalSince(self.lastHistoryRead) >= (self.historyRange == .minute || self.historyRange == .fiveMinutes ? 4 : 15) { self.refreshHistory() }
            }
        }
    }
    func role(for process: ProcessUsage) -> String {
        contexts[process.id]?.role ?? ProcessInspector.role(name: process.reading.name, path: process.reading.path)
    }
    func expand(_ app: AppUsage, isExpanded: Bool) {
        if isExpanded { expandedApps.insert(app.id); loadContexts(app.processes.map(\.reading)) }
        else { expandedApps.remove(app.id) }
    }
    private func loadSelectedContexts() {
        if let process { loadContexts([process.reading]) }
        else if let app = selectedApp { loadContexts(app.processes.map(\.reading)) }
        for app in apps where expandedApps.contains(app.id) { loadContexts(app.processes.map(\.reading)) }
    }
    func loadContexts(_ readings: [ProcessReading]) {
        let missing = readings.filter { contexts[$0.identity] == nil && !pendingContexts.contains($0.identity) }
        guard !missing.isEmpty else { return }
        pendingContexts.formUnion(missing.map(\.identity))
        contextQueue.async {
            let results = missing.compactMap(ProcessInspector.inspect)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingContexts.subtract(missing.map(\.identity))
                guard !self.visible.isEmpty else { return }
                var updated = self.contexts
                for context in results { updated[context.identity] = context }
                self.contexts = updated
            }
        }
    }
    func refreshSelectedContext() {
        let readings = process.map { [$0.reading] } ?? selectedApp?.processes.map(\.reading) ?? []
        for reading in readings { contexts[reading.identity] = nil }
        localSummaries[summaryKey] = nil; summaryFacts[summaryKey] = nil
        loadContexts(readings)
    }
    var gpuUnavailable: Bool { sample.map { !$0.processes.contains { $0.gpuMillisecondsPerSecond != nil } } ?? false }
    var summaryKey: String { selectedProcess.map { "pid:" + $0.key } ?? selected ?? "overview" }
    func descendants(of roots: [ProcessUsage]) -> [ProcessTreeNode] {
        ProcessInspector.descendants(of: roots, in: interval?.processes ?? [])
    }
    func projectSnapshots(_ processes: [ProcessUsage]) -> [ProjectSnapshot] {
        ProcessInspector.projectSnapshots(targets: processes, contexts: processes.compactMap { contexts[$0.id] }, allProcesses: interval?.processes ?? processes)
    }
    func selectProcess(_ target: ProcessUsage) {
        expandedApps.insert(target.groupKey)
        select(app: target.groupKey, process: target.id)
    }
    func selectPID(_ pid: Int32) {
        guard let match = interval?.processes.first(where: { $0.id.pid == pid }) else { return }
        selectProcess(match)
    }
    func summarizeSelection() {
        guard summaryBusy == nil else { return }
        let targets = process.map { [$0] } ?? selectedApp?.processes ?? []
        let readings = targets.map(\.reading)
        guard !readings.isEmpty else { return }
        let title = process?.reading.name ?? selectedApp?.name ?? "Selection"
        let allProcesses = interval?.processes ?? targets
        let key = summaryKey
        summaryBusy = key
        Task {
            do {
                let observations = await withCheckedContinuation { continuation in
                    contextQueue.async { continuation.resume(returning: readings.compactMap(ProcessInspector.inspect)) }
                }
                guard !observations.isEmpty else { throw NSError(domain: "PowerWatch.LocalAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected processes exited before inspection."]) }
                let digest = ProcessInspector.usageDigest(title: title, targets: targets, contexts: observations, allProcesses: allProcesses)
                let byIdentity = Dictionary(readings.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
                let roles = Array(Set(observations.map { context in
                    if let reading = byIdentity[context.identity], let guide = ServiceDescriptions.guide(for: reading) { return guide.purpose }
                    return context.role.components(separatedBy: " · ").first!
                })).sorted()
                if !visible.isEmpty, summaryKey == key { summaryFacts[key] = digest }
                let summary = try await RoleSummaries.explain(roles: roles, digest: digest, unavailableReason: LocalSummaries.unavailableReason) { _ in
                    guard digest.count <= 9000 else { throw NSError(domain: "PowerWatch.LocalAI", code: 3) }
                    return try await LocalSummaries.summarize(evidence: digest)
                }
                if !visible.isEmpty, summaryKey == key { localSummaries[key] = summary }
            } catch { if !visible.isEmpty, summaryKey == key { errorMessage = "Local summary: " + error.localizedDescription } }
            summaryBusy = nil
        }
    }
    func togglePause() {
        paused.toggle()
        if paused { suspend(); statusMessage = "Monitoring paused. No samples are being collected." }
        else { statusMessage = nil; schedule() }
    }
    func suspend() {
        timer?.invalidate(); timer = nil; samplingGeneration += 1; busy = false; service.stop(); helperConnected = false
        // A stale reading must not look like live usage while monitoring is stopped.
        apps = []; interval = nil
    }
    func quit() { suspend(); NSApplication.shared.terminate(nil) }
    func select(app: String?, process: ProcessIdentity? = nil) {
        selectionBegan = ProcessInfo.processInfo.systemUptime
        if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .keyDown].contains(event.type), let began = selectionBegan, began - event.timestamp >= 0, began - event.timestamp < 0.5 { selectionEventBegan = event.timestamp } else { selectionEventBegan = nil }
        selected = app; selectedProcess = process
    }
    func selectionRendered(key: String) {
        guard key == summaryKey else { return }
        guard let began = selectionBegan else { return }
        selectionBegan = nil
        let rendered = ProcessInfo.processInfo.systemUptime
        recordInteraction(["kind": "selection", "handler_to_view_ms": (rendered - began) * 1000, "event_to_view_ms": selectionEventBegan.map { (rendered - $0) * 1000 } as Any? ?? NSNull()])
    }
    func beginTabTransition(to tab: Int) { tabTransition = (tab, ProcessInfo.processInfo.systemUptime) }
    func tabRendered(_ tab: Int, viewUpdated: Double) {
        guard let transition = tabTransition, transition.tab == tab else { return }
        tabTransition = nil
        let callback = ProcessInfo.processInfo.systemUptime
        let names = ["live", "history", "ai", "money"]
        recordInteraction(["kind": "tab", "tab": names.indices.contains(tab) ? names[tab] : "unknown", "handler_to_view_ms": (callback - transition.began) * 1000,
            "handler_to_update_ms": (viewUpdated - transition.began) * 1000, "update_to_callback_ms": (callback - viewUpdated) * 1000])
    }
    private func recordInteraction(_ row: [String: Any]) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--interaction-log"), arguments.indices.contains(index + 1) else { return }
        let path = arguments[index + 1]
        contextQueue.async {
            guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            data.append(10)
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
        }
    }
    private func selectionChanged() {
        selectionWork?.cancel(); historyWork?.cancel(); historyGeneration += 1
        selectedHistory = HistorySummary(); historyLoading = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.loadSelectedContexts(); self.refreshHistory(includeOverview: false)
        }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    func refreshHistory(includeOverview: Bool = true) {
        guard monitoringEnabled, let store else { return }
        historyWork?.cancel()
        historyGeneration += 1; let generation = historyGeneration
        let end = historyRange == .custom ? customEnd : Date()
        let start: Date
        switch historyRange {
        case .minute: start = end.addingTimeInterval(-60)
        case .fiveMinutes: start = end.addingTimeInterval(-300)
        case .halfHour: start = end.addingTimeInterval(-1800)
        case .hour: start = end.addingTimeInterval(-3600)
        case .today: start = Calendar.current.startOfDay(for: end)
        case .week: start = end.addingTimeInterval(-7 * 86400)
        case .custom: start = customStart
        }
        guard start < end else { historyLoading = false; statusMessage = "Choose an end time later than the start time."; return }
        historyLoading = true
        let entity = selectedProcess.map { "pid:" + $0.key } ?? selected
        let groups = expandedHistory
        lastHistoryRead = Date()
        let work = DispatchWorkItem { [weak self] in
            do {
                let all = try includeOverview || entity == nil ? store.summary(from: start, to: end) : nil
                let individual = try entity.map { try store.summary(from: start, to: end, entity: $0) } ?? all!
                var members: [String: [HistoryRow]] = [:]
                for group in groups { members[group] = try store.summary(from: start, to: end, membersOf: group).rows }
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.historyGeneration else { return }
                    if let all { self.history = all }
                    self.selectedHistory = individual
                    if !members.isEmpty { self.historyMembers.merge(members) { _, new in new } }
                    self.historyLoading = false
                }
            } catch { DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.historyGeneration else { return }
                self.historyLoading = false; self.errorMessage = "History query: \(error.localizedDescription)"
            } }
        }
        historyWork = work; historyQueue.async(execute: work)
    }
    func toggleHistoryGroup(_ id: String) {
        if expandedHistory.contains(id) { expandedHistory.remove(id); return }
        expandedHistory.insert(id)
        refreshHistory(includeOverview: false)
    }
    func icon(for app: AppUsage) -> NSImage {
        icon(bundlePath: app.bundlePath, id: app.id, name: app.name)
    }
    func icon(for row: HistoryRow) -> NSImage {
        icon(bundlePath: row.bundlePath, id: row.id, name: row.name)
    }
    private func icon(bundlePath: String?, id: String, name: String) -> NSImage {
        let key = bundlePath ?? (id == PowerWatchConstants.monitorGroup ? "symbol:monitor" : "symbol:process")
        if let cached = icons[key] { return cached }
        let source = bundlePath.flatMap { FileManager.default.fileExists(atPath: $0) ? NSWorkspace.shared.icon(forFile: $0) : nil } ?? (id == PowerWatchConstants.monitorGroup ? YooTrackBrand.mark : NSImage(systemSymbolName: "gearshape", accessibilityDescription: name)!)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        source.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64)); NSGraphicsContext.restoreGraphicsState()
        let icon = NSImage(size: NSSize(width: 32, height: 32)); icon.addRepresentation(bitmap); icon.isTemplate = source.isTemplate
        if icons.count >= 256, let oldest = icons.keys.first { icons.removeValue(forKey: oldest) }
        icons[key] = icon; return icon
    }
    func control(_ reading: ProcessReading, force: Bool) {
        do {
            try ProcessControl.execute(reading, force: force)
            statusMessage = force ? "Force quit requested for \(reading.name)." : "Quit requested for \(reading.name). An app can ask you to save or cancel."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.collect() }
        } catch { errorMessage = error.localizedDescription }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin { statusMessage = "Allow YooTrack in System Settings → General → Login Items."; SMAppService.openSystemSettingsLoginItems() }
        } catch { errorMessage = error.localizedDescription; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    func focusProvider(_ id: String?) {
        if let id { selectedProvider = id }
        else if selectedProvider == nil { selectedProvider = providers.first?.id }
        requestedHubTab = 2
        if !hubShowsProviders { hubShowsProviders = true }
        hubShowsMoney = false
        openDetails()
    }
    func refreshProviders() {
        guard monitoringEnabled else { return }
        if providers.isEmpty {
            providers = [ProviderStatus.checking("cursor", "Cursor"), ProviderStatus.checking("anthropic", "Anthropic"), ProviderStatus.checking("openai", "OpenAI")]
        }
        providerGeneration += 1
        let generation = providerGeneration
        let settings = providerSettings
        providerBusy = true
        Task.detached { [weak self] in
            let statuses = await ProviderUsageService.collect(settings: settings)
            await MainActor.run { [weak self] in
                guard let self, generation == self.providerGeneration else { return }
                self.providers = statuses
                self.providerBusy = false
                if self.selectedProvider == nil { self.selectedProvider = statuses.first?.id }
            }
        }
    }
    func scheduleProviders() {
        providerTimer?.invalidate(); providerTimer = nil
        guard monitoringEnabled else { return }
        let interval = visible.isEmpty ? 300.0 : 60.0
        providerTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshProviders() } }
        providerTimer?.tolerance = interval * 0.2
        refreshProviders()
    }
    func updateProviderSecret(_ id: String, _ value: String?) {
        guard !id.hasPrefix("manual:") else { return }
        do {
            try KeychainSecretStore().setSecret(value, account: id)
            let name = providers.first { $0.id == id }?.name ?? "Provider"
            statusMessage = value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "Saved \(name) in Keychain." : "Removed the saved \(name) credential."
            refreshProviders()
        } catch { errorMessage = error.localizedDescription }
    }
    func updateBudget(id: String, amount: Double?) {
        if let amount, amount > 0, amount.isFinite { providerSettings.monthlyBudgetUSD[id] = amount }
        else { providerSettings.monthlyBudgetUSD.removeValue(forKey: id) }
        persistProviderSettings(); refreshProviders()
    }
    @discardableResult func addAllowance(name: String, used: Double, limit: Double, unit: String) -> Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, limit > 0, limit.isFinite, used >= 0, used.isFinite else { errorMessage = "Enter a name, a used amount, and a limit greater than zero."; return false }
        let allowance = ManualAllowance(id: "manual:" + UUID().uuidString, name: title, used: used, limit: limit, unit: unit.isEmpty ? "USD" : unit)
        providerSettings.manual.append(allowance)
        providers.append(ProviderUsageService.manual(allowance, now: Date()))
        selectedProvider = allowance.id
        persistProviderSettings()
        return true
    }
    func updateAllowance(_ allowance: ManualAllowance) {
        guard let index = providerSettings.manual.firstIndex(where: { $0.id == allowance.id }), allowance.limit > 0, allowance.used >= 0 else { errorMessage = "Enter a used amount and a limit greater than zero."; return }
        providerSettings.manual[index] = allowance
        if let row = providers.firstIndex(where: { $0.id == allowance.id }) { providers[row] = ProviderUsageService.manual(allowance, now: Date()) }
        persistProviderSettings()
    }
    func removeAllowance(_ id: String) {
        providerSettings.manual.removeAll { $0.id == id }
        providers.removeAll { $0.id == id }
        if selectedProvider == id { selectedProvider = providers.first?.id }
        persistProviderSettings()
    }
    private func persistProviderSettings() {
        if let data = try? JSONEncoder().encode(providerSettings) { UserDefaults.standard.set(data, forKey: ProviderSettings.defaultsKey) }
    }
    func clearHistory() {
        guard let store else { return }
        historyQueue.async { [weak self] in
            do { try store.clear(); DispatchQueue.main.async { self?.refreshHistory() } }
            catch { DispatchQueue.main.async { self?.errorMessage = error.localizedDescription } }
        }
    }
    func installHelper(removing: Bool = false) {
        guard !setupBusy else { return }
        guard let script = Bundle.main.url(forResource: removing ? "uninstall-helper" : "install-helper", withExtension: "sh") else { errorMessage = "Open the bundled .app to use the administrator installer."; return }
        setupBusy = true; suspend()
        let bundle = Bundle.main.bundleURL.path
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/bin/sh " + quote(script.path) + (removing ? "" : " " + quote(bundle) + " " + String(getuid()))
        let appleLiteral = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        historyQueue.async { [weak self] in
            let process = Process(); let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(appleLiteral) with administrator privileges"]
            process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            var failure: String?
            do { try process.run(); process.waitUntilExit(); if process.terminationStatus != 0 { failure = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Administrator setup failed." } }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }; self.setupBusy = false
                if let failure { self.errorMessage = failure }
                else { self.statusMessage = removing ? "Collector removed. Basic monitoring is still available." : "Administrator collector installed." }
                self.schedule()
            }
        }
    }
    func reloadMoney() {
        guard let ledger else { return }
        if menuBudgetVisible { reloadMenuBudget() }
        moneyGeneration += 1
        let generation = moneyGeneration, keychain = ledgerKeychain
        moneyLoading = true
        moneyQueue.async { [weak self] in
            do {
                let entries = try ledger.entries()
                let budgets = try ledger.budget()
                let holdings = try ledger.holdings()
                let portfolio = try ledger.portfolio()
                let ready = keychain.secret(account: "plaid-secret") != nil && keychain.secret(account: "plaid-client-id") != nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.moneyGeneration == generation else { return }
                    self.ledgerEntries = entries; self.budgetRows = budgets
                    self.holdings = holdings; self.portfolioPoints = portfolio
                    self.plaidReady = ready; self.moneyLoading = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.moneyGeneration == generation else { return }
                    self.moneyLoading = false; self.errorMessage = "Money ledger: \(error.localizedDescription)"
                }
            }
        }
    }
    func setMenuBudgetVisible(_ visible: Bool) {
        menuBudgetVisible = visible
        if visible { reloadMenuBudget() }
        else {
            menuBudgetGeneration += 1; menuBudgetLoading = false
            if monitoringEnabled { menuBudgetRows = [] }
        }
    }
    private func reloadMenuBudget() {
        guard monitoringEnabled, let ledger else { return }
        menuBudgetGeneration += 1
        let generation = menuBudgetGeneration
        menuBudgetLoading = true
        moneyQueue.async { [weak self] in
            do {
                let rows = try ledger.budget()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.menuBudgetVisible, self.menuBudgetGeneration == generation else { return }
                    self.menuBudgetRows = rows; self.menuBudgetLoading = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.menuBudgetVisible, self.menuBudgetGeneration == generation else { return }
                    self.menuBudgetLoading = false; self.errorMessage = "Budget: \(error.localizedDescription)"
                }
            }
        }
    }
    func addSpend(payee: String, amount: String, income: Bool) {
        guard let cents = MoneyMath.cents(from: amount), cents > 0 else { errorMessage = "Enter an amount like 12.50."; return }
        do { _ = try ledger?.add(payee: payee, cents: income ? cents : -cents, category: nil); reloadMoney(); statusMessage = "Saved on this Mac." }
        catch { errorMessage = error.localizedDescription }
    }
    func setSpendCategory(id: String, category: String) {
        do { try ledger?.setCategory(id: id, category: category); reloadMoney() } catch { errorMessage = error.localizedDescription }
    }
    func categorizeMoneyLocally() {
        do { let count = try ledger?.categorizeLocally() ?? 0; reloadMoney(); statusMessage = count == 0 ? "No local category matched the blank payees." : "Categorized \(count) on this Mac." }
        catch { errorMessage = error.localizedDescription }
    }
    func setBudget(category: String, amount: String) {
        guard let cents = MoneyMath.cents(from: amount) else { errorMessage = "Enter a monthly limit like 400."; return }
        do { try ledger?.setBudget(category: category, monthlyCents: cents); reloadMoney() } catch { errorMessage = error.localizedDescription }
    }
    func addManualHolding(symbol: String, amount: String) {
        guard let cents = MoneyMath.cents(from: amount) else { errorMessage = "Enter a holding value like 1000."; return }
        do { try ledger?.addManualHolding(symbol: symbol, valueCents: cents, day: Self.ledgerDay()); reloadMoney() } catch { errorMessage = error.localizedDescription }
    }
    func setJevEnabled(_ enabled: Bool) {
        jevEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "ai.powerwatch.jevEnabled")
    }
    func saveLedgerSecret(_ value: String, account: String) {
        do { try ledgerKeychain.setSecret(value, account: account); reloadMoney(); statusMessage = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Removed the saved credential." : "Saved in Keychain. It is not shown again." }
        catch { errorMessage = error.localizedDescription }
    }
    func setPlaidEnvironment(_ environment: String) {
        plaidEnvironment = environment == "production" ? "production" : "sandbox"
        UserDefaults.standard.set(plaidEnvironment, forKey: "ai.powerwatch.plaidEnvironment")
    }
    func connectPlaid() {
        guard let clientID = ledgerKeychain.secret(account: "plaid-client-id"), let secret = ledgerKeychain.secret(account: "plaid-secret") else { errorMessage = "Save a Plaid client ID and secret first."; return }
        moneyBusy = true
        let environment = plaidEnvironment, user = ledgerUserID
        Task {
            defer { moneyBusy = false }
            do {
                let link = try await PlaidClient(environment: environment).createHostedLink(clientID: clientID, secret: secret, userID: user)
                try ledgerKeychain.setSecret(link.token, account: "plaid-link-token")
                NSWorkspace.shared.open(link.url)
                statusMessage = "Finish in the browser, then choose Check connection. The access token stays in Keychain."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func finishPlaidLink() {
        guard let clientID = ledgerKeychain.secret(account: "plaid-client-id"), let secret = ledgerKeychain.secret(account: "plaid-secret"), let linkToken = ledgerKeychain.secret(account: "plaid-link-token") else { errorMessage = "Start Connect accounts first."; return }
        moneyBusy = true
        let environment = plaidEnvironment
        Task {
            defer { moneyBusy = false }
            do {
                let client = PlaidClient(environment: environment)
                let tokens = try await client.publicTokens(clientID: clientID, secret: secret, linkToken: linkToken)
                guard !tokens.isEmpty else { statusMessage = "The bank connection is not finished yet."; return }
                for token in tokens {
                    let exchanged = try await client.exchange(clientID: clientID, secret: secret, publicToken: token)
                    try ledgerKeychain.setSecret(exchanged.access, account: "plaid-access-" + exchanged.item)
                    try ledger?.apply(PlaidSyncChange(added: [], modified: [], removedIDs: [], nextCursor: "", hasMore: false), item: exchanged.item, environment: environment)
                }
                try ledgerKeychain.setSecret(nil, account: "plaid-link-token")
                statusMessage = "Account connected on this Mac. Sync to download transactions."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func syncPlaid() {
        guard let ledger, let clientID = ledgerKeychain.secret(account: "plaid-client-id"), let secret = ledgerKeychain.secret(account: "plaid-secret") else { errorMessage = "Save Plaid credentials and connect an account first."; return }
        moneyBusy = true
        let day = Self.ledgerDay()
        Task {
            defer { moneyBusy = false }
            do {
                let items = try ledger.plaidItems()
                guard !items.isEmpty else { statusMessage = "No connected account yet."; return }
                for item in items {
                    guard let access = ledgerKeychain.secret(account: "plaid-access-" + item.id) else { continue }
                    let client = PlaidClient(environment: item.environment)
                    var cursor = item.cursor
                    for _ in 0..<20 {
                        let page = try await client.sync(clientID: clientID, secret: secret, access: access, cursor: cursor)
                        try ledger.apply(page, item: item.id, environment: item.environment)
                        cursor = page.nextCursor
                        if !page.hasMore { break }
                    }
                    if let rows = try? await client.investments(clientID: clientID, secret: secret, access: access), !rows.isEmpty {
                        try ledger.replaceHoldings(rows, item: item.id, day: day)
                    }
                }
                reloadMoney()
                statusMessage = "Synced from Plaid. Matching payees were categorized on this Mac."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func categorizeWithJev() {
        guard jevEnabled, let key = ledgerKeychain.secret(account: "jev"), let ledger else { errorMessage = "Turn on Jev and save a key. That sends payee names off this Mac."; return }
        let pending = Array(ledgerEntries.filter { $0.category == nil }.prefix(25))
        guard !pending.isEmpty else { statusMessage = "Nothing uncategorized."; return }
        moneyBusy = true
        Task {
            defer { moneyBusy = false }
            do {
                let client = JevClient()
                var applied = 0
                for entry in pending {
                    if let guess = try await client.categorize(payee: entry.payee, key: key), guess.applies {
                        try ledger.applyGuess(id: entry.id, guess: guess)
                        applied += 1
                    }
                }
                reloadMoney()
                statusMessage = "Jev categorized \(applied) of \(pending.count). Amounts and account numbers were not sent."
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private var ledgerUserID: String {
        if let existing = UserDefaults.standard.string(forKey: "ai.powerwatch.ledgerUser"), !existing.isEmpty { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: "ai.powerwatch.ledgerUser")
        return created
    }
    private static func ledgerDay(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct DiagnosticSample: Encodable {
    let sample: MachineSample
    let collectorConnected: Bool
    let cadence: Double
    let visibleViews: [String]
}
