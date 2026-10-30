import AppKit
import Darwin
public enum ProcessControl {
    public static func allowed(_ reading: ProcessReading) -> Bool {
        reading.uid == getuid() && reading.identity.pid > 1 && reading.identity.pid != getpid()
        && !["loginwindow", "WindowServer", "launchd", "PowerWatchHelper", "ai.powerwatch.collector", "powermetrics"].contains(reading.name)
        && !reading.path.hasPrefix("/System/") && !reading.path.hasPrefix("/usr/libexec/")
    }
    public static func execute(_ reading: ProcessReading, force: Bool) throws {
        guard allowed(reading) else { throw failure("This process is read-only. Use Quit YooTrack to stop the monitor.") }
        guard let current = NativeSampler.readProcess(pid: reading.identity.pid), current.identity == reading.identity, current.uid == getuid(), current.path == reading.path else {
            throw failure("The process exited or changed since the last sample. Refresh before trying again.")
        }
        if let app = NSRunningApplication(processIdentifier: reading.identity.pid), app.bundleURL != nil, app.activationPolicy != .prohibited {
            let accepted = force ? app.forceTerminate() : app.terminate()
            guard accepted else { throw failure("\(reading.name) declined to quit or has already exited.") }
        } else {
            guard kill(reading.identity.pid, force ? SIGKILL : SIGTERM) == 0 else { throw failure("Could not stop \(reading.name): \(String(cString: strerror(errno))).") }
        }
    }
    public static func target(for app: AppUsage) -> ProcessReading? {
        if app.id == PowerWatchConstants.monitorGroup { return nil }
        let candidates = app.processes.map(\.reading).filter(allowed)
        return candidates.first { NSRunningApplication(processIdentifier: $0.identity.pid)?.activationPolicy == .regular }
        ?? candidates.first { NSRunningApplication(processIdentifier: $0.identity.pid)?.activationPolicy == .accessory }
        ?? (app.bundlePath == nil ? candidates.first : nil)
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "PowerWatch.ProcessControl", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
