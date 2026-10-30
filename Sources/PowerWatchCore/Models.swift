import Foundation

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public var pid: Int32
    public var start: UInt64
    public var key: String { "\(pid):\(start)" }
    public init(pid: Int32, start: UInt64) { self.pid = pid; self.start = start }
}

public struct ProcessReading: Codable, Sendable {
    public var identity: ProcessIdentity
    public var parentPID: Int32
    public var uid: UInt32
    public var name: String
    public var path: String
    public var cpuNanoseconds: UInt64?
    public var energyNanojoules: UInt64?
    public var memoryBytes: UInt64?
    public var energyImpact: Double?
    public var gpuMillisecondsPerSecond: Double?
    public var networkReceivedBytesPerSecond: Double?
    public var networkSentBytesPerSecond: Double?
    public init(identity: ProcessIdentity, parentPID: Int32 = 0, uid: UInt32 = 0, name: String = "Process", path: String = "", cpuNanoseconds: UInt64? = nil, energyNanojoules: UInt64? = nil, memoryBytes: UInt64? = nil, energyImpact: Double? = nil, gpuMillisecondsPerSecond: Double? = nil, networkReceivedBytesPerSecond: Double? = nil, networkSentBytesPerSecond: Double? = nil) {
        self.identity = identity; self.parentPID = parentPID; self.uid = uid; self.name = name; self.path = path
        self.cpuNanoseconds = cpuNanoseconds; self.energyNanojoules = energyNanojoules
        self.memoryBytes = memoryBytes; self.energyImpact = energyImpact
        self.gpuMillisecondsPerSecond = gpuMillisecondsPerSecond
        self.networkReceivedBytesPerSecond = networkReceivedBytesPerSecond; self.networkSentBytesPerSecond = networkSentBytesPerSecond
    }
}

public struct BatteryReading: Codable, Sendable {
    /// The macOS charge level for display; raw capacity is only used for drain calculations.
    public var percentage: Double
    public var rawPercentage: Double?
    public var measurementPercentage: Double { rawPercentage ?? percentage }
    public var onBattery: Bool
    public var charging: Bool
    public var dischargeWatts: Double?
    public init(percentage: Double, onBattery: Bool, charging: Bool, dischargeWatts: Double?, rawPercentage: Double? = nil) {
        self.percentage = percentage; self.onBattery = onBattery; self.charging = charging; self.dischargeWatts = dischargeWatts; self.rawPercentage = rawPercentage
    }
}

public struct HardwareReading: Codable, Sendable {
    public var timestamp: Date
    public var cpuWatts: Double?
    public var gpuWatts: Double?
    public var neuralWatts: Double?
    public var impactByPID: [Int32: Double]
    public var gpuMillisecondsByPID: [Int32: Double]?
    public var networkReceivedByPID: [Int32: Double]?
    public var networkSentByPID: [Int32: Double]?
    public init(timestamp: Date = Date(), cpuWatts: Double? = nil, gpuWatts: Double? = nil, neuralWatts: Double? = nil, impactByPID: [Int32: Double] = [:], gpuMillisecondsByPID: [Int32: Double]? = nil, networkReceivedByPID: [Int32: Double]? = nil, networkSentByPID: [Int32: Double]? = nil) {
        self.timestamp = timestamp; self.cpuWatts = cpuWatts; self.gpuWatts = gpuWatts; self.neuralWatts = neuralWatts; self.impactByPID = impactByPID
        self.gpuMillisecondsByPID = gpuMillisecondsByPID; self.networkReceivedByPID = networkReceivedByPID; self.networkSentByPID = networkSentByPID
    }
}

public struct MachineSample: Codable, Sendable {
    public var timestamp: Date
    public var uptime: Double
    public var processes: [ProcessReading]
    public var battery: BatteryReading?
    public var hardware: HardwareReading?
    public var gpu: GPUReading?
    public var issues: [String]
    public init(timestamp: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime, processes: [ProcessReading], battery: BatteryReading? = nil, hardware: HardwareReading? = nil, gpu: GPUReading? = nil, issues: [String] = []) {
        self.timestamp = timestamp; self.uptime = uptime; self.processes = processes; self.battery = battery; self.hardware = hardware; self.gpu = gpu; self.issues = issues
    }
}

