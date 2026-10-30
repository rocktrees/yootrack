import XCTest
@testable import PowerWatchCore

final class MeasurementTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_790_000_000)
    func process(pid: Int32 = 42, start: UInt64 = 10, energy: UInt64? = 0, cpu: UInt64? = 0, path: String = "/Applications/Example.app/Contents/MacOS/Example", parent: Int32 = 1, uid: UInt32 = 501, name: String = "Example") -> ProcessReading {
        ProcessReading(identity: ProcessIdentity(pid: pid, start: start), parentPID: parent, uid: uid, name: name, path: path, cpuNanoseconds: cpu, energyNanojoules: energy)
    }
    func sample(_ offset: Double, processes: [ProcessReading], battery: BatteryReading? = nil) -> MachineSample {
        MachineSample(timestamp: origin.addingTimeInterval(offset), uptime: 100 + offset, processes: processes, battery: battery)
    }
    func battery(_ percentage: Double, watts: Double = 10, onBattery: Bool = true, charging: Bool = false) -> BatteryReading {
        BatteryReading(percentage: percentage, onBattery: onBattery, charging: charging, dischargeWatts: watts)
    }
    func testWattsCPUAndConservativeAttribution() {
        let engine = MeasurementEngine()
        let first = engine.ingest(sample(0, processes: [process(energy: 1_000_000_000)], battery: battery(70)), expectedInterval: 5)
        XCTAssertNil(first.processes[0].processorWatts)
        let result = engine.ingest(sample(5, processes: [process(energy: 11_000_000_000, cpu: 2_500_000_000)], battery: battery(69.8)), expectedInterval: 5)
        XCTAssertEqual(result.processes[0].processorWatts!, 2, accuracy: 0.0001)
        XCTAssertEqual(result.processes[0].cpuPercent!, 50, accuracy: 0.0001)
        XCTAssertEqual(result.batteryJoules!, 50, accuracy: 0.0001)
        XCTAssertEqual(result.batteryLossPoints!, 0.2, accuracy: 0.0001)
        XCTAssertTrue(result.attributionValid)
        XCTAssertEqual(result.remainderJoules!, 40, accuracy: 0.0001)
    }
    func testPIDReuseAndCounterResetDoNotCreateSpikes() {
        let engine = MeasurementEngine()
        _ = engine.ingest(sample(0, processes: [process(energy: 500)]), expectedInterval: 5)
        let reuse = engine.ingest(sample(5, processes: [process(start: 11, energy: 900)]), expectedInterval: 5)
        XCTAssertNil(reuse.processes[0].processorWatts)
        let reset = engine.ingest(sample(10, processes: [process(start: 11, energy: 1)]), expectedInterval: 5)
        XCTAssertNil(reset.processes[0].processorWatts)
        XCTAssertNil(MeasurementEngine.delta(nil, 1))
        XCTAssertNil(MeasurementEngine.delta(1, nil))
    }
    func testChargingTransitionAndInconsistentCountersDisableAttribution() {
        let engine = MeasurementEngine()
        _ = engine.ingest(sample(0, processes: [process()], battery: battery(70)), expectedInterval: 5)
        let charging = engine.ingest(sample(5, processes: [process(energy: 1_000_000_000)], battery: battery(71, onBattery: false, charging: true)), expectedInterval: 5)
        XCTAssertFalse(charging.attributionValid); XCTAssertNil(charging.batteryJoules)
        _ = engine.ingest(sample(10, processes: [process(energy: 2_000_000_000)], battery: battery(70)), expectedInterval: 5)
        let inconsistent = engine.ingest(sample(15, processes: [process(energy: 102_000_000_000)], battery: battery(69)), expectedInterval: 5)
        XCTAssertFalse(inconsistent.attributionValid); XCTAssertNil(inconsistent.remainderJoules)
        XCTAssertTrue(inconsistent.issue!.contains("exceed"))
    }
    func testGaugeIncreaseGapAndReset() {
        let engine = MeasurementEngine()
        _ = engine.ingest(sample(0, processes: [process()], battery: battery(70)), expectedInterval: 5)
        let gauge = engine.ingest(sample(5, processes: [process(energy: 1_000_000_000)], battery: battery(70.1)), expectedInterval: 5)
        XCTAssertFalse(gauge.attributionValid)
        let gap = engine.ingest(sample(100, processes: [process(energy: 50_000_000_000)]), expectedInterval: 5)
        XCTAssertEqual(gap.seconds, 0); XCTAssertNil(gap.processes[0].processorWatts)
        engine.reset()
        XCTAssertEqual(engine.ingest(sample(105, processes: [process()]), expectedInterval: 5).seconds, 0)
    }
    func testUnavailableCountersStayUnavailableButSupportedZeroIsIdle() {
        let engine = MeasurementEngine()
        _ = engine.ingest(sample(0, processes: [process(energy: nil), process(pid: 43, energy: 0)]), expectedInterval: 5)
        let result = engine.ingest(sample(5, processes: [process(energy: nil), process(pid: 43, energy: 0)]), expectedInterval: 5)
        XCTAssertNil(result.processes[0].processorWatts); XCTAssertEqual(result.processes[1].processorWatts, 0)
        XCTAssertTrue(AppUsage.grouped(result.processes)[0].partial)
    }
    func testACSupplementationRecordsRealDrainWithoutInventingAppShares() {
        let watts = NativeSampler.dischargeWatts(voltageMillivolts: 12000, amperageRaw: UInt64(bitPattern: -3000), onBattery: false, charging: false)
        XCTAssertEqual(watts!, 36, accuracy: 0.0001)
        XCTAssertNil(NativeSampler.dischargeWatts(voltageMillivolts: 12000, amperageRaw: 3000, onBattery: false, charging: true))
        let engine = MeasurementEngine()
        _ = engine.ingest(sample(0, processes: [process()], battery: battery(60, watts: 36, onBattery: false)), expectedInterval: 5)
        let result = engine.ingest(sample(5, processes: [process(energy: 5_000_000_000)], battery: battery(59.9, watts: 36, onBattery: false)), expectedInterval: 5)
        XCTAssertEqual(result.batteryJoules!, 180, accuracy: 0.0001)
        XCTAssertEqual(result.batteryLossPoints!, 0.1, accuracy: 0.0001)
        XCTAssertFalse(result.attributionValid); XCTAssertNil(result.remainderJoules)
    }
    func testDisplayedBatteryLevelDoesNotReplacePreciseDrainGauge() throws {
        let engine = MeasurementEngine()
        let first = BatteryReading(percentage: 100, onBattery: true, charging: false, dischargeWatts: 10, rawPercentage: 96)
        let second = BatteryReading(percentage: 100, onBattery: true, charging: false, dischargeWatts: 10, rawPercentage: 95.9)
        _ = engine.ingest(sample(0, processes: [process()], battery: first), expectedInterval: 5)
        let interval = engine.ingest(sample(5, processes: [process(energy: 1_000_000_000)], battery: second), expectedInterval: 5)
        XCTAssertEqual(second.percentage, 100); XCTAssertEqual(interval.batteryLossPoints!, 0.1, accuracy: 0.0001)
        let legacy = try JSONDecoder().decode(BatteryReading.self, from: Data(#"{"percentage":70,"onBattery":true,"charging":false}"#.utf8))
        XCTAssertEqual(legacy.measurementPercentage, 70)
    }
    func testHardwareRatesRespectPIDReuseAndGroupSum() {
        var reading = process(start: UInt64(origin.timeIntervalSince1970 * 1e6))
        let hardware = HardwareReading(timestamp: origin, impactByPID: [42: 2], gpuMillisecondsByPID: [42: 100], networkReceivedByPID: [42: 1000], networkSentByPID: [42: 0])
        NativeSampler.applyHardware(hardware, to: &reading)
        XCTAssertEqual(reading.gpuMillisecondsPerSecond, 100); XCTAssertEqual(reading.networkSentBytesPerSecond, 0)
        var reused = process(start: reading.identity.start + 1)
        NativeSampler.applyHardware(hardware, to: &reused)
        XCTAssertNil(reused.energyImpact); XCTAssertNil(reused.gpuMillisecondsPerSecond); XCTAssertNil(reused.networkReceivedBytesPerSecond)
        let engine = MeasurementEngine()
        var child = reading; child.identity.pid = 43; child.gpuMillisecondsPerSecond = 50; child.networkReceivedBytesPerSecond = 2000
        let groups = AppUsage.grouped(engine.ingest(sample(0, processes: [reading, child]), expectedInterval: 5).processes)
        XCTAssertEqual(groups[0].gpuMillisecondsPerSecond, 150); XCTAssertEqual(groups[0].networkReceivedBytesPerSecond, 3000)
        XCTAssertNil(groups[0].knownMemoryBytes)
    }
    func testGroupingBundlesAncestorsAndMonitorWithoutDoubleCounting() {
        let processes = [process(pid: 42),
                         process(pid: 43, start: 11, path: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", parent: 42),
                         process(pid: 44, start: 12, path: "/usr/local/bin/child", parent: 42),
                         process(pid: 50, path: "/Library/PrivilegedHelperTools/ai.powerwatch.collector", uid: 0, name: "ai.powerwatch.collector"),
                         process(pid: 51, start: 11, path: "/usr/bin/powermetrics", parent: 50, uid: 0, name: "powermetrics"),
                         process(pid: 52, start: 11, path: "/usr/bin/powermetrics", uid: 0, name: "powermetrics"),
                         process(pid: 60, start: 9, path: "/usr/local/bin/unrelated", parent: 42)]
        let groups = ProcessGrouping.resolve(processes)
        XCTAssertEqual(groups[42]?.key, groups[43]?.key); XCTAssertEqual(groups[42]?.key, groups[44]?.key)
        XCTAssertEqual(groups[50]?.key, PowerWatchConstants.monitorGroup); XCTAssertEqual(groups[51]?.key, PowerWatchConstants.monitorGroup)
        XCTAssertNotEqual(groups[52]?.key, PowerWatchConstants.monitorGroup); XCTAssertNotEqual(groups[60]?.key, groups[42]?.key)
    }
}
