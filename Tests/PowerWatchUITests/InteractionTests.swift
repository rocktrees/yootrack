import XCTest

final class InteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private var logURL: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("PowerWatchInteractions-" + UUID().uuidString + ".jsonl")
        app = XCUIApplication(bundleIdentifier: "ai.powerwatch.app")
        app.launchArguments = ["--ui-testing", "--interaction-log", logURL.path]
        app.launch()
        XCTAssertTrue(app.buttons["consumer.app.fixture-app-000"].waitForExistence(timeout: 15))
    }
    override func tearDownWithError() throws {
        if let data = try? Data(contentsOf: logURL) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Native interaction timings (JSON lines)"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        try? FileManager.default.removeItem(at: logURL)
    }
    private func assertTitle(_ prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["details.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), file: file, line: line)
        let expectedTitle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", prefix, prefix), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [expectedTitle], timeout: 5), .completed,
            "Expected \(prefix), got \(title.value as? String ?? title.label)", file: file, line: line)
    }
    func testAppRowEmptySpaceAndEdgesSelect() {
        let row = app.buttons["consumer.app.fixture-app-000"]
        for offset in [CGVector(dx: 0.40, dy: 0.5), CGVector(dx: 0.65, dy: 0.08), CGVector(dx: 0.98, dy: 0.92), CGVector(dx: 0.02, dy: 0.5)] {
            app.buttons["consumer.app.fixture-app-001"].click()
            assertTitle("Fixture App 001")
            row.coordinate(withNormalizedOffset: offset).click()
            assertTitle("Fixture App 000")
        }
    }
    func testExpandedProcessEmptySpaceAndIndentSelect() {
        app.buttons["consumer.app.fixture-app-001"].click()
        app.buttons["consumer.expand.fixture-app-000"].click()
        assertTitle("Fixture App 001") // The disclosure remains a separate control.
        let process = app.buttons["consumer.process.1000000:1"]
        XCTAssertTrue(process.waitForExistence(timeout: 5))
        for offset in [CGVector(dx: 0.40, dy: 0.5), CGVector(dx: 0.005, dy: 0.5), CGVector(dx: 0.98, dy: 0.08)] {
            app.buttons["consumer.app.fixture-app-001"].click()
            process.coordinate(withNormalizedOffset: offset).click()
            assertTitle("Fixture process 000-0")
        }
    }
    func testHistoryRowEmptySpaceSelects() {
        app.radioButtons["History"].click()
        let row = app.descendants(matching: .any)["consumer.history.fixture-app-000"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.descendants(matching: .any)["consumer.history.fixture-app-001"].click()
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.5)).click()
        assertTitle("Fixture App 000")
    }
    func testLiveColumnHeaderReversesOrder() {
        let memory = app.buttons["sort.memory"]
        memory.click()
        XCTAssertTrue(app.buttons["consumer.app.fixture-app-249"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["consumer.app.fixture-app-249"].isHittable)
        XCTAssertTrue(memory.label.contains("descending"))
        memory.click()
        XCTAssertTrue(app.buttons["consumer.app.fixture-app-000"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["consumer.app.fixture-app-000"].isHittable)
        XCTAssertTrue(memory.label.contains("ascending"))
    }
    func testCompactMenuAndEveryColumnSorts() {
        app.terminate()
        app.launchArguments.append("--test-quick-menu")
        app.launch()
        let menu = app.descendants(matching: .any)["quick.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(menu.frame.width, 550)
        let columns: [(String, String, String)] = [
            ("memory", "249", "000"), ("cpu", "000", "249"), ("gpu", "249", "000"),
            ("network", "249", "000"), ("watts", "000", "249"), ("name", "000", "249")
        ]
        for (column, first, reversed) in columns {
            let header = menu.buttons["sort." + column]
            header.click()
            XCTAssertTrue(menu.buttons["menu.consumer.fixture-app-" + first].waitForExistence(timeout: 5), column)
            header.click()
            XCTAssertTrue(menu.buttons["menu.consumer.fixture-app-" + reversed].waitForExistence(timeout: 5), column + " reversed")
        }
    }
    func testCompactMenuHistoryTab() {
        app.terminate()
        app.launchArguments.append("--test-quick-menu")
        app.launch()
        let menu = app.descendants(matching: .any)["quick.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.radioButtons["History"].click()
        XCTAssertTrue(menu.buttons["menu.history.fixture-app-000"].waitForExistence(timeout: 5))
        XCTAssertTrue(menu.descendants(matching: .any)["menu.history.period"].exists)
        XCTAssertTrue(menu.staticTexts["Avg power"].exists)
        XCTAssertTrue(menu.staticTexts["Energy"].exists)
        menu.radioButtons["Live"].click()
        XCTAssertTrue(menu.buttons["menu.consumer.fixture-app-000"].waitForExistence(timeout: 5))
    }
    func testTabsLoadAndKeepMoneyDraft() {
        app.radioButtons["Money"].click()
        let payee = app.textFields["money.payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        payee.click()
        payee.typeText("Coffee shop")
        app.radioButtons["AI Usage"].click()
        XCTAssertTrue(app.buttons["provider.row.cursor"].waitForExistence(timeout: 5))
        app.radioButtons["History"].click()
        XCTAssertTrue(app.descendants(matching: .any)["consumer.history.fixture-app-000"].waitForExistence(timeout: 5))
        app.radioButtons["Money"].click()
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        XCTAssertEqual(payee.value as? String, "Coffee shop")
        app.radioButtons["Live"].click()
        XCTAssertTrue(app.buttons["consumer.app.fixture-app-000"].waitForExistence(timeout: 5))
    }
    func testTabSwitchLatency() throws {
        for _ in 0..<12 {
            app.radioButtons["History"].click()
            XCTAssertTrue(app.descendants(matching: .any)["consumer.history.fixture-app-000"].waitForExistence(timeout: 5))
            app.radioButtons["Live"].click()
            XCTAssertTrue(app.buttons["consumer.app.fixture-app-000"].waitForExistence(timeout: 5))
        }
        let records = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").compactMap { line -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }.filter { $0["kind"] as? String == "tab" }
        XCTAssertEqual(records.count, 24)
        let timings = records.compactMap { $0["handler_to_view_ms"] as? Double }.sorted()
        XCTAssertEqual(timings.count, 24)
        print("TAB_RENDER_TIMINGS_MS " + String(data: try JSONSerialization.data(withJSONObject: records, options: .sortedKeys), encoding: .utf8)!)
        XCTAssertLessThan(timings.last ?? .infinity, 500, "Tab handler-to-view update exceeded 500 ms; excludes test-driver and display presentation time.")
    }
}