public struct ProcessUsage: Identifiable, Sendable {
    public var reading: ProcessReading
    public var id: ProcessIdentity { reading.identity }
    public var cpuPercent: Double?
    public var processorWatts: Double?
    public var joules: Double?
    public var groupKey: String
    public var groupName: String
    public var bundlePath: String?
    public init(reading: ProcessReading, cpuPercent: Double?, processorWatts: Double?, joules: Double?, groupKey: String, groupName: String, bundlePath: String?) {
        self.reading = reading; self.cpuPercent = cpuPercent; self.processorWatts = processorWatts; self.joules = joules
        self.groupKey = groupKey; self.groupName = groupName; self.bundlePath = bundlePath
    }
}

public struct UsageInterval: Sendable {
    public var start: Date
    public var end: Date
    public var seconds: Double
    public var processes: [ProcessUsage]
    public var batteryJoules: Double?
    public var batteryLossPoints: Double?
    public var attributionValid: Bool
    public var issue: String?
    public var processorJoules: Double { processes.compactMap(\.joules).reduce(0, +) }
    public var remainderJoules: Double? { attributionValid ? batteryJoules.map { max(0, $0 - processorJoules) } : nil }
}

public struct AppUsage: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    public var processes: [ProcessUsage] { didSet { totals = Totals(processes) } }
    private var totals: Totals
    private struct Totals: Sendable {
        var watts: Double?, cpu: Double?, impact: Double?, gpu: Double?, received: Double?, sent: Double?
        var memory: UInt64; var hasMemory: Bool; var partial: Bool
        init(_ processes: [ProcessUsage]) {
            watts = sumKnown(processes.map(\.processorWatts)); cpu = sumKnown(processes.map(\.cpuPercent))
            impact = sumKnown(processes.map { $0.reading.energyImpact }); gpu = sumKnown(processes.map { $0.reading.gpuMillisecondsPerSecond })
            received = sumKnown(processes.map { $0.reading.networkReceivedBytesPerSecond }); sent = sumKnown(processes.map { $0.reading.networkSentBytesPerSecond })
            memory = processes.compactMap { $0.reading.memoryBytes }.reduce(0, +)
            hasMemory = processes.contains { $0.reading.memoryBytes != nil }; partial = processes.contains { $0.processorWatts == nil }
        }
    }
    public init(id: String, name: String, bundlePath: String?, processes: [ProcessUsage]) {
        self.id = id; self.name = name; self.bundlePath = bundlePath; self.processes = processes; totals = Totals(processes)
    }
    public var processorWatts: Double? { totals.watts }
    public var cpuPercent: Double? { totals.cpu }
    public var energyImpact: Double? { totals.impact }
    public var gpuMillisecondsPerSecond: Double? { totals.gpu }
    public var networkReceivedBytesPerSecond: Double? { totals.received }
    public var networkSentBytesPerSecond: Double? { totals.sent }
    public var knownMemoryBytes: UInt64? { totals.hasMemory ? totals.memory : nil }
    public var memoryBytes: UInt64 { totals.memory }
    public var partial: Bool { totals.partial }
    public static func grouped(_ processes: [ProcessUsage]) -> [AppUsage] {
        Dictionary(grouping: processes, by: \.groupKey).map { key, members in
            AppUsage(id: key, name: members[0].groupName, bundlePath: members.compactMap(\.bundlePath).first, processes: members.sorted { ($0.processorWatts ?? -1) > ($1.processorWatts ?? -1) })
        }.sorted { ($0.processorWatts ?? -1) > ($1.processorWatts ?? -1) }
    }
}

private func sumKnown(_ values: [Double?]) -> Double? {
    let known = values.compactMap { $0 }; return known.isEmpty ? nil : known.reduce(0, +)
}

public enum PowerWatchConstants {
    public static let service = "ai.powerwatch.collector"
    public static let appIdentifier = "ai.powerwatch.app"
    public static let installedHelper = "/Library/PrivilegedHelperTools/ai.powerwatch.collector"
    public static let configuration = "/Library/PrivilegedHelperTools/ai.powerwatch.collector.plist"
    public static let monitorGroup = "ai.powerwatch.monitor"
}
