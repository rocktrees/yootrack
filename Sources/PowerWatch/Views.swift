import SwiftUI
import Charts
import AppKit
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

enum Display {
    static func watts(_ value: Double?) -> String { value.map { String(format: "%.2f W", $0) } ?? "—" }
    static func decimal(_ value: Double?, suffix: String = "") -> String { value.map { String(format: "%.1f", $0) + suffix } ?? "—" }
    static func energy(_ joules: Double) -> String { String(format: "%.3f Wh", joules / 3600) }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value == 0 { return "0 B/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max / 2))), countStyle: .binary) + "/s"
    }
    static func memory(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory) }
}

/// Fixed metric widths keep headers, app groups and expanded process rows aligned.
struct UsageCells: View {
    var compact = false
    var cpu: Double?
    var memory: UInt64?
    var gpu: Double?
    var received: Double?
    var sent: Double?
    var watts: Double?
    var partial = false
    init(app: AppUsage, compact: Bool = false) {
        self.compact = compact
        cpu = app.cpuPercent; memory = app.knownMemoryBytes; gpu = app.gpuMillisecondsPerSecond
        received = app.networkReceivedBytesPerSecond; sent = app.networkSentBytesPerSecond
        watts = app.processorWatts; partial = app.partial
    }
    init(process: ProcessUsage) {
        cpu = process.cpuPercent; memory = process.reading.memoryBytes; gpu = process.reading.gpuMillisecondsPerSecond
        received = process.reading.networkReceivedBytesPerSecond; sent = process.reading.networkSentBytesPerSecond
        watts = process.processorWatts
    }
    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            Text(Display.decimal(cpu, suffix: "%")).frame(width: compact ? 48 : 52, alignment: .trailing)
            Text(memory.map(Display.memory) ?? "—").frame(width: compact ? 60 : 68, alignment: .trailing)
            Text(Display.decimal(gpu.map { $0 / 10 }, suffix: "%")).frame(width: compact ? 44 : 64, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text("↓ " + Display.rate(received)); Text("↑ " + Display.rate(sent))
            }.frame(width: compact ? 80 : 100, alignment: .trailing)
            Text(Display.watts(watts) + (partial ? "*" : "")).frame(width: compact ? 56 : 72, alignment: .trailing)
        }.font(compact ? .caption2 : .caption).monospacedDigit().foregroundStyle(.secondary).minimumScaleFactor(0.8)
    }
    static func header(model: AppModel, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            SortColumn(model: model, column: .cpu, label: "CPU").frame(width: compact ? 48 : 52, alignment: .trailing)
            SortColumn(model: model, column: .memory, label: "Memory").frame(width: compact ? 60 : 68, alignment: .trailing)
            SortColumn(model: model, column: .gpu, label: "GPU").frame(width: compact ? 44 : 64, alignment: .trailing)
            SortColumn(model: model, column: .network, label: compact ? "Net ↓/↑" : "Network ↓/↑").frame(width: compact ? 80 : 100, alignment: .trailing)
            SortColumn(model: model, column: .watts, label: "Power").frame(width: compact ? 56 : 72, alignment: .trailing)
        }.font(.caption2).foregroundStyle(.secondary)
    }
}

private struct SortColumn: View {
    @ObservedObject var model: AppModel
    var column: UsageSort
    var label: String
    var body: some View {
        Button { model.sortBy(column) } label: {
            HStack(spacing: 3) {
                Text(label)
                if model.sort == column { Image(systemName: model.sortDescending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .semibold)) }
            }.frame(maxWidth: .infinity, alignment: .trailing).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("sort." + String(describing: column))
            .accessibilityLabel(label + (model.sort == column ? (model.sortDescending ? ", descending" : ", ascending") : ""))
            .help(column == .network ? "Sort by combined receive/send rate. Click again to reverse; unavailable readings stay last." : "Sort by " + column.rawValue + ". Click again to reverse; unavailable readings stay last.")
    }
}

