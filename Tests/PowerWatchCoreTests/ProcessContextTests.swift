import XCTest
import Darwin
@testable import PowerWatchCore

final class ProcessContextTests: XCTestCase {
    func testSensitiveFlagsAndOptionValuesAreRedacted() {
        let filtered = ProcessInspector.filteredArguments(["curl", "-H", "api-key-value", "-e", "PASSWORD=value", "--config", "sk-sensitive-value", "--port", "8080"])
        XCTAssertFalse(filtered.contains("api-key-value"))
        XCTAssertFalse(filtered.contains("PASSWORD=value"))
        XCTAssertFalse(filtered.contains("sk-sensitive-value"))
        XCTAssertTrue(filtered.contains("8080"))
    }

    func testArgumentDecoderStopsBeforeEnvironmentAndRejectsTruncation() throws {
        let arguments = ["/bin/example", "--type=renderer", ""]
        var argc = Int32(arguments.count)
        var data = withUnsafeBytes(of: &argc) { Data($0) }
        data.append(Data("/bin/example\0\0".utf8))
        for argument in arguments { data.append(Data(argument.utf8)); data.append(0) }
        data.append(Data("PRIVATE_SECRET=never read\0".utf8))
        XCTAssertEqual(ProcessInspector.decodeArguments(data), arguments)
        XCTAssertNil(ProcessInspector.decodeArguments(Data(data.prefix(12))))
        XCTAssertFalse(ProcessInspector.filteredArguments(try XCTUnwrap(ProcessInspector.decodeArguments(data))).joined().contains("PRIVATE_SECRET"))
    }
    func testBrowserRolesAndScriptIdentityUseEvidence() {
        XCTAssertEqual(ProcessInspector.role(name: "Google Chrome Helper", path: "/Applications/Google Chrome.app/helper", arguments: ["chrome", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]), "Browser network service")
        XCTAssertEqual(ProcessInspector.role(name: "Google Chrome Helper", path: "", arguments: ["chrome", "--type", "gpu-process"]), "Browser graphics / GPU process")
        XCTAssertTrue(ProcessInspector.role(name: "chrome", path: "", arguments: ["chrome", "--type=renderer"]).contains("tab/frame identity unavailable"))
        XCTAssertEqual(ProcessInspector.role(name: "python3", path: "/usr/bin/python3", arguments: ["python3", "-m", "http.server"]), "Python module · http.server")
        XCTAssertEqual(ProcessInspector.role(name: "node", path: "/usr/local/bin/node", arguments: ["node", "/project/server.js"]), "Script · server.js")
        XCTAssertEqual(ProcessInspector.role(name: "mystery", path: "/local/mystery"), "Executable · mystery")
    }
    func testCommandFilteringDoesNotRetainSecretsOrInlineSource() {
        let filtered = ProcessInspector.filteredArguments(["python3", "worker.py", "serve", "/Users/me/project", "--port", "8080", "--token", "secret.py", "--password=hunter2", "https://example.test/?token=secret", "-c", "print('secret')", "--type=renderer"])
        XCTAssertTrue(filtered.contains("worker.py")); XCTAssertTrue(filtered.contains("--type=renderer"))
        XCTAssertTrue(filtered.contains("serve")); XCTAssertTrue(filtered.contains("/Users/me/project")); XCTAssertTrue(filtered.contains("8080"))
        XCTAssertFalse(filtered.joined().contains("secret")); XCTAssertFalse(filtered.joined().contains("hunter2"))
        XCTAssertEqual(ProcessInspector.role(name: "python3", path: "", arguments: ["python3", "-c", "secret.py"]), "Interpreter · python3")
    }
    func testDescendantsAndUsageDigestBuildProcessTreeAndRejectPIDReuse() {
        let root = ProcessUsage(reading: ProcessReading(identity: ProcessIdentity(pid: 100, start: 10), parentPID: 1, name: "zsh", path: "/bin/zsh", memoryBytes: 10_000_000), cpuPercent: 2, processorWatts: 0.2, joules: 1, groupKey: "app:term", groupName: "Terminal", bundlePath: "/Applications/Utilities/Terminal.app")
        let child = ProcessUsage(reading: ProcessReading(identity: ProcessIdentity(pid: 101, start: 20), parentPID: 100, name: "node", path: "/opt/homebrew/bin/node", memoryBytes: 50_000_000), cpuPercent: 25, processorWatts: 1.5, joules: 5, groupKey: "app:term", groupName: "Terminal", bundlePath: nil)
        let grand = ProcessUsage(reading: ProcessReading(identity: ProcessIdentity(pid: 102, start: 30), parentPID: 101, name: "esbuild", path: "/project/node_modules/esbuild", memoryBytes: 30_000_000), cpuPercent: 80, processorWatts: 3.0, joules: 10, groupKey: "app:term", groupName: "Terminal", bundlePath: nil)
        let reusedStaleChild = ProcessUsage(reading: ProcessReading(identity: ProcessIdentity(pid: 103, start: 5), parentPID: 100, name: "old", path: "/bin/old"), cpuPercent: 99, processorWatts: 9.0, joules: 20, groupKey: "app:term", groupName: "Terminal", bundlePath: nil)
        let all = [root, child, grand, reusedStaleChild]
        let nodes = ProcessInspector.descendants(of: [root], in: all)
        XCTAssertEqual(nodes.map { $0.process.reading.name }, ["node", "esbuild"])
        XCTAssertEqual(nodes.map(\.depth), [1, 2])
        let parentReading = ProcessReading(identity: ProcessIdentity(pid: 1, start: 1), name: "launchd", path: "/sbin/launchd")
        let ctx = ProcessContext(identity: root.id, role: "Interpreter · zsh", arguments: ["/bin/zsh", "-l"], workingDirectory: "/Users/josh/project", parents: [parentReading], issues: [])
        let digest = ProcessInspector.usageDigest(title: "zsh", targets: [root], contexts: [ctx], allProcesses: all)
        XCTAssertTrue(digest.contains("Process: zsh (PID 100)"))
        XCTAssertTrue(digest.contains("Project project"))
        XCTAssertTrue(digest.contains("Working directory: /Users/josh/project"))
        XCTAssertTrue(digest.contains("Launcher chain: launchd (PID 1) → zsh"))
        XCTAssertTrue(digest.contains("Subtree including 2 child process(es): 4.70 W processor power, 107.0% CPU"))
        let limactl = ProcessReading(identity: ProcessIdentity(pid: 71823, start: 8), name: "limactl", path: "/opt/homebrew/bin/limactl")
        let vmRole = ProcessInspector.role(name: "com.apple.Virtualization.VirtualMachine", path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", responsible: limactl, openPaths: ["/Users/josh/.colima/_lima/colima/disk", "/Users/josh/MDMartin/AIrecruite/supabase"])
        XCTAssertEqual(vmRole, "Colima / Lima Linux VM · kicked off by limactl (PID 71823)")
    }
    func testSummaryFactsPreserveUpstreamParentDirectionAndAllProcesses() {
        let browser = ProcessReading(identity: ProcessIdentity(pid: 4, start: 1), name: "Chrome")
        let automation = ProcessReading(identity: ProcessIdentity(pid: 3, start: 1), name: "agent-browser")
        let context = ProcessContext(identity: ProcessIdentity(pid: 5, start: 2), role: "Web renderer", arguments: nil, workingDirectory: "/project", parents: [browser, automation], issues: [])
        let facts = ProcessInspector.summaryFacts([context, context])
        XCTAssertTrue(facts.contains("2 process(es) inspected")); XCTAssertTrue(facts.contains("Chrome ← agent-browser"))
        XCTAssertTrue(facts.contains("Working directory: /project")); XCTAssertTrue(facts.contains("not a proven original launcher"))
    }
    func testLiveInspectionChecksIdentityAndReadsWorkingDirectory() throws {
        let own = try XCTUnwrap(NativeSampler.readProcess(pid: getpid()))
        let context = try XCTUnwrap(ProcessInspector.inspect(own))
        XCTAssertEqual(context.identity, own.identity); XCTAssertNotNil(context.workingDirectory)
        XCTAssertNotNil(context.arguments)
        var replaced = own; replaced.identity.start += 1
        XCTAssertNil(ProcessInspector.inspect(replaced))
        XCTAssertTrue(context.parents.allSatisfy { $0.identity.start <= own.identity.start })
    }
}

extension ProcessContextTests {
    func testProjectNameComesFromNearestGitCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pw-project-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("power-watch", isDirectory: true)
        let nested = repo.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: repo.appendingPathComponent(".git").path, contents: Data("gitdir: /tmp/x".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        let hint = ProcessInspector.project(startingAt: nested.appendingPathComponent("index.js").path)
        XCTAssertEqual(hint?.name, "power-watch")
        XCTAssertEqual(hint?.root, repo.standardizedFileURL.path)
        XCTAssertNil(ProcessInspector.project(startingAt: "/Users/Shared/Library/Application Support/Cursor/state.vscdb"))
        let cwd = ProcessContext(identity: ProcessIdentity(pid: 1, start: 1), role: "Script · index.js", arguments: ["node", "index.js"], workingDirectory: repo.path, parents: [], issues: [])
        let other = ProcessContext(identity: ProcessIdentity(pid: 2, start: 1), role: "Script · index.js", arguments: ["node", "index.js"], workingDirectory: repo.path, parents: [], issues: [])
        XCTAssertEqual(ProcessInspector.projects(in: [cwd, other]).map(\.name), ["power-watch"])
        let nodeA = ProcessUsage(reading: ProcessReading(identity: ProcessIdentity(pid: 11, start: 10), parentPID: 1, name: "node", path: "/usr/local/bin/node", memoryBytes: 1_000_000), cpuPercent: 18, processorWatts: 0.28, joules: 1, groupKey: "node", groupName: "node", bundlePath: nil)
        let nodeB = ProcessUsage(reading: ProcessReading(identity: ProcessIdentity(pid: 12, start: 10), parentPID: 1, name: "node", path: "/usr/local/bin/node", memoryBytes: 1_000_000), cpuPercent: 4, processorWatts: 0.10, joules: 1, groupKey: "node", groupName: "node", bundlePath: nil)
        let chrome = ProcessUsage(reading: ProcessReading(identity: ProcessIdentity(pid: 13, start: 20), parentPID: 11, name: "Google Chrome", path: "/Applications/Google Chrome.app", memoryBytes: 2_000_000), cpuPercent: 1, processorWatts: 0.01, joules: 1, groupKey: "chrome", groupName: "Google Chrome", bundlePath: nil)
        let ghost = ProcessReading(identity: ProcessIdentity(pid: 154, start: 1), name: "ghostty", path: "/opt/homebrew/bin/ghostty")
        let parts = root.appendingPathComponent("lexus-parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: parts.appendingPathComponent(".git").path, contents: Data())
        let ctxA = ProcessContext(identity: nodeA.id, role: "Script · index.js", arguments: ["node", "index.js"], workingDirectory: repo.path, parents: [], responsible: ghost, issues: [])
        let ctxB = ProcessContext(identity: nodeB.id, role: "Script · index.js", arguments: ["node", "index.js"], workingDirectory: parts.path, parents: [], issues: [])
        let snapshots = ProcessInspector.projectSnapshots(targets: [nodeA, nodeB], contexts: [ctxA, ctxB], allProcesses: [nodeA, nodeB, chrome])
        XCTAssertEqual(snapshots.map(\.name), ["lexus-parts", "power-watch"])
        XCTAssertEqual(snapshots[1].launchedBy, "ghostty (PID 154)")
        XCTAssertTrue(snapshots[0].direct.contains("0.10 W processor power"))
        XCTAssertTrue(snapshots[1].direct.contains("0.28 W processor power"))
        XCTAssertTrue(snapshots[0].subtree.contains("no child"))
        XCTAssertTrue(snapshots[1].subtree.contains("1 child"))
    }
    func testRestrictedInspectionDoesNotMeanExited() {
        let expected = ProcessIdentity(pid: 937, start: 123)
        XCTAssertEqual(ProcessInspector.inspectionStatus(expected: expected, observed: nil, signalResult: -1, signalError: EPERM), .restricted)
        XCTAssertEqual(ProcessInspector.inspectionStatus(expected: expected, observed: nil, signalResult: 0, signalError: 0), .restricted)
        XCTAssertEqual(ProcessInspector.inspectionStatus(expected: expected, observed: nil, signalResult: -1, signalError: ESRCH), .exited)
        XCTAssertEqual(ProcessInspector.inspectionStatus(expected: expected, observed: ProcessIdentity(pid: 937, start: 124), signalResult: 0, signalError: 0), .replaced)
        XCTAssertEqual(ProcessInspector.inspectionStatus(expected: expected, observed: expected, signalResult: 0, signalError: 0), .verified)
    }
    func testServiceGuideUsesSystemLocationAndDoesNotInventAppOwnership() {
        let service = ProcessReading(identity: ProcessIdentity(pid: 937, start: 1), parentPID: 1, uid: 88, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer")
        let guide = ServiceDescriptions.guide(for: service)
        XCTAssertTrue(guide?.purpose.contains("shared display") == true)
        XCTAssertTrue(guide?.scope.contains("launchd") == true)
        XCTAssertTrue(guide?.scope.contains("cannot be reliably charged to one app") == true)
        var fake = service; fake.path = "/Users/example/WindowServer"
        XCTAssertNil(ServiceDescriptions.guide(for: fake))
    }
    func testCachedAppTotalsPreserveMissingZeroAndMutation() {
        let sample = MachineSample(processes: [ProcessReading(identity: ProcessIdentity(pid: 42, start: 1), name: "test", path: "/tmp/test", memoryBytes: 0, gpuMillisecondsPerSecond: 0)])
        let usage = MeasurementEngine().ingest(sample, expectedInterval: 15)
        var app = try! XCTUnwrap(AppUsage.grouped(usage.processes).first)
        XCTAssertEqual(app.knownMemoryBytes, 0); XCTAssertEqual(app.gpuMillisecondsPerSecond, 0); XCTAssertNil(app.processorWatts)
        app.processes = []
        XCTAssertNil(app.knownMemoryBytes); XCTAssertNil(app.gpuMillisecondsPerSecond)
    }
}
