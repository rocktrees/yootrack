import XCTest
@testable import PowerWatchCore

final class ProviderUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18))! }

    func testKeychainLookupNeverFallsBackToAnotherAccount() {
        let items = ["cursor": "cursor-secret", "plaid-secret": "plaid-secret"]
        var requests: [(String, String)] = []
        let lookup: (String, String) -> String? = { service, account in
            requests.append((service, account))
            return items[account]
        }
        XCTAssertNil(LocalKeychain.secret(service: "provider-service", account: "openai", lookup: lookup))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, "provider-service")
        XCTAssertEqual(requests.first?.1, "openai")
        XCTAssertEqual(LocalKeychain.secret(service: "provider-service", account: "cursor", lookup: lookup), "cursor-secret")
        XCTAssertNil(LocalKeychain.secret(service: "provider-service", account: "", lookup: lookup))
        XCTAssertEqual(requests.count, 2)
    }

    func testCredentialSessionRejectsRedirects() throws {
        let session = CredentialNetwork.session
        let delegate = try XCTUnwrap(session.delegate as? CredentialRedirectDelegate)
        let source = try XCTUnwrap(URL(string: "https://example.test/usage"))
        let destination = try XCTUnwrap(URL(string: "https://other.example.test/collect"))
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]))
        let completed = expectation(description: "redirect rejected")
        delegate.urlSession(session, task: session.dataTask(with: source), willPerformHTTPRedirection: response, newRequest: URLRequest(url: destination)) { request in
            XCTAssertNil(request)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }

    func testQuotaMathClampsRemaining() {
        let window = QuotaWindow(id: "requests", label: "Requests", used: 120, limit: 500, unit: "requests", resetAt: nil)
        XCTAssertEqual(window.remaining, 380)
        XCTAssertEqual(window.percentRemaining, 76)
        let over = QuotaWindow(id: "over", label: "Over", used: 12, limit: 10, unit: "USD", resetAt: nil)
        XCTAssertEqual(over.remaining, 0)
        XCTAssertEqual(over.percentRemaining, 0)
    }

    func testCursorParsesIncludedCreditsAndRequestCaps() throws {
        let data = Data("""
        {"membershipType":"pro","billingCycleEnd":"2026-11-01T00:00:00Z","gpt-4":{"numRequests":120,"maxRequestUsage":500,"numTokens":1000},"planUsage":{"totalSpend":20,"limit":100,"remaining":80}}
        """.utf8)
        let parsed = ProviderUsageParser.cursor(data, now: now, calendar: calendar)
        XCTAssertEqual(parsed.plan, "pro")
        let included = try XCTUnwrap(parsed.windows.first { $0.id == "plan" })
        XCTAssertEqual(included.remaining, 80)
        XCTAssertEqual(included.unit, "credits")
        let requests = try XCTUnwrap(parsed.windows.first { $0.id == "requests" })
        XCTAssertEqual(requests.remaining, 380)
        XCTAssertEqual(parsed.tokens?.input, 1000)
    }

    func testAnthropicUtilizationAcceptsFractionsAndPercents() throws {
        let data = Data(#"{"five_hour":{"utilization":0.25,"resets_at":"2026-10-14T20:00:00Z"},"seven_day":{"utilization":80,"resets_at":"2026-10-20T00:00:00Z"}}"#.utf8)
        let windows = ProviderUsageParser.anthropicUsage(data)
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(windows[0].remaining, 75)
        XCTAssertEqual(windows[1].remaining, 20)
        XCTAssertEqual(windows[0].resetAt, ProviderUsageParser.dateValue("2026-10-14T20:00:00Z"))
    }

    func testCostsSumStringAndNestedAmounts() {
        let anthropic = Data(#"{"data":[{"results":[{"amount":"1.50","currency":"USD"},{"amount":"2.25","currency":"USD"}]}]}"#.utf8)
        let openai = Data(#"{"data":[{"results":[{"amount":{"value":"3.25","currency":"usd"}}]}]}"#.utf8)
        XCTAssertEqual(ProviderUsageParser.summedCost(anthropic), 3.75)
        XCTAssertEqual(ProviderUsageParser.summedCost(openai), 3.25)
    }

    func testJSONLCountsLeafTokensAndLatestRateLimits() {
        let today = #"{"timestamp":"2026-10-14T12:00:00Z","message":{"usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}}"#
        let older = #"{"timestamp":"2026-09-02T12:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":1}}}"#
        let codex = #"{"timestamp":"2026-10-14T13:00:00Z","payload":{"info":{"total_token_usage":{"input_tokens":7,"output_tokens":3,"cached_input_tokens":1},"last_token_usage":{"input_tokens":99,"output_tokens":99}},"rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":1760000000},"secondary":{"used_percent":10,"window_minutes":10080}}}}"#
        let parsed = ProviderUsageParser.ingest(jsonl: [today, older, codex].joined(separator: "\n"), now: now, fallbackDate: now, calendar: calendar)
        XCTAssertEqual(parsed.today.input, 17)
        XCTAssertEqual(parsed.today.output, 7)
        XCTAssertEqual(parsed.today.cacheRead, 3)
        XCTAssertEqual(parsed.today.cacheWrite, 1)
        XCTAssertEqual(parsed.month.input, 17)
        XCTAssertEqual(parsed.rates.map(\.label), ["5-hour session", "7-day"])
        XCTAssertEqual(parsed.rates[0].percentRemaining, 60)
    }

    func testCursorDatabaseReadsPlainAndQuotedTokens() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Application Support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = try database(in: folder, name: "plain.db", value: "plain-token")
        let quoted = try database(in: folder, name: "quoted.db", value: "\"session-token\"")
        XCTAssertEqual(CursorAuth.accessToken(database: plain), "plain-token")
        XCTAssertEqual(CursorAuth.accessToken(database: quoted), "session-token")
        try? FileManager.default.removeItem(at: folder)
    }

    func testCollectCombinesSpendBudgetLocalRatesAndManualAllowance() async throws {
        let log = #"{"timestamp":"2026-10-14T13:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":1760000000}}}}"#
        let environment = ProviderEnvironment(now: { self.now }, home: URL(fileURLWithPath: "/tmp"), secret: { $0 == "openai" ? "sk-test" : nil }, read: { _ in nil }, fetch: { request in
            guard request.url?.host == "api.openai.com" else { return .failure(ProviderFetchError(status: 500, message: "unexpected")) }
            return .success(Data(#"{"data":[{"results":[{"amount":{"value":"4.50","currency":"usd"}}]}]}"#.utf8))
        }, files: { url in
            url.path.contains(".codex") ? [ProviderLogFile(modified: self.now, text: log)] : []
        })
        var settings = ProviderSettings()
        settings.monthlyBudgetUSD["openai"] = 20
        settings.manual = [ManualAllowance(id: "manual:1", name: "GitHub", used: 10, limit: 50, unit: "requests")]
        let statuses = await ProviderUsageService.collect(settings: settings, environment: environment)
        let openai = try XCTUnwrap(statuses.first { $0.id == "openai" })
        XCTAssertEqual(openai.monthCostUSD, 4.5)
        let budget = try XCTUnwrap(openai.windows.first { $0.id == "budget" })
        XCTAssertEqual(budget.remaining, 15.5)
        XCTAssertEqual(openai.windows.first { $0.id == "primary" }?.percentRemaining, 60)
        let manual = try XCTUnwrap(statuses.first { $0.id == "manual:1" })
        XCTAssertEqual(manual.windows.first?.remaining, 40)
        XCTAssertEqual(statuses.first { $0.id == "cursor" }?.error, "Sign in to Cursor on this Mac. The app and agent CLI share that login.")
    }

    func testDashboardAndCodexParsersReadOAuthQuotas() throws {
        let dashboard = Data(#"{"billingCycleEnd":"1790000000000","planUsage":{"totalPercentUsed":45,"autoPercentUsed":40,"apiPercentUsed":50},"spendLimitUsage":{"individualLimit":5000,"individualRemaining":2500}}"#.utf8)
        let windows = ProviderUsageParser.cursorDashboard(dashboard)
        XCTAssertEqual(windows.map(\.id), ["auto", "api", "spend"])
        XCTAssertEqual(windows.first { $0.id == "auto" }?.label, "In-house")
        XCTAssertEqual(windows.first { $0.id == "auto" }?.remaining, 60)
        XCTAssertEqual(windows.first { $0.id == "api" }?.label, "3rd party")
        XCTAssertEqual(windows.first { $0.id == "api" }?.remaining, 50)
        let spend = try XCTUnwrap(windows.first { $0.id == "spend" })
        XCTAssertEqual(spend.used, 25)
        XCTAssertEqual(spend.limit, 50)
        XCTAssertEqual(ProviderUsageParser.cursorPlanName(Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8)), "Pro")
        let codex = ProviderUsageParser.codexUsage(Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":4,"limit_window_seconds":18000,"reset_at":1792032001},"secondary_window":{"used_percent":22,"limit_window_seconds":604800,"reset_at":1792531403}}}"#.utf8))
        XCTAssertEqual(codex.plan, "plus")
        XCTAssertEqual(codex.windows.map(\.label), ["5-hour session", "7-day"])
        XCTAssertEqual(codex.windows[0].percentRemaining, 96)
        XCTAssertEqual(codex.windows[1].percentRemaining, 78)
    }

    func testOAuthLoginsDriveCursorCodexAndClaude() async throws {
        let dashboard = Data(#"{"planUsage":{"totalPercentUsed":45,"autoPercentUsed":40,"apiPercentUsed":50}}"#.utf8)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pw-oauth-\(UUID().uuidString)", isDirectory: true)
        let folder = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try database(in: folder, name: "state.vscdb", value: "cursor-oauth")
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = Data(#"{"auth_mode":"chatgpt","tokens":{"access_token":"oauth-token","account_id":"acct-1"}}"#.utf8)
        let claude = Data(#"{"oauthAccount":{"billingType":"prepaid"}}"#.utf8)
        let credentials = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-api01-test"}}"#.utf8)
        let environment = ProviderEnvironment(now: { self.now }, home: home, secret: { _ in nil }, read: { url in
            if url.lastPathComponent == "auth.json" { return auth }
            if url.lastPathComponent == ".claude.json" { return claude }
            if url.lastPathComponent == ".credentials.json" { return credentials }
            return nil
        }, fetch: { request in
            if request.url?.path.contains("GetCurrentPeriodUsage") == true { return .success(dashboard) }
            if request.url?.path.contains("GetPlanInfo") == true { return .success(Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8)) }
            if request.url?.host == "chatgpt.com" {
                guard request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1" else { return .failure(ProviderFetchError(status: 500, message: "missing account")) }
                return .success(Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":4,"limit_window_seconds":18000,"reset_at":1792032001}}}"#.utf8))
            }
            return .failure(ProviderFetchError(status: 500, message: "unexpected \(request.url?.host ?? "")"))
        }, files: { _ in [] })
        let statuses = await ProviderUsageService.collect(settings: ProviderSettings(), environment: environment)
        let cursor = try XCTUnwrap(statuses.first { $0.id == "cursor" })
        XCTAssertEqual(cursor.source, "Cursor login")
        XCTAssertEqual(cursor.plan, "Pro")
        XCTAssertEqual(cursor.windows.first { $0.id == "auto" }?.remaining, 60)
        XCTAssertEqual(cursor.windows.first { $0.id == "api" }?.remaining, 50)
        XCTAssertNil(cursor.error)
        let openai = try XCTUnwrap(statuses.first { $0.id == "openai" })
        XCTAssertEqual(openai.source, "ChatGPT login")
        XCTAssertEqual(openai.plan, "plus")
        XCTAssertEqual(openai.windows.first?.percentRemaining, 96)
        let anthropic = try XCTUnwrap(statuses.first { $0.id == "anthropic" })
        XCTAssertEqual(anthropic.source, "Claude login")
        XCTAssertEqual(anthropic.plan, "prepaid")
        XCTAssertEqual(anthropic.error, "This Claude login is an API organization, so Claude does not report a remaining plan window.")
    }

    private func database(in folder: URL, name: String, value: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "CREATE TABLE ItemTable(key TEXT, value TEXT); INSERT INTO ItemTable(key, value) VALUES ('cursorAuth/accessToken', '\(value)');"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return url
    }
}

final class CursorUsageHistoryTests: XCTestCase {
    func testParsesEventsAndPreservesMissingMetrics() throws {
        let data = Data(#"{"totalUsageEventsCount":2,"usageEventsDisplay":[{"timestamp":"1762041600000","model":"Composer","tokenUsage":{"inputTokens":10,"outputTokens":2,"cacheReadTokens":5,"cacheWriteTokens":3},"chargedCents":125},{"timestamp":"1762041700000","model":"Auto"}]}"#.utf8)
        let page = try CursorUsageHistory.parsePage(data)
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.events[0].tokens, 20)
        XCTAssertEqual(page.events[0].costUSD, 1.25)
        XCTAssertNil(page.events[1].tokens)
        XCTAssertNil(page.events[1].costUSD)
    }
    func testRejectsMalformedHistory() {
        XCTAssertThrowsError(try CursorUsageHistory.parsePage(Data(#"{"usageEventsDisplay":[{}],"totalUsageEventsCount":1}"#.utf8)))
    }
    func testWeekAlwaysStartsSundayAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Chicago"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))
        let start = CursorUsageHistory.weekStart(date, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: start), 1)
        XCTAssertEqual(calendar.component(.day, from: start), 1)
        XCTAssertEqual(calendar.component(.hour, from: start), 0)
    }
}