struct QuickMenu: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: "bolt.circle.fill").foregroundStyle(.teal); Text("YooTrack").font(.headline); Spacer(); Text(model.menuLabel).font(.caption).monospacedDigit() }
            Picker("View", selection: $tab) { Text("Live").tag(0); Text("History").tag(1) }
                .pickerStyle(.segmented).accessibilityIdentifier("menu.view")
            if tab == 0 { liveContent } else { historyContent }
            if !model.helperConnected { Text(model.setupBusy ? "Installing collector…" : "Basic monitoring · collector not connected").font(.caption).foregroundStyle(.orange) }
            Divider()
            ProviderMenuSection(model: model)
            Divider()
            HStack {
                Button("Open Details", action: openDetails).buttonStyle(.borderedProminent).tint(.teal)
                Spacer(); Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
            }
            HStack { Button("Settings…") { model.openPreferences() }; Spacer(); Button("Quit YooTrack") { model.quit() } }.font(.caption)
        }.padding(14).frame(width: 520).accessibilityElement(children: .contain).accessibilityIdentifier("quick.menu")
            .onAppear { model.visibility("menu", isVisible: true) }.onDisappear { model.visibility("menu", isVisible: false) }
            .onChange(of: tab) { _, next in if next == 1 { model.refreshHistory() } }
            .alert("YooTrack", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
    @ViewBuilder private var liveContent: some View {
            if model.paused { Text("Monitoring is paused.").foregroundStyle(.secondary) }
            else if model.apps.isEmpty { Text("Reading live processes…").font(.caption).foregroundStyle(.secondary) }
            else {
                Text("Sorted by " + model.sort.rawValue.lowercased() + (model.sortDescending ? " · descending" : " · ascending")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    SortColumn(model: model, column: .name, label: "App").frame(width: 60)
                    Spacer(minLength: 4); UsageCells.header(model: model, compact: true); Color.clear.frame(width: 18)
                }.font(.caption2)
                ForEach(model.menuApps.prefix(8)) { app in
                    HStack(spacing: 6) {
                        Image(nsImage: model.icon(for: app)).resizable().frame(width: 20, height: 20)
                        Button { model.select(app: app.id); openDetails() } label: {
                            HStack(spacing: 6) { Text(app.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(app.name); UsageCells(app: app, compact: true) }.padding(.vertical, 3)
                        }.buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("menu.consumer." + app.id)
                        if let target = ProcessControl.target(for: app) {
                            Button { model.control(target, force: false) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).frame(width: 18).help("Ask \(app.name) to quit")
                        } else { Color.clear.frame(width: 18, height: 20)
                        }
                    }
                }
                if model.apps.contains(where: \.partial) { Text("* Some process power counters are unavailable. Network requires the collector; — means unavailable.").font(.caption2).foregroundStyle(.secondary) }
            }
            Text("Device GPU: " + Display.decimal(model.sample?.gpu?.utilizationPercent, suffix: "%")).font(.caption).monospacedDigit()
            if model.gpuUnavailable { Text("Waiting for readable process GPU counters and a second sample; — means unavailable.").font(.caption2).foregroundStyle(.secondary) }
    }
    private var historyContent: some View {
        let total = model.history.rows.reduce(0) { $0 + $1.joules }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Processor history").font(.caption.bold())
                Spacer()
                Picker("Period", selection: $model.historyRange) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 140).accessibilityIdentifier("menu.history.period")
            }
            if model.historyRange == .custom {
                VStack(alignment: .leading) { DatePicker("From", selection: $model.customStart); DatePicker("To", selection: $model.customEnd) }.font(.caption)
            }
            HStack {
                Text("App / process").frame(maxWidth: .infinity, alignment: .leading)
                Text("Avg power").frame(width: 76, alignment: .trailing)
                Text("Energy").frame(width: 76, alignment: .trailing)
                Text("Share").frame(width: 60, alignment: .trailing)
            }.font(.caption2).foregroundStyle(.secondary)
            if model.historyRange == .custom && model.customStart >= model.customEnd {
                Text("Choose an end time later than the start time.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else if model.historyLoading {
                Text("Loading history…").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else if model.history.rows.isEmpty {
                Text("History appears after active processes have been observed for a full interval.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history.rows) { row in
                            Button {
                                model.select(app: row.id)
                                model.requestedHubTab = 1
                                model.openDetails()
                            } label: {
                                HStack {
                                    Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(row.name)
                                    Text(Display.watts(row.averageWatts)).frame(width: 76, alignment: .trailing)
                                    Text(Display.energy(row.joules)).frame(width: 76, alignment: .trailing)
                                    Text(Display.decimal(total > 0 ? row.joules / total * 100 : nil, suffix: "%")).frame(width: 60, alignment: .trailing)
                                }.font(.caption).monospacedDigit().padding(.vertical, 5)
                            }.buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("menu.history." + row.id)
                            Divider()
                        }
                    }
                }.frame(height: 220)
            }
            Text("Share is recorded processor energy, including while plugged in. Select an app for details.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func openDetails() {
        if tab == 1 { model.requestedHubTab = 1 }
        model.openDetails()
    }
}

