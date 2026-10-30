import Foundation
import Darwin
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

final class SamplingService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.powerwatch.app.sampling", qos: .utility)
    private let native = NativeSampler()
    private let engine = MeasurementEngine()
    private var connection: NSXPCConnection?
    private var generation = 0
    private var stopped = false
    private var helperIssue: String?
    func fetch(interval: Double, completion: @escaping (MachineSample, UsageInterval, [AppUsage], Bool) -> Void) {
        queue.async { [self] in
            func deliver(_ sample: MachineSample, _ connected: Bool) {
                let usage = engine.ingest(sample, expectedInterval: max(15, interval))
                completion(sample, usage, AppUsage.grouped(usage.processes), connected)
            }
            stopped = false
            if connection == nil { connect() }
            guard let connection else {
                var sample = native.sample(interval: interval)
                sample.issues.append(helperIssue ?? "Administrator collector is not installed. Processor counters remain available; Energy Impact and hardware metrics need the collector.")
                deliver(sample, false); return
            }
            generation += 1; let request = generation
            func fallback(_ message: String) {
                guard request == self.generation, !self.stopped else { return }
                self.generation += 1
                var sample = self.native.sample(interval: interval); sample.issues.append(message)
                self.connection?.invalidate(); self.connection = nil
                deliver(sample, false)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in self.queue.async { fallback("Collector connection failed: \(error.localizedDescription)") } } as? CollectorProtocol
            proxy?.sample(interval: interval) { data, error in
                self.queue.async {
                    guard request == self.generation, !self.stopped else { return }
                    guard let data, let sample = try? JSONDecoder().decode(MachineSample.self, from: data) else { fallback(error ?? "Collector returned an invalid sample."); return }
                    self.generation += 1; deliver(sample, true)
                }
            }
            queue.asyncAfter(deadline: .now() + 4) { fallback("Collector did not respond. Monitoring with local process counters.") }
        }
    }
    private func connect() {
        let path = PowerWatchConstants.installedHelper
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0, ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else {
                helperIssue = "Collector installation has unsafe ownership or permissions."; return
            }
            let requirement = try CollectorSecurity.requirement(for: URL(fileURLWithPath: path), identifier: PowerWatchConstants.service)
            let client = NSXPCConnection(machServiceName: PowerWatchConstants.service, options: .privileged)
            client.setCodeSigningRequirement(requirement)
            client.remoteObjectInterface = NSXPCInterface(with: CollectorProtocol.self)
            client.invalidationHandler = { [weak self, weak client] in
                self?.queue.async { [weak self] in if self?.connection === client { self?.connection = nil } }
            }
            client.resume(); connection = client; helperIssue = nil
        } catch { helperIssue = "Collector signature verification failed: \(error.localizedDescription)" }
    }
    func stop() {
        queue.async { [self] in
            stopped = true; generation += 1; native.resetGPU(); engine.reset()
            if let proxy = connection?.remoteObjectProxy as? CollectorProtocol { proxy.stop {} }
            connection?.invalidate(); connection = nil
        }
    }
}
