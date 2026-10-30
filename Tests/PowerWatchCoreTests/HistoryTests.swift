import XCTest
import SQLite3
@testable import PowerWatchCore

final class HistoryTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func interval(at start: Date, seconds: Double = 15, joules: Double = 15) -> UsageInterval {
        let reading = ProcessReading(identity: ProcessIdentity(pid: 123, start: 100), name: "Example", path: "/bin/example", cpuNanoseconds: 0, energyNanojoules: 0)
        let process = ProcessUsage(reading: reading, cpuPercent: 5, processorWatts: joules / seconds, joules: joules, groupKey: "example", groupName: "Example", bundlePath: nil)
        return UsageInterval(start: start, end: start.addingTimeInterval(seconds), seconds: seconds, processes: [process], batteryJoules: joules * 4, batteryLossPoints: 0.2, attributionValid: true)
    }
    func testHistoryPersistsExitedProcessesAndSplitsBuckets() throws {
        let url = directory.appendingPathComponent("history.sqlite")
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 + 55)
        do { let store = try HistoryStore(url: url); try store.record(interval(at: now)) }
        let reopened = try HistoryStore(url: url)
        let summary = try reopened.summary(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120))
        XCTAssertEqual(summary.rows.count, 1); XCTAssertEqual(summary.rows[0].joules, 15, accuracy: 0.001)
        XCTAssertEqual(summary.rows[0].shareOfDrain!, 25, accuracy: 0.001)
        XCTAssertEqual(summary.rows[0].lossPoints, 0.05, accuracy: 0.001)
        XCTAssertEqual(summary.remainderJoules, 45, accuracy: 0.001)
        XCTAssertEqual(summary.points.count, 2)
        let specific = try reopened.summary(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120), entity: "pid:123:100")
        XCTAssertEqual(specific.rows[0].joules, 15)
    }
    func testCompactionIsIdempotentAndRetentionRemovesOldData() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        try store.record(interval(at: now.addingTimeInterval(-2 * 86400)))
        try store.record(interval(at: now.addingTimeInterval(-8 * 86400)))
        try store.maintain(now: now); try store.maintain(now: now)
        let result = try store.summary(from: now.addingTimeInterval(-10 * 86400), to: now)
        XCTAssertEqual(result.rows[0].joules, 15, accuracy: 0.001)
        XCTAssertGreaterThan(result.availableSince!, now.addingTimeInterval(-7 * 86400))
        try store.clear(); XCTAssertTrue(try store.summary(from: now.addingTimeInterval(-10 * 86400), to: now).rows.isEmpty)
    }
    func testOneMinuteHistoryHasFineBucketsAndCompactsWithoutChangingTotals() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
        for offset in stride(from: 0.0, to: 60.0, by: 15.0) { try store.record(interval(at: now.addingTimeInterval(offset))) }
        let minute = try store.summary(from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(minute.points.count, 4); XCTAssertEqual(minute.rows[0].joules, 60, accuracy: 0.001)
        XCTAssertEqual(minute.monitoredSeconds, 60, accuracy: 0.001)
        try store.maintain(now: now.addingTimeInterval(7200)); try store.maintain(now: now.addingTimeInterval(7200))
        let compacted = try store.summary(from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(compacted.points.count, 1); XCTAssertEqual(compacted.rows[0].joules, 60, accuracy: 0.001)
        XCTAssertEqual(compacted.monitoredSeconds, 60, accuracy: 0.001)
    }
    func testExistingMinuteHistoryTransitionsWithoutDuplicateEnergy() throws {
        let url = directory.appendingPathComponent("history.sqlite")
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
        do { let store = try HistoryStore(url: url); try store.record(interval(at: start)) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "UPDATE usage SET resolution=60; UPDATE system SET resolution=60;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let reopened = try HistoryStore(url: url)
        try reopened.record(interval(at: start.addingTimeInterval(15)))
        try reopened.record(interval(at: start.addingTimeInterval(60), seconds: 60, joules: 60))
        let result = try reopened.summary(from: start, to: start.addingTimeInterval(120))
        XCTAssertEqual(result.rows[0].joules, 90, accuracy: 0.001)
        XCTAssertEqual(result.monitoredSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(result.points.count, 5)
        try reopened.maintain(now: start.addingTimeInterval(7200))
        let compacted = try reopened.summary(from: start, to: start.addingTimeInterval(120))
        XCTAssertEqual(compacted.rows[0].joules, 90, accuracy: 0.001)
        XCTAssertEqual(compacted.monitoredSeconds, 90, accuracy: 0.001)
    }
    func testChargingUsageIsRecordedWithoutDrainAttribution() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date(); var value = interval(at: now); value.batteryJoules = nil; value.batteryLossPoints = nil; value.attributionValid = false
        try store.record(value)
        let result = try store.summary(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120))
        XCTAssertEqual(result.rows[0].joules, 15); XCTAssertNil(result.rows[0].shareOfDrain); XCTAssertEqual(result.rows[0].lossPoints, 0)
        XCTAssertEqual(result.rows[0].averageWatts, 1, accuracy: 0.001)
        let members = try store.summary(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(120), membersOf: "example")
        XCTAssertEqual(members.rows.count, 1)
        XCTAssertEqual(members.rows[0].id, "pid:123:100")
        XCTAssertEqual(members.rows[0].joules, 15, accuracy: 0.001)
        XCTAssertEqual(members.rows[0].averageWatts, 1, accuracy: 0.001)
    }
    func testBatteryAndImpactHistorySurviveCompactionAndClear() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 300) * 300)
        var first = interval(at: start)
        first.processes[0].reading.energyImpact = 10
        first.batterySnapshot = BatteryReading(percentage: 80, onBattery: true, charging: false, dischargeWatts: 12)
        var second = interval(at: start.addingTimeInterval(15))
        second.processes[0].reading.energyImpact = 30
        second.batterySnapshot = BatteryReading(percentage: 81, onBattery: false, charging: true, dischargeWatts: nil)
        try store.record(first); try store.record(second)
        var result = try store.summary(from: start, to: start.addingTimeInterval(30))
        XCTAssertEqual(result.rows.first?.averageImpact ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(result.batteryPoints.count, 2)
        XCTAssertFalse(result.batteryPoints[0].charging); XCTAssertTrue(result.batteryPoints[1].charging)
        try store.maintain(now: start.addingTimeInterval(2 * 86400))
        try store.maintain(now: start.addingTimeInterval(2 * 86400))
        result = try store.summary(from: start, to: start.addingTimeInterval(30))
        XCTAssertEqual(result.rows.first?.averageImpact ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(result.batteryPoints.count, 1)
        XCTAssertEqual(result.batteryPoints[0].percentage, 80.5, accuracy: 0.001)
        XCTAssertTrue(result.batteryPoints[0].charging)
        try store.clear()
        result = try store.summary(from: start, to: start.addingTimeInterval(30))
        XCTAssertTrue(result.batteryPoints.isEmpty); XCTAssertTrue(result.rows.isEmpty)
    }
    func testImpactOnlyRowsDoNotInventProcessorEnergyOrBatteryShare() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 15) * 15)
        var value = interval(at: start)
        value.processes[0].joules = nil; value.processes[0].reading.energyImpact = 7
        try store.record(value)
        let result = try store.summary(from: start, to: start.addingTimeInterval(15))
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].averageImpact, 7)
        XCTAssertFalse(result.rows[0].energyAvailable); XCTAssertNil(result.rows[0].shareOfDrain)
        let member = try store.summary(from: start, to: start.addingTimeInterval(15), membersOf: "example")
        XCTAssertEqual(member.rows.first?.averageImpact, 7)
    }
    func testGroupedImpactSumsProcessesAndAveragesAvailableIntervals() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 15) * 15)
        var first = interval(at: start)
        first.processes[0].reading.energyImpact = 3
        var child = first.processes[0]
        child.reading.identity = ProcessIdentity(pid: 124, start: 100)
        child.reading.energyImpact = 5
        first.processes.append(child)
        var second = interval(at: start.addingTimeInterval(15))
        second.processes[0].reading.energyImpact = 2
        var missing = child; missing.reading.energyImpact = nil
        second.processes.append(missing)
        try store.record(first); try store.record(second)
        let all = try store.summary(from: start, to: start.addingTimeInterval(30))
        XCTAssertEqual(all.rows.first?.averageImpact ?? -1, 5, accuracy: 0.001)
        let member = try store.summary(from: start, to: start.addingTimeInterval(30), entity: "pid:124:100")
        XCTAssertEqual(member.rows.first?.averageImpact, 5)
        let latest = try store.summary(from: start.addingTimeInterval(15), to: start.addingTimeInterval(30))
        XCTAssertEqual(latest.rows.first?.averageImpact, 2)
    }
    func testDailyLossIncludesOnlyMeasuredDischargeDays() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        var charge = interval(at: yesterday.addingTimeInterval(15))
        charge.batteryJoules = nil; charge.batteryLossPoints = nil; charge.attributionValid = false
        try store.record(interval(at: yesterday)); try store.record(charge)
        try store.record(interval(at: today))
        let result = try store.summary(from: yesterday, to: today.addingTimeInterval(30))
        XCTAssertEqual(result.dailyLoss.count, 2)
        XCTAssertEqual(result.dailyLoss[0].points, 0.2, accuracy: 0.001)
        XCTAssertEqual(result.dailyLoss[1].points, 0.2, accuracy: 0.001)
    }
    func testMixedExternalPowerHistoryUsesOnlyValidBatteryIntervalsForDrainShare() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 15) * 15)
        try store.record(interval(at: now))
        var external = interval(at: now.addingTimeInterval(15), joules: 150)
        external.batteryJoules = nil; external.batteryLossPoints = nil; external.attributionValid = false
        try store.record(external)
        let result = try store.summary(from: now, to: now.addingTimeInterval(30))
        XCTAssertEqual(result.rows[0].joules, 165, accuracy: 0.001)
        XCTAssertEqual(result.rows[0].attributedJoules, 15, accuracy: 0.001)
        XCTAssertEqual(result.rows[0].shareOfDrain!, 25, accuracy: 0.001)
        XCTAssertEqual(result.rows[0].lossPoints, 0.05, accuracy: 0.001)
        XCTAssertEqual(result.attributionCoverage, 0.5, accuracy: 0.001)
        let externalOnly = try store.summary(from: now.addingTimeInterval(15), to: now.addingTimeInterval(30))
        XCTAssertNil(externalOnly.rows[0].shareOfDrain)
        XCTAssertEqual(externalOnly.rows[0].joules, 150, accuracy: 0.001)
    }
    func testOpenBucketDoesNotUnderCountLatestActivity() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 + 5)
        try store.record(interval(at: now))
        let result = try store.summary(from: now, to: now.addingTimeInterval(15))
        XCTAssertEqual(result.rows[0].joules, 15, accuracy: 0.001)
        XCTAssertEqual(result.monitoredSeconds, 15, accuracy: 0.001)
        XCTAssertEqual(result.batteryLossPoints, 0.2, accuracy: 0.001)
    }
    func testStorageCeilingPrunesOldestFirst() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        for offset in [0.0, -86400, -172800] { try store.record(interval(at: now.addingTimeInterval(offset))) }
        try store.maintain(now: now, byteLimit: 1)
        XCTAssertTrue(try store.summary(from: now.addingTimeInterval(-7 * 86400), to: now.addingTimeInterval(60)).rows.isEmpty)
    }
    func testCachedMetadataUpdatesAndReturnsAfterClearOrPruning() throws {
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        let now = Date()
        try store.record(interval(at: now))
        var changed = interval(at: now.addingTimeInterval(15))
        changed.processes[0].reading.name = "Renamed Worker"
        changed.processes[0].reading.parentPID = 456
        try store.record(changed)
        var result = try store.summary(from: now, to: now.addingTimeInterval(60), entity: "pid:123:100")
        XCTAssertEqual(result.rows.first?.name, "Renamed Worker")
        XCTAssertEqual(result.rows.first?.joules, 30)
        try store.clear()
        try store.record(changed)
        result = try store.summary(from: now, to: now.addingTimeInterval(60), entity: "pid:123:100")
        XCTAssertEqual(result.rows.first?.name, "Renamed Worker")
        XCTAssertEqual(result.rows.first?.joules, 15)
        let later = now.addingTimeInterval(8 * 86400)
        try store.maintain(now: later)
        changed.start = later; changed.end = later.addingTimeInterval(15)
        try store.record(changed)
        result = try store.summary(from: later, to: later.addingTimeInterval(60), entity: "pid:123:100")
        XCTAssertEqual(result.rows.first?.name, "Renamed Worker")
        XCTAssertEqual(result.rows.first?.joules, 15)
    }
}