struct Dashboard: View {
    @ObservedObject var model: AppModel
    @State private var forceTarget: ProcessReading?
    @State private var tab = 0
    @State private var contentReady = true
    @State private var readySelectionKey: String?
    @State private var moneyListDraft = MoneyListDraft()
    @State private var moneyOverviewDraft = MoneyOverviewDraft()
    @State private var providerListDraft = ProviderListDraft()
    @State private var providerDetailDraft = ProviderDetailDraft()
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.helperConnected && !model.paused { collectorBanner }
            if let status = model.statusMessage {
                HStack { Text(status).font(.caption); Spacer(); Button { model.statusMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(10).background(.teal.opacity(0.08))
            }
            HSplitView {
                ConsumerBrowser(model: model, tab: $tab, contentReady: $contentReady, moneyDraft: $moneyListDraft, providerDraft: $providerListDraft)
                ScrollView { details.padding(24).frame(maxWidth: .infinity, alignment: .leading) }.frame(minWidth: 360)
            }
            Divider()
            HStack {
                Circle().fill(model.paused ? .gray : model.helperConnected ? .teal : .orange).frame(width: 6, height: 6)
                Text(model.paused ? "Paused" : "\(model.sample?.processes.count ?? 0) processes · refresh \(Int(model.cadence))s").font(.caption)
                Spacer()
                if let time = model.sample?.timestamp { Text("Updated \(time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            }.padding(10)
        }
        .frame(minWidth: 1130, minHeight: 580)
        .onAppear { model.visibility("details", isVisible: true); model.refreshHistory() }
        .onDisappear { model.visibility("details", isVisible: false) }
        .task(id: tab) {
            guard tab != 0 || !contentReady else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            contentReady = true
        }
        .task(id: model.summaryKey) {
            let key = model.summaryKey
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, key == model.summaryKey else { return }
            readySelectionKey = key
        }
        .alert("YooTrack", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Force quit \(forceTarget?.name ?? "process")? Unsaved work can be lost.", isPresented: Binding(get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }), titleVisibility: .visible) {
            Button("Force Quit", role: .destructive) { if let target = forceTarget { model.control(target, force: true) }; forceTarget = nil }
            Button("Cancel", role: .cancel) { forceTarget = nil }
        }
    }
    private var header: some View {
        HStack(spacing: 18) {
            Image(systemName: "bolt.circle.fill").font(.system(size: 32)).foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("YooTrack").font(.title2.bold())
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { Text("v" + version).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Battery, usage, and money on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) { Text(model.menuLabel).font(.title3).monospacedDigit(); Text((model.sample?.battery?.dischargeWatts ?? 0) > 0 ? (model.sample?.battery?.onBattery == true ? "Battery discharge" : "Battery discharge · plugged in") : "Connected to power").font(.caption).foregroundStyle(.secondary) }
            VStack { Text("GPU " + Display.decimal(model.sample?.gpu?.utilizationPercent, suffix: "%")).monospacedDigit(); Button("Overview") { model.select(app: nil) }.font(.caption) }
            Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
            Button { model.openPreferences() } label: { Image(systemName: "gearshape") }.help("Settings")
        }.padding(18)
    }
    private var collectorBanner: some View {
        HStack {
            Image(systemName: "info.circle")
            Text("Add the administrator collector for Energy Impact, network rates, and hardware power.").font(.caption)
            Spacer(); Button(model.setupBusy ? "Installing…" : model.helperInstalled ? "Repair Collector" : "Install Collector") { model.installHelper() }.disabled(model.setupBusy)
        }.padding(12).background(.orange.opacity(0.09))
    }
    @ViewBuilder private var details: some View {
        if tab == 3 {
            if contentReady { MoneyOverview(model: model, draft: $moneyOverviewDraft) } else { loadingContent }
        } else if tab == 2 {
            if contentReady { ProviderDetail(model: model, draft: $providerDetailDraft) } else { loadingContent }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                if let process = model.process { processDetails(process) }
                else if let app = model.selectedApp { appDetails(app) }
                else if let row = model.history.rows.first(where: { $0.id == model.selected }) {
                    Text(row.name).font(.title.bold()); Text("Historical usage · no current process is selected").foregroundStyle(.secondary); historyChart(model.selectedHistory)
                } else { overview }
                if let issue = model.interval?.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                if let issues = model.sample?.issues, !issues.isEmpty { ForEach(issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } }
            }.background(SelectionRenderProbe(model: model, key: model.summaryKey).frame(width: 0, height: 0))
        }
    }
    private var loadingContent: some View {
        ProgressView("Loading…").frame(maxWidth: .infinity, minHeight: 120)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Live overview").font(.title.bold())
            Text("Select an app or expand it to inspect individual processes.").foregroundStyle(.secondary)
            HStack { Metric(title: "Battery discharge", value: Display.watts(model.sample?.battery?.dischargeWatts)); Metric(title: "CPU hardware", value: Display.watts(model.sample?.hardware?.cpuWatts)) }
            Metric(title: "GPU device utilization", value: Display.decimal(model.sample?.gpu?.utilizationPercent, suffix: "%"))
            HStack { Metric(title: "GPU · unassigned", value: Display.watts(model.sample?.hardware?.gpuWatts)); Metric(title: "Neural Engine · unassigned", value: Display.watts(model.sample?.hardware?.neuralWatts)) }
            if model.gpuUnavailable { Text("Process GPU readings need two readable samples. Processes without GPU counters display —.").font(.caption).foregroundStyle(.secondary) }
            if let interval = model.interval { Metric(title: "Hardware and unattributed", value: Display.watts(interval.remainderJoules.map { $0 / interval.seconds })) }
            historyChart(model.history)
            measurementNote
        }
    }
    private func appDetails(_ app: AppUsage) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Image(nsImage: model.icon(for: app)).resizable().frame(width: 48, height: 48); VStack(alignment: .leading) { Text(app.name).font(.title.bold()).accessibilityIdentifier("details.title"); Text("\(app.processes.count) live processes").foregroundStyle(.secondary) } }
            HStack { Metric(title: "Processor power" + (app.partial ? " · partial" : ""), value: Display.watts(app.processorWatts)); Metric(title: "Energy Impact", value: Display.decimal(app.energyImpact)) }
            HStack { Metric(title: "CPU", value: Display.decimal(app.cpuPercent, suffix: "%")); Metric(title: "Memory", value: app.knownMemoryBytes.map(Display.memory) ?? "—") }
            HStack { Metric(title: "GPU activity", value: Display.decimal(app.gpuMillisecondsPerSecond.map { $0 / 10 }, suffix: "%")); Metric(title: "Network ↓ / ↑", value: Display.rate(app.networkReceivedBytesPerSecond) + " / " + Display.rate(app.networkSentBytesPerSecond)) }
            if readySelectionKey != model.summaryKey { loadingContent }
            else if app.processes.count == 1, let single = app.processes.first {
                serviceDetails(single.reading)
                contextDetails(single)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("What is running").font(.headline); Spacer(); Button("Refresh context") { model.refreshSelectedContext() }.font(.caption) }
                    projectList(model.projectSnapshots(app.processes))
                    ForEach(roleCounts(app), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    Text("Expand the app to select a process and inspect its launch context.").font(.caption).foregroundStyle(.secondary)
                }
                let groupIDs = Set(app.processes.map { $0.id.pid })
                let externalParents = app.processes.compactMap { model.contexts[$0.id]?.parents }.flatMap { $0 }.filter { !groupIDs.contains($0.identity.pid) }
                processTree(roots: app.processes, parents: externalParents)
            }
            if readySelectionKey == model.summaryKey { localSummary }
            if let path = app.bundlePath { Text(path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
            if let target = ProcessControl.target(for: app) { controls(target) }
            if app.id == PowerWatchConstants.monitorGroup { Text("Includes this app, its administrator collector, and the powermetrics subprocess. Root-owned collector usage requires the helper connection.").font(.caption).foregroundStyle(.secondary) }
            if readySelectionKey == model.summaryKey { historyChart(model.selectedHistory); measurementNote }
        }
    }
    private func processDetails(_ process: ProcessUsage) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(process.reading.name).font(.title.bold()).accessibilityIdentifier("details.title")
            serviceDetails(process.reading)
            Text(ProcessDescriptions.description(name: process.reading.name, bundleName: process.bundlePath == nil ? nil : process.groupName)).foregroundStyle(.secondary)
            HStack { Metric(title: "Processor power", value: Display.watts(process.processorWatts)); Metric(title: "Energy Impact", value: Display.decimal(process.reading.energyImpact)) }
            HStack { Metric(title: "CPU", value: Display.decimal(process.cpuPercent, suffix: "%")); Metric(title: "Memory", value: process.reading.memoryBytes.map(Display.memory) ?? "—") }
            HStack { Metric(title: "GPU activity", value: Display.decimal(process.reading.gpuMillisecondsPerSecond.map { $0 / 10 }, suffix: "%")); Metric(title: "Network ↓ / ↑", value: Display.rate(process.reading.networkReceivedBytesPerSecond) + " / " + Display.rate(process.reading.networkSentBytesPerSecond)) }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow { Text("PID").foregroundStyle(.secondary); Text(String(process.id.pid)) }
                GridRow { Text("Started").foregroundStyle(.secondary); Text(Date(timeIntervalSince1970: Double(process.id.start) / 1e6).formatted(date: .abbreviated, time: .standard)) }
                GridRow { Text("Parent PID").foregroundStyle(.secondary); Text(String(process.reading.parentPID)) }
                GridRow { Text("Owner").foregroundStyle(.secondary); Text(owner(process.reading.uid)) }
                GridRow { Text("Executable").foregroundStyle(.secondary); Text(process.reading.path.isEmpty ? "Unavailable" : process.reading.path).textSelection(.enabled).lineLimit(nil) }
            }.font(.caption)
            if readySelectionKey == model.summaryKey { contextDetails(process); localSummary } else { loadingContent }
            if ProcessControl.allowed(process.reading) { controls(process.reading) } else { Text("Read-only system or monitoring process.").font(.caption).foregroundStyle(.secondary) }
            if readySelectionKey == model.summaryKey { historyChart(model.selectedHistory); measurementNote }
        }
    }
    @ViewBuilder private func serviceDetails(_ reading: ProcessReading) -> some View {
        if let guide = ServiceDescriptions.guide(for: reading) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What is this service?").font(.headline)
                Text(guide.purpose)
                Text(guide.scope).font(.callout).foregroundStyle(.secondary)
                Text("Runs from: " + reading.path).font(.caption).textSelection(.enabled)
                Text("Service account: " + owner(reading.uid) + " · observed parent PID: \(reading.parentPID)").font(.caption)
                Button("Show executable in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reading.path)]) }.font(.caption)
                Text(guide.investigate).font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func roleCounts(_ app: AppUsage) -> [String] {
        Dictionary(grouping: app.processes, by: { model.role(for: $0) }).map { "\($0.value.count) × \($0.key)" }.sorted()
    }
    @ViewBuilder private func contextDetails(_ process: ProcessUsage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Launch context").font(.headline); Spacer(); Button("Refresh context") { model.refreshSelectedContext() }.font(.caption) }
            Text(model.role(for: process)).font(.callout)
            if let context = model.contexts[process.id] {
                Text("Observed " + context.capturedAt.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                if let resp = context.responsible {
                    VStack(alignment: .leading, spacing: 2) {
                        Button { model.selectPID(resp.identity.pid) } label: {
                            Text("Kicked off by: \(resp.name) (PID \(resp.identity.pid))").font(.caption.bold()).foregroundStyle(.teal)
                        }.buttonStyle(.plain)
                        if let cmd = context.responsibleArguments, !cmd.isEmpty {
                            Text(cmd.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                projectList(model.projectSnapshots([process]))
                if let directory = context.workingDirectory { Text("Working directory: " + directory).font(.caption).textSelection(.enabled) }
                if let arguments = context.arguments { Text("Filtered arguments: " + arguments.joined(separator: " ")).font(.caption).textSelection(.enabled) }
                if !context.openPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active files & folders").font(.caption.bold())
                        ForEach(context.openPaths.prefix(6), id: \.self) { path in
                            Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                processTree(roots: [process], parents: context.parents)
                ForEach(context.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Inspecting launch metadata…").font(.caption).foregroundStyle(.secondary)
                processTree(roots: [process], parents: [])
            }
        }
    }
    @ViewBuilder private func projectList(_ snapshots: [ProjectSnapshot]) -> some View {
        if !snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshots.count == 1 ? "Project" : "Projects").font(.caption.bold())
                ForEach(snapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.name).font(.callout.bold())
                        Text(snapshot.root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(snapshot.direct).font(.caption)
                        if let launchedBy = snapshot.launchedBy { Text("Kicked off by \(launchedBy)").font(.caption).foregroundStyle(.secondary) }
                        Text(snapshot.subtree).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    @ViewBuilder private func processTree(roots: [ProcessUsage], parents: [ProcessReading]) -> some View {
        let nodes = model.descendants(of: roots)
        if !parents.isEmpty || !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Process tree").font(.caption.bold())
                if !parents.isEmpty {
                    let chain = parents.reversed().map { "\($0.name) (PID \($0.identity.pid))" }.joined(separator: " → ") + (roots.count == 1 ? " → \(roots[0].reading.name)" : "")
                    Text("Launcher chain: " + chain)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !nodes.isEmpty {
                    let totalWatts = (roots + nodes.map(\.process)).compactMap(\.processorWatts).reduce(0, +)
                    let totalCPU = (roots + nodes.map(\.process)).compactMap(\.cpuPercent).reduce(0, +)
                    Text("Head of \(nodes.count) child process(es) · Subtree \(Display.watts(totalWatts)) · \(Display.decimal(totalCPU, suffix: "%")) CPU")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(nodes.prefix(16)) { node in
                        Button { model.selectProcess(node.process) } label: {
                            HStack(spacing: 6) {
                                Text(String(repeating: "  ", count: max(0, node.depth - 1)) + "↳ " + node.process.reading.name).fontWeight(.medium).lineLimit(1)
                                Text("PID \(node.process.id.pid)").foregroundStyle(.secondary)
                                Spacer()
                                Text(Display.decimal(node.process.cpuPercent, suffix: "%") + " · " + (node.process.reading.memoryBytes.map(Display.memory) ?? "—") + " · " + Display.watts(node.process.processorWatts))
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }.font(.caption).padding(.vertical, 2)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private var localSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(model.summaryBusy == model.summaryKey ? "Summarizing on this Mac…" : model.selectedProcess == nil ? "Summarize app processes" : "Summarize this process") { model.summarizeSelection() }.disabled(model.summaryBusy != nil)
            if let summary = model.localSummaries[model.summaryKey] {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.source == .generated ? "AI process summary · generated on this Mac" : "Built-in process summary").font(.caption.bold()).foregroundStyle(.teal)
                    Text(summary.text).font(.callout).textSelection(.enabled)
                    if let notice = summary.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.teal.opacity(0.35)))
            }
            if let facts = model.summaryFacts[model.summaryKey] {
                DisclosureGroup("Raw process details") {
                    Text(facts).font(.caption).textSelection(.enabled).padding(.top, 4)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Text(LocalSummaries.unavailableReason ?? "Apple Intelligence summarizes each project, what started it, and its live usage on this Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func controls(_ target: ProcessReading) -> some View {
        HStack {
            Button(NSRunningApplication(processIdentifier: target.identity.pid)?.bundleURL != nil ? "Quit App" : "Stop Process") { model.control(target, force: false) }.buttonStyle(.bordered)
            Button("Force Quit…", role: .destructive) { forceTarget = target }.buttonStyle(.bordered)
        }
    }
    private func historyChart(_ summary: HistorySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Usage over time").font(.headline); Spacer(); Picker("Period", selection: $model.historyRange) { ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 140) }
            attributionStatus(summary, model: model)
            if model.historyRange == .custom { DatePicker("From", selection: $model.customStart); DatePicker("To", selection: $model.customEnd) }
            if model.historyLoading { Text("Loading history…").font(.caption).foregroundStyle(.secondary) }
            else if summary.points.isEmpty { ContentUnavailableView("No recorded activity", systemImage: "chart.xyaxis.line", description: Text("Keep monitoring to build a local history.")).frame(height: 160) }
            else {
                Chart(summary.points) { point in BarMark(x: .value("Time", point.timestamp), y: .value("Processor energy (Wh)", point.joules / 3600)).foregroundStyle(.teal) }
                    .chartYAxisLabel("Processor energy · Wh").frame(height: 180)
            }
            HStack { Metric(title: "Processor energy", value: Display.energy(summary.rows.reduce(0) { $0 + $1.joules })); Metric(title: "Observed battery loss", value: String(format: "%.2f percentage points", summary.batteryLossPoints)) }
            if model.selected != nil, let row = summary.rows.first {
                HStack { Metric(title: "Estimated share of drain", value: Display.decimal(row.shareOfDrain, suffix: "%")); Metric(title: "Estimated battery contribution", value: row.shareOfDrain == nil ? "—" : String(format: "%.2f percentage points", row.lossPoints)) }
            } else { Metric(title: "Hardware and unattributed energy", value: summary.validBatteryJoules > 0 ? Display.energy(summary.remainderJoules) : "—") }
            Text("Attribution available for \(Int((summary.attributionCoverage * 100).rounded()))% of monitored time. Shares use battery-only discharge intervals; charging, AC supplementation, and missing data are excluded. Range edges are approximate within stored buckets.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var measurementNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Understanding the numbers", systemImage: "info.circle").font(.caption.bold())
            Text("Processor watts are derived from macOS energy counters and do not include all app-related hardware work. Energy Impact is Apple's relative activity score, not watts. Battery contributions are estimates; graphics, hardware, and missed activity remain unattributed. GPU % is driver-reported execution time divided by elapsed time. Concurrent work can exceed 100%; app values need not sum to device utilization and are not GPU watts. Network shows receive/send bytes per second. GPU activity is read directly from the graphics driver; network and GPU watts require the collector. Group sums can be partial when a member is unavailable. — means unavailable; CPU can exceed 100% across cores.").font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func owner(_ uid: UInt32) -> String { getpwuid(uid).map { "\(String(cString: $0.pointee.pw_name)) (\(uid))" } ?? String(uid) }
}

private struct ConsumerBrowser: View {
    @ObservedObject var model: AppModel
    @Binding var tab: Int
    @Binding var contentReady: Bool
    @Binding var moneyDraft: MoneyListDraft
    @Binding var providerDraft: ProviderListDraft
    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: Binding(get: { tab }, set: { next in
                guard next != tab else { return }
                show(next)
            })) { Text("Live").tag(0); Text("History").tag(1); Text("AI Usage").tag(2); Text("Money").tag(3) }.pickerStyle(.segmented).padding(12).accessibilityIdentifier("dashboard.view")
            Group {
                if !contentReady { ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if tab == 0 { liveList }
                else if tab == 1 { historyList }
                else if tab == 2 { ProviderList(model: model, draft: $providerDraft) }
                else { MoneyList(model: model, draft: $moneyDraft) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 730, idealWidth: 760).background(TabRenderProbe(model: model, tab: tab).frame(width: 0, height: 0))
            .onAppear { applyRequested(model.requestedHubTab) }
            .onChange(of: model.requestedHubTab) { _, value in applyRequested(value) }
    }
    private func show(_ next: Int) {
        model.beginTabTransition(to: next)
        contentReady = false
        tab = next
        if next == 2, model.selectedProvider == nil { model.selectedProvider = model.providers.first?.id }
        if next == 3 { model.reloadMoney() }
        if model.hubShowsProviders != (next == 2) { model.hubShowsProviders = next == 2 }
        if model.hubShowsMoney != (next == 3) { model.hubShowsMoney = next == 3 }
    }
    private func applyRequested(_ value: Int?) {
        guard let value else { return }
        if tab != value { show(value) }
        else {
            if model.hubShowsProviders != (value == 2) { model.hubShowsProviders = value == 2 }
            if model.hubShowsMoney != (value == 3) { model.hubShowsMoney = value == 3 }
        }
        model.requestedHubTab = nil
    }
    private var liveList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search name, path, or PID", text: $model.query).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $model.sort) { ForEach(UsageSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 135)
            }.padding(.horizontal, 12).padding(.bottom, 10)
            HStack { SortColumn(model: model, column: .name, label: "App / process").frame(width: 112); Spacer(); UsageCells.header(model: model) }.font(.caption2).foregroundStyle(.secondary).padding(.leading, 36).padding(.trailing, 20).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sortedApps) { app in
                        LiveConsumerRow(model: model, app: app, revision: model.listRevision, expanded: model.expandedApps.contains(app.id), selected: model.selected == app.id, selectedProcess: model.selected == app.id ? model.selectedProcess : nil, sort: model.sort, descending: model.sortDescending).equatable()
                        Divider()
                    }
                }.padding(.horizontal, 12)
            }
            if model.sortedApps.isEmpty { Text(model.paused ? "Monitoring paused" : "No matching processes").foregroundStyle(.secondary).padding() }
        }
    }
    private var historyList: some View {
        let processorTotal = model.history.rows.reduce(0) { $0 + $1.joules }
        let liveIDs = Set(model.apps.map(\.id))
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Period", selection: $model.historyRange) { ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) } }.padding(.horizontal, 12)
            if model.historyRange == .custom {
                VStack { DatePicker("From", selection: $model.customStart); DatePicker("To", selection: $model.customEnd) }.font(.caption).padding(.horizontal, 12)
            }
            attributionStatus(model.history, model: model).padding(.horizontal, 12)
            HStack {
                Text("App / process").frame(width: 112, alignment: .leading); Spacer()
                Text("Avg power").frame(width: 88, alignment: .trailing)
                Text("Energy").frame(width: 88, alignment: .trailing)
                Text("Share").frame(width: 72, alignment: .trailing)
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.history.rows) { row in
                        HStack(spacing: 0) {
                            Button { model.toggleHistoryGroup(row.id) } label: {
                                Image(systemName: model.expandedHistory.contains(row.id) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 22, height: 36)
                            }.buttonStyle(.plain).accessibilityIdentifier("history.expand." + row.id)
                            Button { model.select(app: row.id) } label: { historyRow(row, shareOf: processorTotal, exited: !liveIDs.contains(row.id)) }
                                .buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("consumer.history." + row.id)
                        }
                        if model.expandedHistory.contains(row.id) {
                            if let members = model.historyMembers[row.id] {
                                if members.isEmpty { Text("Process energy appears after the next sample.").font(.caption).foregroundStyle(.secondary).padding(.leading, 36) }
                                ForEach(members) { member in
                                    historyRow(member, shareOf: row.joules, exited: false).padding(.leading, 28)
                                }
                            } else {
                                Text("Loading processes…").font(.caption).foregroundStyle(.secondary).padding(.leading, 36)
                            }
                        }
                        Divider()
                    }
                }.padding(.horizontal, 12)
            }
            Text("Average power and energy are processor totals, including time plugged in. Share is each row’s portion of that energy. Battery drain share stays separate and needs battery-only discharge.").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
            if model.history.rows.isEmpty { Text("History appears after active processes have been observed for a full interval.").font(.caption).foregroundStyle(.secondary).padding() }
            if let since = model.history.availableSince { Text("Stored since \(since.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary).padding(12) }
        }
    }
    private func historyRow(_ row: HistoryRow, shareOf total: Double, exited: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).lineLimit(1)
                if exited { Text("exited").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(Display.watts(row.averageWatts)).monospacedDigit().frame(width: 88, alignment: .trailing)
                .help("Average processor power over the time this process was observed, including while plugged in.")
            Text(Display.energy(row.joules)).monospacedDigit().frame(width: 88, alignment: .trailing)
            Text(Display.decimal(total > 0 ? row.joules / total * 100 : nil, suffix: "%")).monospacedDigit().frame(width: 72, alignment: .trailing)
        }.padding(.vertical, 8).padding(.horizontal, 4)
            .background(model.selected == row.id ? .teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

@MainActor @ViewBuilder private func attributionStatus(_ summary: HistorySummary, model: AppModel) -> some View {
    if !model.historyLoading && summary.validBatteryJoules <= 0 {
        VStack(alignment: .leading, spacing: 5) {
            Label("Battery drain share unavailable for this range", systemImage: "info.circle").font(.caption.bold())
            if summary.monitoredSeconds <= 0 {
                Text("No monitored intervals in this range yet.")
            } else if summary.batteryJoules > 0 {
                Text("Battery discharge was recorded, but no intervals had consistent battery-only measurements. Mixed adapter power, missing counters or conflicting readings prevent an estimate.")
            } else {
                Text("No usable battery discharge was recorded in this range. Charging and external power do not produce battery drain shares; unavailable battery readings can also prevent estimates.")
            }
            if model.sample?.battery?.onBattery == false {
                Text("Your Mac is currently connected to external power. For battery drain shares, monitor while unplugged and choose a range covering that time.")
            }
        }.font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Metric: View {
    let title: String
    let value: String
    var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.weight(.semibold)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10)) }
}

struct Preferences: View {
    @ObservedObject var model: AppModel
    @State private var confirmingClear = false
    @State private var confirmingRemove = false
    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text("Samples every 15 seconds in the background and 5 seconds while a view is open. Collection pauses during sleep.").font(.caption).foregroundStyle(.secondary)
                Button(model.paused ? "Resume monitoring" : "Pause monitoring") { model.togglePause() }
            }
            Section("Administrator collector") {
                Text(model.helperConnected ? "Connected · full collection" : "Not connected · basic collection")
                Button(model.setupBusy ? "Working…" : "Install or Repair Collector…") { model.installHelper() }.disabled(model.setupBusy)
                if model.helperInstalled { Button("Remove Collector…", role: .destructive) { confirmingRemove = true }.disabled(model.setupBusy) }
                Text("Setup requires administrator authorization. The helper only reads metrics; app termination runs under your account.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local history") {
                Text("Seven days, up to 250 MB. Recent history uses 15-second buckets, then one-minute and five-minute buckets. No data leaves this Mac.").font(.caption)
                Button("Clear History…", role: .destructive) { confirmingClear = true }
            }
            Section("AI usage") {
                Text("Cursor is read from the app session on this Mac. That login is shared with the agent CLI and does not use the keychain password prompt. In-house and 3rd party limits are shown separately.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.providers) { provider in
                    HStack { Text(provider.name); Spacer(); Text(provider.source).foregroundStyle(.secondary) }
                }
                Button("Open AI Usage") { model.focusProvider(nil) }
                Button(model.providerBusy ? "Refreshing…" : "Refresh now") { model.refreshProviders() }.disabled(model.providerBusy)
            }
            Section("Money") {
                Text("Spending and holdings stay in a private ledger on this Mac. Plaid credentials and access tokens stay in Keychain. The menu bar does not show dollar amounts.").font(.caption).foregroundStyle(.secondary)
                Button("Open Money") { model.requestedHubTab = 3; model.hubShowsMoney = true; model.hubShowsProviders = false; model.openDetails() }
            }
        }.formStyle(.grouped).frame(width: 480, height: 640)
            .onAppear { model.visibility("settings", isVisible: true) }.onDisappear { model.visibility("settings", isVisible: false) }
            .confirmationDialog("Delete all recorded history?", isPresented: $confirmingClear, titleVisibility: .visible) { Button("Clear History", role: .destructive) { model.clearHistory() } }
            .confirmationDialog("Remove the administrator collector? Basic monitoring will remain available.", isPresented: $confirmingRemove, titleVisibility: .visible) { Button("Remove Collector", role: .destructive) { model.installHelper(removing: true) } }
            .alert("YooTrack", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
}


/// Selection changes redraw only affected rows; the model itself is not observed by each row.
private struct LiveConsumerRow: View, Equatable {
    var model: AppModel
    var app: AppUsage
    var revision: Int
    var expanded: Bool
    var selected: Bool
    var selectedProcess: ProcessIdentity?
    var sort: UsageSort
    var descending: Bool
    static func == (a: Self, b: Self) -> Bool { a.app.id == b.app.id && a.revision == b.revision && a.expanded == b.expanded && a.selected == b.selected && a.selectedProcess == b.selectedProcess && a.sort == b.sort && a.descending == b.descending }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button { model.expand(app, isExpanded: !expanded) } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 22, height: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).help(expanded ? "Collapse processes" : "Expand processes").accessibilityLabel((expanded ? "Collapse " : "Expand ") + app.name).accessibilityIdentifier("consumer.expand." + app.id)
                Button { model.select(app: app.id) } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: model.icon(for: app)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) { Text(app.name).fontWeight(.medium).lineLimit(1); Text("\(app.processes.count) process\(app.processes.count == 1 ? "" : "es")").font(.caption2).foregroundStyle(.secondary) }
                        Spacer(minLength: 4); UsageCells(app: app)
                    }.padding(.vertical, 10).padding(.horizontal, 4).background(selected && selectedProcess == nil ? .teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("consumer.app." + app.id)
            }
            if expanded {
                ForEach(AppSorting.sortedProcesses(app.processes, by: sort, descending: descending)) { process in
                    Button { model.select(app: app.id, process: process.id) } label: {
                        HStack { VStack(alignment: .leading) { Text(process.reading.name).lineLimit(1); Text("PID \(process.id.pid) · " + model.role(for: process)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading); UsageCells(process: process) }
                            .padding(5).padding(.leading, 22).background(selectedProcess == process.id ? .teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(FullRowButtonStyle()).accessibilityIdentifier("consumer.process." + process.id.key)
                }
            }
        }
    }
}

/// Include transparent spacers and padding in the native button's hit region.
struct FullRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct SelectionRenderProbe: NSViewRepresentable {
    var model: AppModel
    var key: String
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) { DispatchQueue.main.async { model.selectionRendered(key: key) } }
}

private struct TabRenderProbe: NSViewRepresentable {
    var model: AppModel
    var tab: Int
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let updated = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { model.tabRendered(tab, viewUpdated: updated) }
    }
}
