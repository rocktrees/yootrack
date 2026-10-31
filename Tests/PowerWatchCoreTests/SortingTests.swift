import XCTest
@testable import PowerWatchCore

final class SortingTests: XCTestCase {
    func testSearchMatchesCaseDiacriticsWhitespaceAndProcessFields() {
        XCTAssertTrue(SearchFilter.matches("  CAFE ", fields: [nil, "Café"]))
        XCTAssertTrue(SearchFilter.matches(" \n ", fields: []))
        XCTAssertFalse(SearchFilter.matches("missing", fields: ["something"]))
        var item = app("Browser", value: 1)
        item.processes[0].reading.path = "/Applications/Example.app/worker"
        XCTAssertTrue(SearchFilter.matches("example.app", app: item))
        XCTAssertTrue(SearchFilter.matches(String(item.processes[0].id.pid), app: item))
        XCTAssertFalse(SearchFilter.matches("unrelated", app: item))
    }
    func testHistoryRankingUsesSelectedMetricAndKeepsOriginalRankWhenFiltered() {
        var alpha = HistoryRow(id: "alpha", name: "Alpha", bundlePath: "/Apps/Alpha.app", joules: 10, attributedJoules: 0, lossPoints: 0.1, observedSeconds: 1, shareOfDrain: 1)
        var beta = HistoryRow(id: "beta", name: "Beta", bundlePath: nil, joules: 20, attributedJoules: 0, lossPoints: 0.2, observedSeconds: 1, shareOfDrain: 2)
        var missing = HistoryRow(id: "missing", name: "Missing", bundlePath: nil, joules: 100, attributedJoules: 0, lossPoints: 1, observedSeconds: 1, shareOfDrain: nil)
        alpha.averageImpact = 9; beta.averageImpact = 2; missing.energyAvailable = false
        let rows = [alpha, beta, missing]
        XCTAssertEqual(HistoryRanking.battery.ranked(rows).map(\.id), ["beta", "alpha", "missing"])
        XCTAssertEqual(HistoryRanking.impact.ranked(rows).map(\.id), ["alpha", "beta", "missing"])
        XCTAssertEqual(HistoryRanking.processor.ranked(rows).map(\.id), ["beta", "alpha", "missing"])
        let filtered = HistoryRanking.processor.ranked(rows, matching: "alpha.app")
        XCTAssertEqual(filtered.map(\.id), ["alpha"])
        XCTAssertEqual(filtered.map(\.rank), [2])
    }
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
