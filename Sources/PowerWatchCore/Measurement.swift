import Foundation

public enum ProcessGrouping {
    public static func bundleRoot(for path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
    public static func resolve(_ processes: [ProcessReading], bundleResolver: ((String) -> String?)? = nil) -> [Int32: (key: String, name: String, bundle: String?)] {
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let rootForPath = bundleResolver ?? { bundleRoot(for: $0) }
        var groups: [Int32: (key: String, name: String, bundle: String?)] = [:]
        for p in processes {
            if ["PowerWatch", "PowerWatchHelper", "ai.powerwatch.collector"].contains(p.name) || p.path.hasSuffix("/YooTrack.app/Contents/MacOS/PowerWatch") || p.path.hasSuffix("/Power Watch.app/Contents/MacOS/PowerWatch") {
                groups[p.identity.pid] = (PowerWatchConstants.monitorGroup, "YooTrack", rootForPath(p.path))
            } else if let root = rootForPath(p.path) {
                groups[p.identity.pid] = ("app:" + root, URL(fileURLWithPath: root).deletingPathExtension().lastPathComponent, root)
            }
        }
        for p in processes where groups[p.identity.pid] == nil {
            var ancestor = p; var visited: Set<Int32> = [p.identity.pid]
            while let parent = byPID[ancestor.parentPID], parent.uid == p.uid, parent.identity.start <= ancestor.identity.start, visited.insert(parent.identity.pid).inserted {
                if let owner = groups[parent.identity.pid] { groups[p.identity.pid] = owner; break }
                ancestor = parent
            }
            // powermetrics runs as root under the monitor's helper, so allow that exact relationship.
            if p.name == "powermetrics", let parent = byPID[p.parentPID], ["PowerWatchHelper", "ai.powerwatch.collector"].contains(parent.name), parent.identity.start <= p.identity.start {
                groups[p.identity.pid] = (PowerWatchConstants.monitorGroup, "YooTrack", nil)
            }
            if groups[p.identity.pid] == nil {
                let key = p.path.isEmpty ? "instance:" + p.identity.key : "process:\(p.uid):\(p.path)"
                groups[p.identity.pid] = (key, p.name, nil)
            }
        }
        return groups
    }
}

public final class MeasurementEngine {
    private var previous: MachineSample?
    private var bundleRoots: [String: String?] = [:]
    public init() {}
    public func reset() { previous = nil; bundleRoots.removeAll() }
    public func ingest(_ sample: MachineSample, expectedInterval: Double) -> UsageInterval {
        let old = previous; previous = sample
        let dt = old.map { sample.uptime - $0.uptime } ?? 0
        let validTime = dt > 0 && dt <= expectedInterval * 2.5 && old.map { abs(sample.timestamp.timeIntervalSince($0.timestamp) - dt) < 3 } == true
        let previousProcesses = Dictionary((old?.processes ?? []).map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let grouping = ProcessGrouping.resolve(sample.processes) { [self] path in
            if let cached = bundleRoots[path] { return cached }
            if bundleRoots.count >= 4096 { bundleRoots.removeAll() }
            let root = ProcessGrouping.bundleRoot(for: path)
            bundleRoots[path] = .some(root)
            return root
        }
        let usage = sample.processes.map { current -> ProcessUsage in
            let baseline = previousProcesses[current.identity]
            let cpu = validTime ? Self.delta(current.cpuNanoseconds, baseline?.cpuNanoseconds).map { $0 / 1e9 / dt * 100 } : nil
            let joules = validTime ? Self.delta(current.energyNanojoules, baseline?.energyNanojoules).map { $0 / 1e9 } : nil
            let group = grouping[current.identity.pid]!
            return ProcessUsage(reading: current, cpuPercent: cpu, processorWatts: joules.map { $0 / dt }, joules: joules, groupKey: group.key, groupName: group.name, bundlePath: group.bundle)
        }
        var batteryJoules: Double?; var loss: Double?; var issue: String?; var batteryOnly = false
        if validTime, let a = old?.battery, let b = sample.battery, a.onBattery == b.onBattery, !a.charging, !b.charging,
           let wa = a.dischargeWatts, let wb = b.dischargeWatts, wa >= 0, wb >= 0, wa.isFinite, wb.isFinite {
            batteryJoules = (wa + wb) / 2 * dt
            batteryOnly = a.onBattery && b.onBattery
            if !batteryOnly { issue = "Battery is discharging while plugged in. App battery shares are unavailable because energy also comes from the adapter." }
            let drop = a.measurementPercentage - b.measurementPercentage
            if drop >= 0 { loss = drop }
            else { issue = "Battery gauge increased; attribution is unavailable for this interval." }
        }
        let total = usage.compactMap(\.joules).reduce(0, +)
        var validAttribution = batteryOnly && batteryJoules.map { $0 > 0 && total <= $0 && usage.contains { $0.joules != nil } } == true && loss != nil
        if let batteryJoules, total > batteryJoules {
            issue = "Processor counters exceed battery discharge; attribution is unavailable."
            validAttribution = false
        }
        if !validTime { issue = old == nil ? "Collecting the first measurement interval." : "Sampling gap; measurement baselines restarted." }
        return UsageInterval(start: validTime ? old!.timestamp : sample.timestamp, end: sample.timestamp, seconds: validTime ? dt : 0,
                             processes: usage, batteryJoules: batteryJoules, batteryLossPoints: loss, attributionValid: validAttribution, issue: issue)
    }
    public static func delta(_ current: UInt64?, _ previous: UInt64?) -> Double? {
        guard let current, let previous, current >= previous else { return nil }; return Double(current - previous)
    }
}

public enum ProcessDescriptions {
    public static func description(name: String, bundleName: String?) -> String {
        switch name {
        case "WindowServer": return "Draws windows and composites the desktop. Its work can come from multiple apps."
        case "kernel_task": return "The macOS kernel and system work. Its activity cannot reliably be assigned to one app."
        case "mds", "mds_stores", "mdworker", "mdworker_shared": return "Spotlight indexing and search metadata."
        case "bird", "cloudd": return "iCloud synchronization and related background work."
        case "backupd": return "Time Machine backup service."
        case "powerd": return "macOS power management service."
        case "powermetrics": return "Apple's power metrics collector. When launched by YooTrack, its usage is included with the monitor."
        case "PowerWatch", "PowerWatchHelper", "ai.powerwatch.collector": return "YooTrack monitoring and measurement collection. This usage is included in the monitor's total."
        default:
            if let bundleName { return "A process belonging to \(bundleName). macOS metadata identifies its owner; its specific task is not available." }
            return "A local executable. Its name, path, owner, and parent are shown below; no verified description is available."
        }
    }
}


public struct ServiceGuide: Sendable {
    public var purpose: String
    public var scope: String
    public var investigate: String
}

public enum ServiceDescriptions {
    public static func guide(for reading: ProcessReading) -> ServiceGuide? {
        guard reading.path.hasPrefix("/System/") || reading.path.hasPrefix("/usr/libexec/") || reading.path == "/sbin/launchd" else { return nil }
        switch reading.name {
        case "WindowServer": return ServiceGuide(purpose: "macOS's shared display service. It combines app windows into the desktop image, manages windows, and routes interface events.", scope: "Runs on this Mac as a macOS service, launched by launchd. Many apps send their windows to it, so its CPU/GPU usage belongs to shared desktop work and cannot be reliably charged to one app.", investigate: "Compare its activity as you close windows or pause video and animations. The executable location, service account and observed parent PID below identify this running instance.")
        case "powerd": return ServiceGuide(purpose: "Manages sleep, wake and power behavior for macOS.", scope: "A shared macOS service; apps can request that the Mac stay awake.", investigate: "Its usage can reflect system power management. The executable and owner identify the running instance.")
        case "mds", "mds_stores", "mdworker", "mdworker_shared": return ServiceGuide(purpose: "Builds and searches the Spotlight index of files and metadata.", scope: "Shared system indexing rather than a single document or app.", investigate: "Indexing may accompany file changes. This app does not identify the exact file being indexed.")
        case "bird", "cloudd": return ServiceGuide(purpose: "Coordinates iCloud data synchronization.", scope: "Shared synchronization used by multiple apps.", investigate: "Check ongoing file or app synchronization; the counters alone do not identify a particular upload.")
        case "coreaudiod": return ServiceGuide(purpose: "Provides shared audio playback and recording services.", scope: "Multiple apps can use this macOS audio service.", investigate: "Compare activity while stopping playback or recording in individual apps.")
        case "launchd": return ServiceGuide(purpose: "Starts and supervises macOS services and background jobs.", scope: "A system or user service manager, depending on this instance's owner.", investigate: "An observed parent PID of 1 indicates the system launchd. Current ancestry does not prove which app originally requested a service.")
        case "com.apple.Virtualization.VirtualMachine": return ServiceGuide(purpose: "Runs a Linux or macOS virtual machine through Apple's Virtualization.framework.", scope: "Spawned as an XPC service by launchd on behalf of a VM host tool (such as Colima, Lima, Docker Desktop, OrbStack, or UTM).", investigate: "Check 'Kicked off by' and 'Active files & folders' below to see the exact VM host process, disk image, and mounted workspace folders.")
        default: return nil
        }
    }
}
