import XCTest
@testable import PowerWatchCore

final class GPUTests: XCTestCase {
    let instance = ProcessIdentity(pid: 42, start: 100)
    func client(_ values: [UInt64], id: UInt64 = 1, process: ProcessIdentity? = nil, layout: [String]? = nil) -> GPUClientCounter {
        GPUClientCounter(registryID: id, process: process ?? instance, layout: layout ?? values.map { _ in "Metal" }, nanoseconds: values)
    }
    func testNanosecondRatesAndZero() {
        let tracker = GPUDeltaTracker()
        XCTAssertTrue(tracker.ingest([client([1_000_000_000])], uptime: 10).isEmpty)
        XCTAssertEqual(tracker.ingest([client([3_000_000_000])], uptime: 15)[instance], 400)
        XCTAssertEqual(tracker.ingest([client([3_000_000_000])], uptime: 20)[instance], 0)
        XCTAssertTrue(tracker.ingest([], uptime: 25).isEmpty)
    }
    func testMultipleClientsAndDuplicateRegistryIDs() {
        let tracker = GPUDeltaTracker()
        _ = tracker.ingest([client([0, 0]), client([0], id: 2)], uptime: 1)
        let clients = [client([1_000_000_000, 2_000_000_000]), client([1_000_000_000], id: 2)]
        XCTAssertEqual(tracker.ingest(clients + [clients[0]], uptime: 3)[instance], 2000)
    }
    func testResetLayoutPIDReuseAndSleep() {
        let tracker = GPUDeltaTracker()
        _ = tracker.ingest([client([5, 5])], uptime: 1)
        XCTAssertTrue(tracker.ingest([client([4, 100])], uptime: 2).isEmpty)
        XCTAssertTrue(tracker.ingest([client([6])], uptime: 3).isEmpty)
        XCTAssertTrue(tracker.ingest([client([8], layout: ["OpenGL"])], uptime: 4).isEmpty)
        XCTAssertTrue(tracker.ingest([client([10], process: ProcessIdentity(pid: 42, start: 200))], uptime: 5).isEmpty)
        XCTAssertTrue(tracker.ingest([client([100])], uptime: 40).isEmpty)
        tracker.reset()
        XCTAssertTrue(tracker.ingest([client([200])], uptime: 45).isEmpty)
    }
    func testNewAndExitedClientsDoNotImportLifetimeWork() {
        let tracker = GPUDeltaTracker()
        _ = tracker.ingest([client([100])], uptime: 1)
        XCTAssertTrue(tracker.ingest([client([100_000_000], id: 2)], uptime: 2).isEmpty)
        XCTAssertTrue(tracker.ingest([client([200])], uptime: 3).isEmpty)
    }
    func testParsingAndDirectPrecedence() {
        let rows: [[String: Any]] = [["API": "Metal", "accumulatedGPUTime": NSNumber(value: 123)], ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 0)]]
        XCTAssertEqual(GPUSampler.counter(direct: nil, usage: rows)?.1, [123, 0])
        XCTAssertEqual(GPUSampler.counter(direct: NSNumber(value: 7), usage: rows)?.1, [7])
        XCTAssertNil(GPUSampler.counter(direct: nil, usage: []))
        XCTAssertNil(GPUSampler.counter(direct: nil, usage: [["API": "Metal"]]))
        XCTAssertNil(GPUSampler.counter(direct: NSNumber(value: -1), usage: rows))
        XCTAssertNil(GPUSampler.counter(direct: NSNumber(value: true), usage: rows))
        XCTAssertNil(GPUSampler.counter(direct: NSNumber(value: Double.nan), usage: rows))
        XCTAssertEqual(GPUSampler.creatorPID("pid 42, GPU client"), 42)
        XCTAssertNil(GPUSampler.creatorPID("pid -2, unknown"))
    }
    func testDeviceUtilizationAndLegacySample() throws {
        XCTAssertEqual(GPUSampler.utilization(["Device Utilization %": 0]), 0)
        XCTAssertEqual(GPUSampler.utilization(["GPU Activity(%)": 82]), 82)
        XCTAssertNil(GPUSampler.utilization(["Device Utilization %": 101]))
        XCTAssertNil(GPUSampler.utilization([:]))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MachineSample(processes: []))) as! [String: Any]
        json.removeValue(forKey: "gpu")
        let sample = try JSONDecoder().decode(MachineSample.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(sample.gpu)
    }
}
