import Foundation

public enum UsageSort: String, CaseIterable { case watts = "Processor power", impact = "Energy Impact", cpu = "CPU", memory = "Memory", gpu = "GPU activity", network = "Network", name = "Name" }

public enum SearchFilter {
    public static func matches(_ query: String, fields: [String?]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || fields.compactMap { $0 }.contains { $0.localizedStandardContains(needle) }
    }

    public static func matches(_ query: String, app: AppUsage) -> Bool {
        if matches(query, fields: [app.name, app.bundlePath]) { return true }
        return app.processes.contains { process in
            matches(query, fields: [process.reading.name, process.reading.path, String(process.id.pid)])
        }
    }
}

public enum HistoryRanking: String, CaseIterable, Identifiable {
    case battery = "Battery", impact = "Energy Impact", processor = "Processor"
    public var id: String { rawValue }

    public func ranked(_ rows: [HistoryRow], matching query: String = "") -> [RankedHistoryRow] {
        func value(_ row: HistoryRow) -> Double? {
            switch self {
            case .battery: return row.shareOfDrain == nil ? nil : row.lossPoints
            case .impact: return row.averageImpact
            case .processor: return row.energyAvailable ? row.joules : nil
            }
        }
        let sorted = rows.sorted { a, b in
            let left = value(a), right = value(b)
            if left != right { return (left ?? -1) > (right ?? -1) }
            let name = a.name.localizedStandardCompare(b.name)
            return name == .orderedSame ? a.id < b.id : name == .orderedAscending
        }
        return sorted.enumerated().compactMap { index, row in
            SearchFilter.matches(query, fields: [row.name, row.bundlePath, row.id]) ? RankedHistoryRow(rank: index + 1, row: row) : nil
        }
    }
}

public struct RankedHistoryRow: Identifiable {
    public var id: String { row.id }
    public let rank: Int
    public let row: HistoryRow
}

public enum AppSorting {
    public static func sortedProcesses(_ processes: [ProcessUsage], by column: UsageSort, descending: Bool) -> [ProcessUsage] {
        sorted(processes.map { AppUsage(id: $0.id.key, name: $0.reading.name, bundlePath: nil, processes: [$0]) }, by: column, descending: descending).flatMap(\.processes)
    }
    public static func sorted(_ apps: [AppUsage], by column: UsageSort, descending: Bool) -> [AppUsage] {
        func compare<T: Comparable>(_ a: T?, _ b: T?) -> Int {
            switch (a, b) {
            case (nil, nil): return 0
            case (nil, _): return 1
            case (_, nil): return -1
            case let (a?, b?): return a == b ? 0 : (descending ? a > b : a < b) ? -1 : 1
            }
        }
        func network(_ app: AppUsage) -> Double? {
            guard app.networkReceivedBytesPerSecond != nil || app.networkSentBytesPerSecond != nil else { return nil }
            return (app.networkReceivedBytesPerSecond ?? 0) + (app.networkSentBytesPerSecond ?? 0)
        }
        return apps.sorted { a, b in
            let order: Int
            switch column {
            case .name:
                let comparison = a.name.localizedStandardCompare(b.name)
                order = comparison == .orderedSame ? 0 : (descending ? comparison == .orderedDescending : comparison == .orderedAscending) ? -1 : 1
            case .watts: order = compare(a.processorWatts, b.processorWatts)
            case .impact: order = compare(a.energyImpact, b.energyImpact)
            case .cpu: order = compare(a.cpuPercent, b.cpuPercent)
            case .memory: order = compare(a.knownMemoryBytes, b.knownMemoryBytes)
            case .gpu: order = compare(a.gpuMillisecondsPerSecond, b.gpuMillisecondsPerSecond)
            case .network: order = compare(network(a), network(b))
            }
            if order != 0 { return order < 0 }
            let name = a.name.localizedStandardCompare(b.name)
            return name == .orderedSame ? a.id < b.id : name == .orderedAscending
        }
    }
}
