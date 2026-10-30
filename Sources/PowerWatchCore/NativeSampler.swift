import Foundation
import Darwin
import IOKit
import IOKit.ps

public final class NativeSampler {
    private var pathCache: [ProcessIdentity: String] = [:]
    private var nameCache: [ProcessIdentity: String] = [:]
    private let gpu = GPUSampler()
    public init() {}
    public func resetGPU() { gpu.reset() }
    public func sample(hardware: HardwareReading? = nil, interval: Double = 15) -> MachineSample {
        let timestamp = Date()
        var issues: [String] = []
        let count = proc_listallpids(nil, 0)
        var pids = [Int32](repeating: 0, count: max(64, Int(count) + 128))
        let bytes = Int32(pids.count * MemoryLayout<Int32>.stride)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        if actual <= 0 { issues.append("Process enumeration failed: \(String(cString: strerror(errno))).") }
        let freshHardware = hardware.flatMap {
            let age = timestamp.timeIntervalSince($0.timestamp)
            return age >= -3 && age <= interval * 2.5 ? $0 : nil
        }
        if let hardware, freshHardware == nil { issues.append("Power collector sample is \(Int(timestamp.timeIntervalSince(hardware.timestamp))) seconds old; Energy Impact, hardware power and network readings are unavailable until a fresh sample arrives.") }
        var readings: [ProcessReading] = []
        var cache: [ProcessIdentity: String] = [:]
        var names: [ProcessIdentity: String] = [:]
        for pid in pids.prefix(max(0, min(Int(actual), pids.count))) where pid > 0 {
            guard var reading = Self.readProcess(pid: pid, cachedPaths: pathCache, cachedNames: nameCache) else { continue }
            Self.applyHardware(freshHardware, to: &reading)
            readings.append(reading); cache[reading.identity] = reading.path
            if !reading.path.isEmpty { names[reading.identity] = reading.name }
        }
        pathCache = cache
        nameCache = names
        if readings.allSatisfy({ $0.energyNanojoules == nil }) { issues.append("Process energy counters are unavailable; watts cannot be calculated.") }
        let uptime = ProcessInfo.processInfo.systemUptime
        let (gpuReading, gpuRates) = gpu.sample(processes: readings, uptime: uptime)
        for index in readings.indices {
            if let rate = gpuRates[readings[index].identity] { readings[index].gpuMillisecondsPerSecond = rate }
        }
        return MachineSample(timestamp: timestamp, uptime: uptime, processes: readings, battery: Self.readBattery(), hardware: freshHardware, gpu: gpuReading, issues: issues)
    }
    public static func applyHardware(_ hardware: HardwareReading?, to reading: inout ProcessReading) {
        // A PID can be reused after the collector sample. Do not attach the previous instance's rates.
        guard let hardware, Double(reading.identity.start) / 1e6 <= hardware.timestamp.timeIntervalSince1970 else { return }
        let pid = reading.identity.pid
        reading.energyImpact = hardware.impactByPID[pid]
        reading.gpuMillisecondsPerSecond = hardware.gpuMillisecondsByPID?[pid]
        reading.networkReceivedBytesPerSecond = hardware.networkReceivedByPID?[pid]
        reading.networkSentBytesPerSecond = hardware.networkSentByPID?[pid]
    }
    public static func identity(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, start: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
    }
    public static func readProcess(pid: Int32, cachedPaths: [ProcessIdentity: String] = [:], cachedNames: [ProcessIdentity: String] = [:], impact: Double? = nil) -> ProcessReading? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { proc_pid_rusage(pid, RUSAGE_INFO_V6, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        let identity = ProcessIdentity(pid: pid, start: start)
        let path: String
        if let cached = cachedPaths[identity] { path = cached }
        else {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            path = count > 0 ? String(cString: buffer) : ""
        }
        let name = cachedNames[identity] ?? (path.isEmpty ? withUnsafePointer(to: &info.pbi_comm) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } } : URL(fileURLWithPath: path).lastPathComponent)
        // Verify the process has not been replaced between the BSD and resource calls.
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              after.pbi_start_tvsec == info.pbi_start_tvsec, after.pbi_start_tvusec == info.pbi_start_tvusec else { return nil }
        return ProcessReading(identity: identity, parentPID: Int32(info.pbi_ppid), uid: info.pbi_uid, name: name, path: path,
                              cpuNanoseconds: result == 0 ? Self.nanoseconds(fromMachTicks: usage.ri_user_time + usage.ri_system_time) : nil,
                              energyNanojoules: result == 0 && energySupported ? usage.ri_energy_nj : nil,
                              memoryBytes: result == 0 ? usage.ri_phys_footprint : nil, energyImpact: impact)
    }
    public static func nanoseconds(fromMachTicks ticks: UInt64) -> UInt64 {
        let value = Double(ticks) * timebase
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
    public static let energySupported: Bool = {
        var supported: Int32 = 0; var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.pervasive_energy", &supported, &size, nil, 0) == 0 { return supported != 0 }
        // The capability sysctl is restricted on some macOS releases; a nonzero self counter is direct evidence.
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self)) }
        return result == 0 && usage.ri_energy_nj > 0
    }()
    public static func readBattery() -> BatteryReading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Double,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Double, maxCapacity > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let percentage = min(100, max(0, current / maxCapacity * 100))
            var rawPercentage: Double?
            var watts: Double?
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func number(_ key: String) -> NSNumber? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber }
                if let raw = number("AppleRawCurrentCapacity"), let full = number("AppleRawMaxCapacity"), full.doubleValue > 0 {
                    rawPercentage = min(100, max(0, raw.doubleValue / full.doubleValue * 100))
                }
                if let voltage = number("Voltage"), let current = number("InstantAmperage") ?? number("Amperage") {
                    watts = dischargeWatts(voltageMillivolts: voltage.doubleValue, amperageRaw: current.uint64Value, onBattery: onBattery, charging: charging)
                }
            }
            return BatteryReading(percentage: percentage, onBattery: onBattery, charging: charging, dischargeWatts: watts, rawPercentage: rawPercentage)
        }
        return nil
    }
    public static func dischargeWatts(voltageMillivolts: Double, amperageRaw: UInt64, onBattery: Bool, charging: Bool) -> Double? {
        let amps = Double(Int64(bitPattern: amperageRaw)) / 1000
        let value = -amps * voltageMillivolts / 1000
        guard !charging, value.isFinite, value >= 0, value < 1000, onBattery || value > 0 else { return nil }
        return value
    }
}
