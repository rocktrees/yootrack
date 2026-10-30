import Foundation
import Darwin

public enum PowerMetricsError: Error { case malformed, oversized }

/// powermetrics writes a sequence of NUL-separated property lists, not a single document.
public struct PowerMetricsDecoder {
    private var pending = Data()
    private var searchedBytes = 0
    public init() {}
    public mutating func append(_ data: Data) throws -> [HardwareReading] {
        pending.append(data)
        guard pending.count < 16 * 1024 * 1024 else { pending.removeAll(); searchedBytes = 0; throw PowerMetricsError.oversized }
        var readings: [HardwareReading] = []
        // Pipes deliver a large plist in many chunks. Scan only newly received bytes,
        // using libc's byte search rather than repeatedly walking the whole buffer.
        while let offset = pending.withUnsafeBytes({ bytes -> Int? in
            guard searchedBytes < bytes.count, let base = bytes.baseAddress,
                  let delimiter = memchr(base.advanced(by: searchedBytes), 0, bytes.count - searchedBytes) else { return nil }
            return base.distance(to: UnsafeRawPointer(delimiter))
        }) {
            let end = pending.startIndex + offset
            let frame = pending[..<end]; pending.removeSubrange(...end)
            searchedBytes = 0
            if !frame.isEmpty { readings.append(try Self.decode(Data(frame))) }
        }
        searchedBytes = pending.count
        return readings
    }
    public static func decode(_ data: Data) throws -> HardwareReading {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw PowerMetricsError.malformed }
        func numeric(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }; return value.doubleValue
        }
        let processor = root["processor"] as? [String: Any] ?? [:]
        let gpu = root["gpu"] as? [String: Any] ?? [:]
        let ane = root["ane"] as? [String: Any] ?? [:]
        let timestamp = root["timestamp"] as? Date ?? Date()
        let duration = numeric(root["elapsed_ns"]).map { $0 / 1e9 }
        func watts(_ dictionary: [String: Any], power: [String], energy: [String]) -> Double? {
            guard dictionary["invalid"] as? Bool != true else { return nil }
            for key in power { if let mw = numeric(dictionary[key]) { return mw / 1000 } }
            if let duration, duration > 0 {
                for key in energy { if let mj = numeric(dictionary[key]) { return mj / 1000 / duration } }
            }
            return nil
        }
        var impacts: [Int32: Double] = [:]
        var gpuTimes: [Int32: Double] = [:], received: [Int32: Double] = [:], sent: [Int32: Double] = [:]
        func rate(_ task: [String: Any], direct: String, total: String, divisor: Double = 1) -> Double? {
            if let value = numeric(task[direct]) { return value }
            guard let duration, duration > 0, let value = numeric(task[total]) else { return nil }
            return value / divisor / duration
        }
        // Coalition mode nests process rows. Read those rows, never the coalition's own aggregate.
        let coalitions = root["coalitions"] as? [[String: Any]] ?? []
        let nested = coalitions.flatMap { $0["tasks"] as? [[String: Any]] ?? [] }
        let processes = nested + (root["tasks"] as? [[String: Any]] ?? root["processes"] as? [[String: Any]] ?? [])
        for task in processes where task["invalid"] as? Bool != true {
            guard let pid = task["pid"] as? NSNumber, pid.int32Value > 0 else { continue }
            let id = pid.int32Value
            if let impact = numeric(task["energy_impact_per_s"] ?? task["energy_impact"]) { impacts[id] = impact }
            if let value = rate(task, direct: "gputime_ms_per_s", total: "gputime_ns", divisor: 1e6) { gpuTimes[id] = value }
            if let value = rate(task, direct: "bytes_received_per_s", total: "bytes_received") { received[id] = value }
            if let value = rate(task, direct: "bytes_sent_per_s", total: "bytes_sent") { sent[id] = value }
        }
        return HardwareReading(timestamp: timestamp,
                               cpuWatts: watts(processor, power: ["cpu_power"], energy: ["cpu_energy"]),
                               gpuWatts: watts(processor, power: ["gpu_power"], energy: ["gpu_energy"]) ?? watts(gpu, power: ["gpu_power"], energy: ["gpu_energy"]),
                               neuralWatts: watts(processor, power: ["ane_power"], energy: ["ane_energy"]) ?? watts(ane, power: ["ane_power"], energy: ["ane_energy"]), impactByPID: impacts, gpuMillisecondsByPID: gpuTimes, networkReceivedByPID: received, networkSentByPID: sent)
    }
}

public final class PowerMetricsRunner {
    private var process: Process?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var decoder = PowerMetricsDecoder()
    private let lock = NSLock()
    private var reading: HardwareReading?
    private var failure: String?
    private var interval: Double = 0
    public init() {}
    public var latest: HardwareReading? { lock.lock(); defer { lock.unlock() }; return reading }
    public var issue: String? { lock.lock(); defer { lock.unlock() }; return failure }
    public func start(interval: Double) {
        guard self.interval != interval || process?.isRunning != true else { return }
        stop(); self.interval = interval
        let child = Process(); let stdout = Pipe(); let stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // Ownership comes from our libproc/bundle grouping. Coalition reporting adds
        // redundant aggregation and a much larger plist without improving attribution.
        child.arguments = ["--samplers", "tasks,cpu_power,gpu_power,ane_power,battery,network", "--show-process-energy", "--handle-invalid-values", "--format", "plist", "--sample-rate", String(Int(interval * 1000)), "--buffer-size", "1"]
        child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData; guard !data.isEmpty, let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            do { if let latest = try self.decoder.append(data).last { self.reading = latest; self.failure = nil } }
            catch { self.failure = "Power metrics returned an unreadable sample." }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData; guard !data.isEmpty, let self else { return }
            self.lock.lock(); self.failure = String(data: data.prefix(1000), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines); self.lock.unlock()
        }
        do { try child.run(); process = child; output = stdout; errorOutput = stderr }
        catch { lock.lock(); failure = "Could not start Apple's power collector: \(error.localizedDescription)"; lock.unlock() }
    }
    public func stop() {
        // Keep draining the pipes while the tool exits, including a partially written large process sample.
        if process?.isRunning == true { process?.terminate(); process?.waitUntilExit() }
        output?.fileHandleForReading.readabilityHandler = nil; errorOutput?.fileHandleForReading.readabilityHandler = nil
        try? output?.fileHandleForReading.close(); try? errorOutput?.fileHandleForReading.close()
        process = nil; output = nil; errorOutput = nil; interval = 0
        lock.lock(); reading = nil; decoder = PowerMetricsDecoder(); lock.unlock()
    }
    deinit { stop() }
}
