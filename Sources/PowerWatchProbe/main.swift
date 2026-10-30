import Foundation
import Darwin
import AppKit
import Security
import Metal
import PowerWatchCore

let sampler = NativeSampler()
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let cancel: Bool
    init(cancel: Bool) { self.cancel = cancel }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { cancel ? .terminateCancel : .terminateNow }
}
final class ProbeSession: NSObject, CollectorProtocol {
    var stopped = false
    func sample(interval: Double, reply: @escaping (Data?, String?) -> Void) { reply(Data("authenticated".utf8), nil) }
    func stop(reply: @escaping () -> Void) { stopped = true; reply() }
}
final class ProbeListener: NSObject, NSXPCListenerDelegate {
    let session = ProbeSession()
    var connections: [NSXPCConnection] = []
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: CollectorProtocol.self); connection.exportedObject = session
        connections.append(connection); connection.resume(); return true
    }
}
if CommandLine.arguments.contains("--fixture-app") {
    let app = NSApplication.shared; let delegate = FixtureDelegate(cancel: CommandLine.arguments.contains("--cancel-quit"))
    app.delegate = delegate; app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
} else if CommandLine.arguments.contains("--xpc-check") {
    let path = NativeSampler.readProcess(pid: getpid())!.path
    var code: SecStaticCode?; SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
    var info: CFDictionary?; SecCodeCopySigningInformation(code!, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let identifier = (info! as NSDictionary)[kSecCodeInfoIdentifier] as! String
    let ownRule = try CollectorSecurity.requirement(for: URL(fileURLWithPath: path), identifier: identifier)
    for authorized in [true, false] {
        let listener = NSXPCListener.anonymous(); let delegate = ProbeListener(); listener.delegate = delegate
        listener.setConnectionCodeSigningRequirement(authorized ? ownRule : "identifier \"ai.powerwatch.untrusted\"")
        listener.resume()
        let client = NSXPCConnection(listenerEndpoint: listener.endpoint); client.remoteObjectInterface = NSXPCInterface(with: CollectorProtocol.self); client.resume()
        let received = DispatchSemaphore(value: 0); var accepted = false
        let proxy = client.remoteObjectProxyWithErrorHandler { _ in received.signal() } as? CollectorProtocol
        proxy?.sample(interval: 5) { data, _ in accepted = data == Data("authenticated".utf8); received.signal() }
        _ = received.wait(timeout: .now() + 5)
        guard accepted == authorized else { print("XPC authorization mismatch: expected \(authorized), accepted \(accepted)"); exit(1) }
        if authorized {
            let stopped = DispatchSemaphore(value: 0); proxy?.stop { stopped.signal() }; _ = stopped.wait(timeout: .now() + 2)
            guard delegate.session.stopped else { print("Collector stop was not delivered"); exit(1) }
        }
        client.invalidate(); listener.invalidate(); delegate.connections.forEach { $0.invalidate() }
        print(authorized ? "Pinned client authenticated; collection stop delivered" : "Different signing identity rejected by XPC")
    }
} else if CommandLine.arguments.contains("--quit-check") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PowerWatch-QuitCheck-" + UUID().uuidString)
    let app = directory.appendingPathComponent("Disposable Quit Test.app")
    let contents = app.appendingPathComponent("Contents"), binary = contents.appendingPathComponent("MacOS/PowerWatchQuitTest")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]), to: binary)
    let info: [String: Any] = ["CFBundleIdentifier": "ai.powerwatch.fixture", "CFBundleName": "Disposable Quit Test", "CFBundleExecutable": "PowerWatchQuitTest", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    defer { try? FileManager.default.removeItem(at: directory) }
    for cancel in [false, true] {
        let child = Process(); child.executableURL = binary; child.arguments = ["--fixture-app"] + (cancel ? ["--cancel-quit"] : []); try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && NSRunningApplication(processIdentifier: child.processIdentifier)?.isFinishedLaunching != true { Thread.sleep(forTimeInterval: 0.05) }
        guard let reading = NativeSampler.readProcess(pid: child.processIdentifier), NSRunningApplication(processIdentifier: child.processIdentifier)?.bundleURL != nil else { print("Fixture app did not register"); exit(1) }
        do { try ProcessControl.execute(reading, force: false) }
        catch { if cancel { print("Quit declined: \(error.localizedDescription)") } else if child.isRunning { throw error } }
        Thread.sleep(forTimeInterval: 0.5)
        if cancel {
            guard child.isRunning else { print("Cancelled quit unexpectedly exited"); exit(1) }
            print("App cancelled normal quit; process remained alive")
            try ProcessControl.execute(reading, force: true)
        }
        let end = Date().addingTimeInterval(3)
        while child.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        guard !child.isRunning else { print("App did not quit"); exit(1) }
        print(cancel ? "Force quit terminated disposable app" : "Normal quit terminated disposable app")
    }
} else if CommandLine.arguments.contains("--metrics") {
    let runner = PowerMetricsRunner(); runner.start(interval: 5)
    Thread.sleep(forTimeInterval: 6)
    print(String(data: try JSONEncoder().encode(sampler.sample(hardware: runner.latest, interval: 5)), encoding: .utf8)!)
    if let issue = runner.issue { fputs(issue + "\n", stderr) }; runner.stop()
 } else if CommandLine.arguments.contains("--gpu-check") {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void gpuWork(device float* output [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        float value = float(id % 127) / 127.0f;
        for (uint i = 0; i < 4096; ++i) { value = sin(value) * 0.999f + 0.01f; }
        output[id] = value;
    }
    """
    let library = try device.makeLibrary(source: source, options: nil)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "gpuWork")!)
    let count = 65536
    let buffer = device.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModeShared)!
    func dispatch() -> Double {
        let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { fatalError("Metal command failed") }
        return command.gpuEndTime - command.gpuStartTime
    }
    _ = dispatch() // Materialize the client's AppUsage counter before establishing its baseline.
    _ = sampler.sample(interval: 5)
    let begin = ProcessInfo.processInfo.systemUptime
    var metalSeconds = 0.0
    while ProcessInfo.processInfo.systemUptime - begin < 5 { metalSeconds += dispatch() }
    let loaded = sampler.sample(interval: 5)
    let own = loaded.processes.first { $0.identity.pid == getpid() }?.gpuMillisecondsPerSecond
    let duration = ProcessInfo.processInfo.systemUptime - begin
    print("GPU workload: PID \(getpid()), device \(loaded.gpu?.utilizationPercent ?? -1)%, process \((own ?? -1) / 10)%, Metal active seconds \(metalSeconds), elapsed \(duration)s")
    guard let own, own > 0, abs(own * duration / 1000 - metalSeconds) < max(0.25, metalSeconds * 0.2) else { fatalError("GPU counter does not match Metal timing") }
    Thread.sleep(forTimeInterval: 5)
    let idle = sampler.sample(interval: 5)
    let idleRate = idle.processes.first { $0.identity.pid == getpid() }?.gpuMillisecondsPerSecond
    print("GPU idle: process \((idleRate ?? -1) / 10)%")
    guard let idleRate, idleRate < own * 0.1 else { fatalError("GPU counter did not return to idle") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let artifact = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/gpu-live-validation.json")
    try encoder.encode([loaded, idle]).write(to: artifact)
} else if CommandLine.arguments.contains("--load-check") {
    let engine = MeasurementEngine(); _ = engine.ingest(sampler.sample(), expectedInterval: 5)
    var total = 0.0
    let start = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - start < 2 { for i in 1...10000 { total += sqrt(Double(i)) } }
    let result = engine.ingest(sampler.sample(), expectedInterval: 5)
    let mine = result.processes.first { $0.id.pid == getpid() }
    print("Controlled CPU workload: \(String(format: "%.1f", mine?.cpuPercent ?? -1))% CPU; \(String(format: "%.3f", mine?.processorWatts ?? -1)) processor W; \(String(format: "%.3f", mine?.joules ?? -1)) J; checksum \(total)")
    if (mine?.cpuPercent ?? 0) < 25 || (mine?.joules ?? 0) <= 0 { exit(1) }
} else if CommandLine.arguments.contains("--helper-check") || CommandLine.arguments.contains("--unauthorized-check") {
    // This probe is intentionally signed with a different identity than the app.
    let connection = NSXPCConnection(machServiceName: PowerWatchConstants.service, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: CollectorProtocol.self)
    connection.resume()
    let semaphore = DispatchSemaphore(value: 0)
    var accepted = false
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in print("Rejected: \(error.localizedDescription)"); semaphore.signal() } as? CollectorProtocol
    proxy?.sample(interval: 5) { data, error in accepted = data != nil; print("Accepted=\(accepted) error=\(error ?? "none")"); semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 6); connection.invalidate()
    exit(accepted ? 1 : 0)
} else {
    let sample = sampler.sample()
    print("Processes: \(sample.processes.count); accessible counters: \(sample.processes.filter { $0.energyNanojoules != nil }.count); energy supported: \(NativeSampler.energySupported)")
    if let battery = sample.battery { print("Battery: \(String(format: "%.1f", battery.percentage))%; on battery: \(battery.onBattery); charging: \(battery.charging); discharge watts: \(battery.dischargeWatts.map(String.init(describing:)) ?? "unavailable")") }
    for reading in sample.processes.prefix(5) { print("\(reading.name) PID=\(reading.identity.pid) path=\(reading.path)") }
    for issue in sample.issues { print(issue) }
}
