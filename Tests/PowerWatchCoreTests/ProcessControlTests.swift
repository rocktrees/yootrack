import XCTest
import Darwin
@testable import PowerWatchCore

final class ProcessControlTests: XCTestCase {
    func testOnlyUsersNonSystemProcessesCanBeStopped() {
        let own = ProcessReading(identity: ProcessIdentity(pid: 98765, start: 1), uid: getuid(), name: "Worker", path: "/usr/local/bin/worker")
        XCTAssertTrue(ProcessControl.allowed(own))
        var changed = own; changed.uid = 0; XCTAssertFalse(ProcessControl.allowed(changed))
        changed = own; changed.path = "/System/Library/worker"; XCTAssertFalse(ProcessControl.allowed(changed))
        changed = own; changed.identity.pid = getpid(); XCTAssertFalse(ProcessControl.allowed(changed))
        changed = own; changed.name = "powermetrics"; XCTAssertFalse(ProcessControl.allowed(changed))
        changed = own; changed.identity.pid = 1; XCTAssertFalse(ProcessControl.allowed(changed))
    }
    func testStopAndForceStopDisposableBackgroundProcess() throws {
        for force in [false, true] {
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]; try child.run()
            defer { if child.isRunning { child.terminate() } }
            guard let reading = NativeSampler.readProcess(pid: child.processIdentifier) else { throw XCTSkip("Process inspection is restricted in this execution sandbox.") }
            try ProcessControl.execute(reading, force: force); child.waitUntilExit()
            XCTAssertFalse(child.isRunning); XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        }
    }
    func testChangedIdentityCannotTerminateNewProcess() throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]; try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        guard var reading = NativeSampler.readProcess(pid: child.processIdentifier) else { throw XCTSkip("Process inspection is restricted in this execution sandbox.") }
        reading.identity.start += 1
        XCTAssertThrowsError(try ProcessControl.execute(reading, force: true)); XCTAssertTrue(child.isRunning)
    }
}
