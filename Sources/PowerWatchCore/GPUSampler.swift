import Foundation
import IOKit

/// Driver-defined, read-only IOAccelerator statistics. No private framework or subprocess.
public struct GPUReading: Codable, Sendable {
    public var utilizationPercent: Double?
    public var reportingDevices: Int
    public var measuredProcesses: Int
}

public struct GPUClientCounter: Sendable {
    public var registryID: UInt64
    public var process: ProcessIdentity
    public var layout: [String]
    public var nanoseconds: [UInt64]
    public init(registryID: UInt64, process: ProcessIdentity, layout: [String], nanoseconds: [UInt64]) {
        self.registryID = registryID; self.process = process; self.layout = layout; self.nanoseconds = nanoseconds
    }
}

/// Baselines are per driver client AND process instance. New clients never import lifetime work.
public final class GPUDeltaTracker {
    private var previous: [UInt64: GPUClientCounter] = [:]
    private var lastUptime: Double?
    public init() {}
    public func reset() { previous = [:]; lastUptime = nil }
    public func ingest(_ counters: [GPUClientCounter], uptime: Double) -> [ProcessIdentity: Double] {
        defer {
            previous = Dictionary(counters.map { ($0.registryID, $0) }, uniquingKeysWith: { first, _ in first })
            lastUptime = uptime
        }
        guard let lastUptime, uptime > lastUptime, uptime - lastUptime <= 30 else { return [:] }
        let seconds = uptime - lastUptime
        var result: [ProcessIdentity: Double] = [:]
        var seen = Set<UInt64>()
        for current in counters where seen.insert(current.registryID).inserted {
            guard let old = previous[current.registryID], old.process == current.process,
                  !current.nanoseconds.isEmpty, old.layout == current.layout,
                  old.nanoseconds.count == current.nanoseconds.count,
                  zip(current.nanoseconds, old.nanoseconds).allSatisfy({ $0 >= $1 }) else { continue }
            let delta = zip(current.nanoseconds, old.nanoseconds).reduce(0.0) { $0 + Double($1.0 - $1.1) }
            result[current.process, default: 0] += delta / 1e6 / seconds
        }
        return result
    }
}

public final class GPUSampler {
    private let deltas = GPUDeltaTracker()
    public init() {}
    public func reset() { deltas.reset() }
    public func sample(processes: [ProcessReading], uptime: Double) -> (GPUReading, [ProcessIdentity: Double]) {
        let identities = Dictionary(processes.map { ($0.identity.pid, $0.identity) }, uniquingKeysWith: { first, _ in first })
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            _ = deltas.ingest([], uptime: uptime)
            return (GPUReading(utilizationPercent: nil, reportingDevices: 0, measuredProcesses: 0), [:])
        }
        defer { IOObjectRelease(accelerators) }
        var counters: [GPUClientCounter] = []
        var percentages: [Double] = []
        var deviceCount = 0
        var seen = Set<UInt64>()
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            deviceCount += 1
            if let stats = Self.property(accelerator, "PerformanceStatistics") as? [String: Any],
               let percentage = Self.utilization(stats) { percentages.append(percentage) }
            var children: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(client, &id) == KERN_SUCCESS, seen.insert(id).inserted,
                      let creator = Self.property(client, "IOUserClientCreator") as? String,
                      let pid = Self.creatorPID(creator), let identity = identities[pid] else { continue }
                // Check the instance again after the registry read: a reused PID must not inherit GPU work.
                let direct = Self.property(client, "accumulatedGPUTime")
                let usage = direct == nil ? Self.property(client, "AppUsage") : nil
                guard let parsed = Self.counter(direct: direct, usage: usage),
                      NativeSampler.identity(pid: pid) == identity else { continue }
                counters.append(GPUClientCounter(registryID: id, process: identity, layout: parsed.0, nanoseconds: parsed.1))
            }
        }
        let rates = deltas.ingest(counters, uptime: uptime)
        // On multi-GPU machines report the busiest device, not a sum of overlapping percentages.
        let utilization = deviceCount > 0 && percentages.count == deviceCount ? percentages.max() : nil
        return (GPUReading(utilizationPercent: utilization, reportingDevices: deviceCount, measuredProcesses: rates.count), rates)
    }
    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    public static func creatorPID(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid "), let first = creator.dropFirst(4).split(separator: ",", maxSplits: 1).first,
              let pid = Int32(first.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
        return pid
    }
    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        if let exact = UInt64(number.stringValue) { return exact }
        guard number.doubleValue < Double(UInt64.max) else { return nil }
        return UInt64(number.doubleValue)
    }
    public static func counter(direct: Any?, usage: Any?) -> ([String], [UInt64])? {
        // Direct total takes precedence; adding AppUsage as well would count the same work twice.
        if let direct { return unsigned(direct).map { (["direct"], [$0]) } }
        guard let rows = usage as? [[String: Any]], !rows.isEmpty else { return nil }
        var layout: [String] = [], values: [UInt64] = []
        for row in rows {
            guard let value = unsigned(row["accumulatedGPUTime"]) else { return nil }
            layout.append(row["API"] as? String ?? "unknown"); values.append(value)
        }
        return (layout, values)
    }
    public static func utilization(_ stats: [String: Any]) -> Double? {
        guard let number = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              (0...100).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }
}
