import Foundation
import Darwin
import Security
#if SWIFT_PACKAGE
import PowerWatchCore
#endif

final class CollectorSession: NSObject, CollectorProtocol {
    private let queue = DispatchQueue(label: "ai.powerwatch.helper.collection", qos: .utility)
    private let sampler = NativeSampler()
    private let metrics = PowerMetricsRunner()
    private var watchdog: DispatchSourceTimer?
    func sample(interval: Double, reply: @escaping (Data?, String?) -> Void) {
        queue.async { [self] in
            let cadence = interval <= 5 ? 5.0 : 15.0
            metrics.start(interval: cadence)
            watchdog?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + cadence * 3)
            timer.setEventHandler { [weak self] in self?.metrics.stop(); self?.sampler.resetGPU() }
            timer.resume(); watchdog = timer
            var sample = sampler.sample(hardware: metrics.latest, interval: cadence)
            if let issue = metrics.issue { sample.issues.append(issue) }
            do { reply(try JSONEncoder().encode(sample), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }
    func stop(reply: @escaping () -> Void) { queue.async { [self] in watchdog?.cancel(); watchdog = nil; metrics.stop(); sampler.resetGPU(); reply() } }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let configuredUID: UInt32
    private var active: NSXPCConnection?
    private let lock = NSLock()
    init(uid: UInt32) { configuredUID = uid }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard CollectorSecurity.accepts(uid: connection.effectiveUserIdentifier, configuredUID: configuredUID, activeClient: active != nil) else { return false }
        let session = CollectorSession()
        connection.exportedInterface = NSXPCInterface(with: CollectorProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self, weak connection] in
            session.stop {}
            self?.lock.lock(); if self?.active === connection { self?.active = nil }; self?.lock.unlock()
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        active = connection; connection.resume(); return true
    }
}

do {
    guard geteuid() == 0 else { throw NSError(domain: "PowerWatch.Helper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install the collector using the local administrator installer."]) }
    let configurationURL = URL(fileURLWithPath: PowerWatchConstants.configuration)
    let attrs = try FileManager.default.attributesOfItem(atPath: configurationURL.path)
    guard (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0, ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o022 == 0 else { throw NSError(domain: "PowerWatch.Helper", code: 2) }
    let data = try Data(contentsOf: configurationURL)
    guard let config = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let requirement = config["ClientRequirement"] as? String, let uid = config["ClientUID"] as? NSNumber else { throw NSError(domain: "PowerWatch.Helper", code: 3) }
    var compiled: SecRequirement?
    guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess else { throw NSError(domain: "PowerWatch.Helper", code: 4) }
    let delegate = ListenerDelegate(uid: uid.uint32Value)
    let listener = NSXPCListener(machServiceName: PowerWatchConstants.service)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = delegate; listener.resume()
    RunLoop.current.run()
} catch {
    FileHandle.standardError.write(Data("YooTrack collector: \(error.localizedDescription)\n".utf8)); exit(1)
}
