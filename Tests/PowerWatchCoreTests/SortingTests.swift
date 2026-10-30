import XCTest
@testable import PowerWatchCore

final class SortingTests: XCTestCase {
    func app(_ name: String, value: Double?) -> AppUsage {
        let reading = ProcessReading(identity: ProcessIdentity(pid: name == "Low" ? 1 : name == "High" ? 2 : 3, start: 1), name: name,
            memoryBytes: value.map { UInt64($0) }, energyImpact: value, gpuMillisecondsPerSecond: value,
            networkReceivedBytesPerSecond: value, networkSentBytesPerSecond: value)
        let p = ProcessUsage(reading: reading, cpuPercent: value, processorWatts: value, joules: value, groupKey: name, groupName: name, bundlePath: nil)
        return AppUsage(id: name, name: name, bundlePath: nil, processes: [p])
    }
    func testEveryNumericColumnReversesAndKeepsUnavailableLast() {
        let apps = [app("Missing", value: nil), app("Low", value: 0), app("High", value: 10)]
        for column in UsageSort.allCases where column != .name {
            XCTAssertEqual(AppSorting.sorted(apps, by: column, descending: true).map(\.id), ["High", "Low", "Missing"], "\(column)")
            XCTAssertEqual(AppSorting.sorted(apps, by: column, descending: false).map(\.id), ["Low", "High", "Missing"], "\(column)")
        }
    }
    func testNameSortAndMetricTiesHaveDeterministicOrdering() {
        let apps = [app("Zebra", value: 1), app("Alpha", value: 1)]
        XCTAssertEqual(AppSorting.sorted(apps, by: .name, descending: false).map(\.id), ["Alpha", "Zebra"])
        XCTAssertEqual(AppSorting.sorted(apps, by: .name, descending: true).map(\.id), ["Zebra", "Alpha"])
        XCTAssertEqual(AppSorting.sorted(apps, by: .cpu, descending: true).map(\.id), ["Alpha", "Zebra"])
    }
    func testNetworkUsesCombinedKnownTrafficAndProcessesUseSameColumn() {
        var low = app("Low", value: 1)
        low.processes[0].reading.networkReceivedBytesPerSecond = nil
        low.processes[0].reading.networkSentBytesPerSecond = 100
        let high = app("High", value: 10)
        XCTAssertEqual(AppSorting.sorted([high, low], by: .network, descending: true).map(\.id), ["Low", "High"])
        XCTAssertEqual(AppSorting.sortedProcesses(high.processes + low.processes, by: .cpu, descending: false).map(\.reading.name), ["Low", "High"])
    }
}
