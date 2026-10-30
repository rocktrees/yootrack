import Foundation
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

/// Explicit UI-test launches use synthetic data, isolated storage and no collector.
@MainActor enum UITestFixtures {
    static func makeModel() -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PowerWatchUITests-" + UUID().uuidString)
        let model = AppModel(monitoringEnabled: false, historyURL: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        var usages: [ProcessUsage] = []
        for app in 0..<250 {
            for child in 0..<4 {
                let reading = ProcessReading(identity: ProcessIdentity(pid: Int32(1_000_000 + app * 4 + child), start: 1), uid: 0,
                    name: String(format: "Fixture process %03d-%d", app, child), path: "/fixture/app-\(app)/process-\(child)",
                    cpuNanoseconds: 1_000, energyNanojoules: 1_000, memoryBytes: UInt64(app + 1) * 1_048_576,
                    gpuMillisecondsPerSecond: Double(app), networkReceivedBytesPerSecond: Double(app) * 1024, networkSentBytesPerSecond: Double(app) * 256)
                usages.append(ProcessUsage(reading: reading, cpuPercent: Double(250 - app) / 100, processorWatts: Double(250 - app) / 1000,
                    joules: Double(250 - app), groupKey: String(format: "fixture-app-%03d", app),
                    groupName: String(format: "Fixture App %03d", app), bundlePath: nil))
            }
        }
        model.sample = MachineSample(timestamp: now, uptime: 100, processes: usages.map(\.reading),
            battery: BatteryReading(percentage: 80, onBattery: true, charging: false, dischargeWatts: 12))
        model.apps = AppUsage.grouped(usages)
        model.helperConnected = true
        let rows = model.apps.map { app in
            HistoryRow(id: app.id, name: app.name, bundlePath: nil, joules: app.processes.compactMap(\.joules).reduce(0, +),
                attributedJoules: 1, lossPoints: 0.01, observedSeconds: 60, shareOfDrain: 1)
        }
        model.history = HistorySummary(rows: rows,
            points: (0..<60).map { HistoryPoint(timestamp: now.addingTimeInterval(Double($0 - 60) * 15), joules: 2, seconds: 15) },
            batteryJoules: 100, batteryLossPoints: 1, validBatteryJoules: 100, monitoredSeconds: 60, attributionSeconds: 60, availableSince: now.addingTimeInterval(-3600))
        model.selectedHistory = model.history
        model.menuBudgetRows = [
            BudgetRow(category: "Dining", spentCents: 3200, limitCents: 10000),
            BudgetRow(category: "Groceries", spentCents: 12000, limitCents: 10000),
            BudgetRow(category: "Other", spentCents: 1000, limitCents: 0)
        ]
        model.providers = [
            ProviderStatus(id: "cursor", name: "Cursor", plan: "Pro", source: "Fixture", windows: [QuotaWindow(id: "inhouse", label: "In-house", used: 64, limit: 100, unit: "%", resetAt: now.addingTimeInterval(3600)), QuotaWindow(id: "thirdparty", label: "3rd party", used: 100, limit: 100, unit: "%", resetAt: now.addingTimeInterval(3600))], tokens: [], monthCostUSD: nil, budgetUSD: nil, updatedAt: now, error: nil),
            ProviderStatus(id: "anthropic", name: "Anthropic", plan: nil, source: "Fixture", windows: [QuotaWindow(id: "five_hour", label: "5-hour session", used: 25, limit: 100, unit: "%", resetAt: now.addingTimeInterval(7200))], tokens: [], monthCostUSD: nil, budgetUSD: nil, updatedAt: now, error: nil),
            ProviderStatus(id: "openai", name: "OpenAI", plan: nil, source: "Fixture", windows: [QuotaWindow(id: "five_hour", label: "5-hour session", used: 63, limit: 100, unit: "%", resetAt: now.addingTimeInterval(3600)), QuotaWindow(id: "seven_day", label: "7-day", used: 10, limit: 100, unit: "%", resetAt: now.addingTimeInterval(86400))], tokens: [], monthCostUSD: nil, budgetUSD: nil, updatedAt: now, error: nil)
        ]
        return model
    }
}
