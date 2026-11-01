import Foundation
import SQLite3
import Security

/// Do not forward credentials or request bodies to redirect destinations.
final class CredentialRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CredentialNetwork {
    static let delegate = CredentialRedirectDelegate()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()
}

public struct QuotaWindow: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var used: Double?
    public var limit: Double?
    public var unit: String
    public var resetAt: Date?
    public var remaining: Double? { guard let used, let limit else { return nil }; return max(0, limit - used) }
    public var percentRemaining: Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return max(0, min(100, (limit - used) / limit * 100))
    }
    public init(id: String, label: String, used: Double?, limit: Double?, unit: String, resetAt: Date?) {
        self.id = id; self.label = label; self.used = used; self.limit = limit; self.unit = unit; self.resetAt = resetAt
    }
}

public struct TokenUsageSummary: Equatable, Sendable {
    public var period: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var costUSD: Double?
    public init(period: String, input: Double, output: Double, cacheRead: Double, cacheWrite: Double, costUSD: Double?) {
        self.period = period; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.costUSD = costUSD
    }
}

public struct ProviderStatus: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var plan: String?
    public var source: String
    public var windows: [QuotaWindow]
    public var tokens: [TokenUsageSummary]
    public var monthCostUSD: Double?
    public var budgetUSD: Double?
    public var updatedAt: Date
    public var error: String?
    /// Tightest remaining window, so a one-line summary shows the limit that will run out first.
    public var headline: QuotaWindow? { windows.min { ($0.percentRemaining ?? 101) < ($1.percentRemaining ?? 101) } }
    /// Rate windows for the menu. Spend caps and monthly budgets stay in the detail view.
    public var rateWindows: [QuotaWindow] {
        let rates = windows.filter { $0.id != "budget" && $0.id != "spend" }
        return rates.isEmpty ? windows.filter { $0.id != "budget" } : rates
    }
    public init(id: String, name: String, plan: String?, source: String, windows: [QuotaWindow], tokens: [TokenUsageSummary], monthCostUSD: Double?, budgetUSD: Double?, updatedAt: Date, error: String?) {
        self.id = id; self.name = name; self.plan = plan; self.source = source; self.windows = windows; self.tokens = tokens
        self.monthCostUSD = monthCostUSD; self.budgetUSD = budgetUSD; self.updatedAt = updatedAt; self.error = error
    }
    public static func checking(_ id: String, _ name: String) -> ProviderStatus {
        ProviderStatus(id: id, name: name, plan: nil, source: "Checking…", windows: [], tokens: [], monthCostUSD: nil, budgetUSD: nil, updatedAt: Date(), error: nil)
    }
}

public struct ManualAllowance: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var used: Double
    public var limit: Double
    public var unit: String
    public init(id: String, name: String, used: Double, limit: Double, unit: String) {
        self.id = id; self.name = name; self.used = used; self.limit = limit; self.unit = unit
    }
}

public struct ProviderSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "ai.powerwatch.providerSettings"
    public var monthlyBudgetUSD: [String: Double]
    public var manual: [ManualAllowance]
    public init(monthlyBudgetUSD: [String: Double] = [:], manual: [ManualAllowance] = []) {
        self.monthlyBudgetUSD = monthlyBudgetUSD; self.manual = manual
    }
}

public struct ProviderLogFile: Sendable {
    public var modified: Date
    public var text: String
    public init(modified: Date, text: String) { self.modified = modified; self.text = text }
}

public struct ProviderFetchError: Error, Sendable {
    public var status: Int
    public var message: String
    public init(status: Int, message: String) { self.status = status; self.message = message }
}

public struct ProviderEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var home: URL
    public var secret: @Sendable (String) -> String?
    public var read: @Sendable (URL) -> Data?
    public var fetch: @Sendable (URLRequest) async -> Result<Data, ProviderFetchError>
    public var files: @Sendable (URL) -> [ProviderLogFile]
    public init(now: @escaping @Sendable () -> Date, home: URL, secret: @escaping @Sendable (String) -> String?, read: @escaping @Sendable (URL) -> Data?, fetch: @escaping @Sendable (URLRequest) async -> Result<Data, ProviderFetchError>, files: @escaping @Sendable (URL) -> [ProviderLogFile]) {
        self.now = now; self.home = home; self.secret = secret; self.read = read; self.fetch = fetch; self.files = files
    }
    public static let live = ProviderEnvironment(
        now: { Date() },
        home: FileManager.default.homeDirectoryForCurrentUser,
        secret: { KeychainSecretStore().secret(account: $0) },
        read: { try? Data(contentsOf: $0) },
        fetch: { request in
            do {
                let (data, response) = try await CredentialNetwork.session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    let rejected = code == 401 || code == 403
                    return .failure(ProviderFetchError(status: code, message: rejected ? "The login was rejected." : "Usage request failed (\(code))."))
                }
                return .success(data)
            } catch { return .failure(ProviderFetchError(status: -1, message: "Could not reach the provider.")) }
        },
        files: { ProviderUsageService.logs(under: $0) }
    )
}

enum LocalKeychain {
    static func secret(service: String, account: String, lookup: (String, String) -> String? = copy) -> String? {
        guard !account.isEmpty else { return nil }
        return lookup(service, account)
    }
    private static func copy(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

public struct KeychainSecretStore: Sendable {
    public var service: String
    public init(service: String = "ai.powerwatch.providers") { self.service = service }
    public func secret(account: String) -> String? { LocalKeychain.secret(service: service, account: account) }
    public func setSecret(_ value: String?, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: "PowerWatch.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not store the provider secret in Keychain."]) }
    }
}

public enum CursorAuth {
    /// Read Cursor's local session without writing its database. A saved YooTrack token wins at the call site.
    public static func accessToken(database: URL) -> String? {
        var db: OpaquePointer?
        let encoded = database.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database.path
        if sqlite3_open_v2("file:" + encoded + "?mode=ro&immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            sqlite3_close(db); db = nil
            guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        }
        guard let db else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { return nil }
        var token = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(token.utf8)) { token = decoded }
        return token.isEmpty ? nil : token
    }
}

struct UsageTotals: Equatable {
    var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0, cost = 0.0, costKnown = false
    mutating func add(_ other: UsageTotals) {
        input += other.input; output += other.output; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite; cost += other.cost; costKnown = costKnown || other.costKnown
    }
    func summary(_ period: String) -> TokenUsageSummary? {
        guard input + output + cacheRead + cacheWrite > 0 || costKnown else { return nil }
        return TokenUsageSummary(period: period, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, costUSD: costKnown ? cost : nil)
    }
}

public enum ProviderUsageParser {
    public static func cursor(_ data: Data, now: Date = Date(), calendar: Calendar = .current) -> (plan: String?, windows: [QuotaWindow], tokens: TokenUsageSummary?) {
        guard let root = jsonObject(data) else { return (nil, [], nil) }
        var windows: [QuotaWindow] = []
        let cycleEnd = dateValue(root["billingCycleEnd"]) ?? nextMonth(dateValue(root["startOfMonth"]) ?? now, calendar: calendar)
        if let plan = dictionary(root["planUsage"]) ?? dictionary(root["plan_usage"]) {
            let limit = number(plan["limit"]) ?? number(plan["includedSpend"])
            let remaining = number(plan["remaining"])
            let used = number(plan["totalSpend"]) ?? limit.flatMap { lim in remaining.map { lim - $0 } }
            if let limit, let used { windows.append(QuotaWindow(id: "plan", label: "Included", used: used, limit: limit, unit: "credits", resetAt: cycleEnd)) }
            else if let percent = number(plan["totalPercentUsed"]) ?? number(plan["autoPercentUsed"]) {
                windows.append(QuotaWindow(id: "plan", label: "Included", used: percent, limit: 100, unit: "%", resetAt: cycleEnd))
            }
        }
        var requestUsed = 0.0, requestLimit = 0.0, tokens = 0.0, capped = false
        for (key, value) in root {
            guard key != "planUsage" && key != "plan_usage", let model = value as? [String: Any] else { continue }
            tokens += number(model["numTokens"]) ?? 0
            if let max = number(model["maxRequestUsage"]) {
                capped = true; requestLimit += max; requestUsed += number(model["numRequests"]) ?? number(model["numRequestsTotal"]) ?? 0
            }
        }
        if capped { windows.append(QuotaWindow(id: "requests", label: "Requests", used: requestUsed, limit: requestLimit, unit: "requests", resetAt: cycleEnd)) }
        let plan = (root["membershipType"] as? String) ?? (root["membership_type"] as? String)
        return (plan, windows, tokens > 0 ? TokenUsageSummary(period: "Month", input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, costUSD: nil) : nil)
    }

    /// Current Cursor dashboard quota. Percents are the plan windows; spend values are cents.
    public static func cursorDashboard(_ data: Data) -> [QuotaWindow] {
        guard let root = jsonObject(data) else { return [] }
        let cycle = dateValue(root["billingCycleEnd"])
        var windows: [QuotaWindow] = []
        if let plan = dictionary(root["planUsage"]) {
            for (id, label, key) in [("auto", "In-house", "autoPercentUsed"), ("api", "3rd party", "apiPercentUsed")] {
                if let used = number(plan[key]) { windows.append(QuotaWindow(id: id, label: label, used: used, limit: 100, unit: "%", resetAt: cycle)) }
            }
        }
        if let spend = dictionary(root["spendLimitUsage"]), let limit = number(spend["individualLimit"]), limit > 0 {
            let remaining = number(spend["individualRemaining"]) ?? 0
            windows.append(QuotaWindow(id: "spend", label: "Spend limit", used: max(0, limit - remaining) / 100, limit: limit / 100, unit: "USD", resetAt: cycle))
        }
        return windows
    }

    public static func cursorPlanName(_ data: Data) -> String? {
        guard let name = dictionary(dictionary(jsonObject(data))?["planInfo"])?["planName"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// ChatGPT OAuth quota used by Codex. `used_percent` is amount consumed.
    public static func codexUsage(_ data: Data) -> (plan: String?, windows: [QuotaWindow]) {
        guard let root = jsonObject(data), let limits = dictionary(root["rate_limit"]) else { return (nil, []) }
        var windows: [QuotaWindow] = []
        for (id, fallback) in [("primary_window", "Session"), ("secondary_window", "Weekly")] {
            guard let raw = dictionary(limits[id]), let used = number(raw["used_percent"]) else { continue }
            let seconds = number(raw["limit_window_seconds"])
            let label = seconds.map { abs($0 - 18000) < 1 ? "5-hour session" : abs($0 - 604800) < 1 ? "7-day" : fallback } ?? fallback
            windows.append(QuotaWindow(id: id, label: label, used: used, limit: 100, unit: "%", resetAt: dateValue(raw["reset_at"])))
        }
        return (root["plan_type"] as? String, windows)
    }

    public static func anthropicUsage(_ data: Data) -> [QuotaWindow] {
        guard let root = jsonObject(data) else { return [] }
        let payload = dictionary(root["usage"]) ?? root
        let labels = ["five_hour": "5-hour session", "seven_day": "7-day", "seven_day_opus": "7-day Opus", "seven_day_sonnet": "7-day Sonnet"]
        let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]
        let windows = payload.compactMap { key, value -> QuotaWindow? in
            guard let item = value as? [String: Any], let raw = number(item["utilization"]) else { return nil }
            return QuotaWindow(id: key, label: labels[key] ?? key.replacingOccurrences(of: "_", with: " "), used: raw <= 1 ? raw * 100 : raw, limit: 100, unit: "%", resetAt: dateValue(item["resets_at"]))
        }
        return windows.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }

    public static func summedCost(_ data: Data) -> Double? {
        guard let root = jsonObject(data) else { return nil }
        var total = 0.0, found = false
        func visit(_ value: Any) {
            if let rows = value as? [Any] { rows.forEach(visit); return }
            guard let dict = value as? [String: Any] else { return }
            if let amount = dict["amount"] {
                if let value = number(amount) { total += value; found = true }
                else if let nested = dictionary(amount), let value = number(nested["value"]) { total += value; found = true }
            }
            for (key, child) in dict where key != "amount" { visit(child) }
        }
        visit(root)
        return found ? total : nil
    }

    static func ingest(jsonl: String, now: Date, fallbackDate: Date, calendar: Calendar = .current) -> (today: UsageTotals, month: UsageTotals, rates: [QuotaWindow]) {
        var today = UsageTotals(), month = UsageTotals(), rates: [QuotaWindow] = []
        let dayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart
        for line in jsonl.split(separator: "\n") {
            guard let root = jsonObject(Data(line.utf8)) else { continue }
            let stamp = dateValue(root["timestamp"]) ?? fallbackDate
            var piece = UsageTotals()
            var lineRates: [QuotaWindow] = []
            consume(root, into: &piece, rates: &lineRates)
            if stamp >= monthStart { month.add(piece) }
            if stamp >= dayStart { today.add(piece) }
            if !lineRates.isEmpty { rates = lineRates }
        }
        return (today, month, rates)
    }

    static func jsonObject(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func number(_ value: Any?) -> Double? {
        // JSON booleans are CFBooleans. A plain 0 or 1 must still count as a number.
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        if let text = value as? String { return Double(text) }
        return nil
    }
    static func dateValue(_ value: Any?) -> Date? {
        if let number = number(value), number > 1_000_000 { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let day = ISO8601DateFormatter(); day.formatOptions = [.withFullDate]
        return day.date(from: text)
    }
    static func nextMonth(_ date: Date, calendar: Calendar) -> Date? {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .month, value: 1, to: start)
    }

    private static func consume(_ value: Any, into totals: inout UsageTotals, rates: inout [QuotaWindow]) {
        if let rows = value as? [Any] { rows.forEach { consume($0, into: &totals, rates: &rates) }; return }
        guard let dict = value as? [String: Any] else { return }
        captureRates(dict, into: &rates)
        if let total = dict["total_token_usage"] as? [String: Any] {
            addUsage(total, into: &totals)
            for (key, child) in dict where key != "total_token_usage" && key != "last_token_usage" { consume(child, into: &totals, rates: &rates) }
            return
        }
        if isLeafUsage(dict) { addUsage(dict, into: &totals); return }
        dict.values.forEach { consume($0, into: &totals, rates: &rates) }
    }
    private static func isLeafUsage(_ dict: [String: Any]) -> Bool {
        guard dict["input_tokens"] != nil || dict["output_tokens"] != nil else { return false }
        return !dict.values.contains { value in
            guard let child = value as? [String: Any] else { return false }
            return child["input_tokens"] != nil || child["output_tokens"] != nil
        }
    }
    private static func addUsage(_ dict: [String: Any], into totals: inout UsageTotals) {
        totals.input += number(dict["input_tokens"]) ?? 0
        totals.output += number(dict["output_tokens"]) ?? 0
        totals.cacheRead += number(dict["cache_read_input_tokens"]) ?? number(dict["cached_input_tokens"]) ?? 0
        totals.cacheWrite += number(dict["cache_creation_input_tokens"]) ?? 0
        if let cost = number(dict["costUSD"]) ?? number(dict["cost_usd"]) { totals.cost += cost; totals.costKnown = true }
    }
    private static func captureRates(_ dict: [String: Any], into rates: inout [QuotaWindow]) {
        let source = (dict["rate_limits"] as? [String: Any]) ?? dict
        var windows: [QuotaWindow] = []
        if let primary = source["primary"] as? [String: Any], let used = number(primary["used_percent"]) {
            windows.append(rateWindow(id: "primary", fallback: "Session", used: used, raw: primary))
        }
        if let secondary = source["secondary"] as? [String: Any], let used = number(secondary["used_percent"]) {
            windows.append(rateWindow(id: "secondary", fallback: "Weekly", used: used, raw: secondary))
        }
        if !windows.isEmpty { rates = windows }
    }
    private static func rateWindow(id: String, fallback: String, used: Double, raw: [String: Any]) -> QuotaWindow {
        let minutes = number(raw["window_minutes"])
        let label: String
        if let minutes, abs(minutes - 300) < 1 { label = "5-hour session" }
        else if let minutes, abs(minutes - 10080) < 1 { label = "7-day" }
        else { label = fallback }
        return QuotaWindow(id: id, label: label, used: used, limit: 100, unit: "%", resetAt: dateValue(raw["resets_at"]))
    }
}

public enum ProviderUsageService {
    public static func collect(settings: ProviderSettings, environment: ProviderEnvironment = .live) async -> [ProviderStatus] {
        async let cursor = cursor(settings, environment)
        async let anthropic = anthropic(settings, environment)
        async let openai = openai(settings, environment)
        let manuals = settings.manual.map { manual($0, now: environment.now()) }
        return await [cursor, anthropic, openai] + manuals
    }

    public static func manual(_ allowance: ManualAllowance, now: Date) -> ProviderStatus {
        ProviderStatus(id: allowance.id, name: allowance.name, plan: "Manual", source: "Manual", windows: [QuotaWindow(id: "manual", label: "Allowance", used: allowance.used, limit: allowance.limit, unit: allowance.unit, resetAt: nil)], tokens: [], monthCostUSD: allowance.unit == "USD" ? allowance.used : nil, budgetUSD: allowance.unit == "USD" ? allowance.limit : nil, updatedAt: now, error: nil)
    }

    static func logs(under root: URL) -> [ProviderLogFile] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [(URL, Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "json" || url.pathExtension == "jsonl" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            found.append((url, modified))
            if found.count >= 300 { break }
        }
        return found.sorted { $0.1 < $1.1 }.suffix(12).compactMap { item in
            guard let text = tail(item.0) else { return nil }
            return ProviderLogFile(modified: item.1, text: text)
        }
    }

    static func cursor(_ settings: ProviderSettings, _ environment: ProviderEnvironment) async -> ProviderStatus {
        let now = environment.now()
        let logins = cursorLogins(environment)
        var status = base("cursor", "Cursor", source: logins.first?.source ?? "Not connected", budget: settings, now: now)
        guard !logins.isEmpty else { status.error = "Sign in to Cursor on this Mac. The app and agent CLI share that login."; return status }
        var lastError: String?
        for login in logins {
            status.source = login.source
            switch await environment.fetch(postJSON(URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!, bearer: login.token)) {
            case .success(let data):
                status.windows = ProviderUsageParser.cursorDashboard(data)
                if case .success(let planData) = await environment.fetch(postJSON(URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!, bearer: login.token)) {
                    status.plan = ProviderUsageParser.cursorPlanName(planData)
                }
                if status.windows.isEmpty {
                    switch await environment.fetch(authorized(URL(string: "https://api2.cursor.sh/auth/usage")!, bearer: login.token)) {
                    case .success(let legacy):
                        let parsed = ProviderUsageParser.cursor(legacy, now: now)
                        status.plan = parsed.plan ?? status.plan
                        status.windows = parsed.windows
                        if let tokens = parsed.tokens { status.tokens = [tokens] }
                    case .failure(let error): lastError = error.message
                    }
                }
                if !status.windows.isEmpty { status.error = nil; return status }
                lastError = lastError ?? "Cursor responded without a readable quota."
            case .failure(let error):
                lastError = error.message
                if error.status != 401 && error.status != 403 { status.error = error.message; return status }
            }
        }
        status.error = lastError
        return status
    }

    static func anthropic(_ settings: ProviderSettings, _ environment: ProviderEnvironment) async -> ProviderStatus {
        let now = environment.now()
        let login = claudeToken(environment.read(environment.home.appendingPathComponent(".claude/.credentials.json")))
        let saved = cleaned(environment.secret("anthropic"))
        let billing = claudeBilling(environment)
        let source = login != nil || billing != nil ? "Claude login" : (saved == nil ? "Not connected" : (saved!.hasPrefix("sk-ant-") ? "API key" : "Saved token"))
        var status = base("anthropic", "Anthropic", source: source, budget: settings, now: now)
        status.plan = billing
        let local = logs(environment, ".claude/projects", now: now)
        status.tokens = summaries(local)
        status.windows = local.rates
        var reported = false
        if let login { reported = await applyClaude(&status, token: login, now: now, environment: environment) }
        if !reported, let saved, saved != login { reported = await applyClaude(&status, token: saved, now: now, environment: environment) || reported }
        if !reported && login == nil && saved == nil {
            if billing != nil { status.error = "Claude is signed in, but its usage token could not be read." }
            else if status.tokens.isEmpty && status.windows.isEmpty { status.error = "Sign in to Claude Code on this Mac." }
            else { status.source = "Local logs" }
        }
        attachBudget(&status, settings, now: now)
        return status
    }

    static func openai(_ settings: ProviderSettings, _ environment: ProviderEnvironment) async -> ProviderStatus {
        let now = environment.now()
        let login = codexLogin(environment.read(environment.home.appendingPathComponent(".codex/auth.json")))
        let saved = cleaned(environment.secret("openai"))
        var status = base("openai", "OpenAI", source: login != nil ? "ChatGPT login" : (saved == nil ? "Not connected" : "API key"), budget: settings, now: now)
        let local = logs(environment, ".codex/sessions", now: now)
        status.tokens = summaries(local)
        status.windows = local.rates
        var reported = false
        if let login {
            var request = authorized(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, bearer: login.access)
            if let account = login.account { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            switch await environment.fetch(request) {
            case .success(let data):
                let parsed = ProviderUsageParser.codexUsage(data)
                status.plan = parsed.plan
                if !parsed.windows.isEmpty { status.windows = parsed.windows; status.error = nil; reported = true }
            case .failure(let error):
                status.error = status.windows.isEmpty && status.tokens.isEmpty ? error.message : error.message + " Showing local logs."
            }
        }
        if !reported, let saved {
            var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
            components.queryItems = [URLQueryItem(name: "start_time", value: String(Int(monthStart(now).timeIntervalSince1970))), URLQueryItem(name: "bucket_width", value: "1d"), URLQueryItem(name: "limit", value: "31")]
            switch await environment.fetch(authorized(components.url!, bearer: saved)) {
            case .success(let data): if let cost = ProviderUsageParser.summedCost(data) { status.monthCostUSD = cost; status.error = nil; reported = true }
            case .failure(let error): status.error = status.windows.isEmpty && status.tokens.isEmpty ? error.message : error.message + " Showing local logs."
            }
        }
        if !reported && login == nil && saved == nil {
            if status.windows.isEmpty && status.tokens.isEmpty { status.error = "Sign in to Codex on this Mac, or save an OpenAI admin key." }
            else { status.source = "Local logs" }
        }
        attachBudget(&status, settings, now: now)
        return status
    }

    private static func base(_ id: String, _ name: String, source: String, budget: ProviderSettings, now: Date) -> ProviderStatus {
        ProviderStatus(id: id, name: name, plan: nil, source: source, windows: [], tokens: [], monthCostUSD: nil, budgetUSD: budget.monthlyBudgetUSD[id], updatedAt: now, error: nil)
    }
    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
    private static func cursorLogins(_ environment: ProviderEnvironment) -> [(token: String, source: String)] {
        var seen = Set<String>()
        var logins: [(String, String)] = []
        func add(_ token: String?, _ source: String) {
            guard let token = cleaned(token), seen.insert(token).inserted else { return }
            logins.append((token, source))
        }
        add(CursorAuth.accessToken(database: environment.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")), "Cursor login")
        add(environment.secret("cursor"), "Saved token")
        return logins
    }
    /// Returns true when the credential produced a plan window or a monthly cost.
    private static func applyClaude(_ status: inout ProviderStatus, token: String, now: Date, environment: ProviderEnvironment) async -> Bool {
        if token.hasPrefix("sk-ant-admin") {
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
            components.queryItems = [URLQueryItem(name: "starting_at", value: iso(monthStart(now))), URLQueryItem(name: "ending_at", value: iso(now)), URLQueryItem(name: "bucket_width", value: "1d")]
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            switch await environment.fetch(request) {
            case .success(let data):
                if let cost = ProviderUsageParser.summedCost(data) { status.monthCostUSD = cost; status.error = nil; return true }
            case .failure(let error):
                if status.error == nil { status.error = status.tokens.isEmpty && status.windows.isEmpty ? error.message : error.message + " Showing local logs." }
            }
            return false
        }
        if token.hasPrefix("sk-ant-api") {
            status.source = "Claude login"
            status.error = "This Claude login is an API organization, so Claude does not report a remaining plan window."
            return false
        }
        if token.hasPrefix("sk-ant-") && !token.hasPrefix("sk-ant-oat") {
            if status.error == nil && status.tokens.isEmpty && status.windows.isEmpty { status.error = "A regular API key cannot report remaining quota. Save an admin key or sign in to Claude Code." }
            return false
        }
        var request = authorized(URL(string: "https://api.anthropic.com/api/oauth/usage")!, bearer: token)
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        switch await environment.fetch(request) {
        case .success(let data):
            let remote = ProviderUsageParser.anthropicUsage(data)
            if !remote.isEmpty { status.windows = remote; status.error = nil; return true }
        case .failure(let error):
            status.error = status.windows.isEmpty && status.tokens.isEmpty ? error.message : error.message + " Showing local logs."
        }
        return false
    }
    private static func claudeBilling(_ environment: ProviderEnvironment) -> String? {
        guard let data = environment.read(environment.home.appendingPathComponent(".claude.json")),
              let account = ProviderUsageParser.dictionary(ProviderUsageParser.jsonObject(data)?["oauthAccount"]),
              let billing = account["billingType"] as? String, !billing.isEmpty else { return nil }
        return billing
    }
    private static func claudeToken(_ data: Data?) -> String? {
        guard let data, let root = ProviderUsageParser.jsonObject(data) else { return nil }
        let oauth = ProviderUsageParser.dictionary(root["claudeAiOauth"]) ?? root
        return cleaned((oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String))
    }
    private static func codexLogin(_ data: Data?) -> (access: String, account: String?)? {
        guard let data, let root = ProviderUsageParser.jsonObject(data) else { return nil }
        let tokens = ProviderUsageParser.dictionary(root["tokens"]) ?? [:]
        guard let access = cleaned((tokens["access_token"] as? String) ?? (root["access_token"] as? String)) else { return nil }
        return (access, cleaned((tokens["account_id"] as? String) ?? (root["account_id"] as? String)))
    }
    private static func logs(_ environment: ProviderEnvironment, _ relative: String, now: Date) -> (today: UsageTotals, month: UsageTotals, rates: [QuotaWindow]) {
        var today = UsageTotals(), month = UsageTotals(), rates: [QuotaWindow] = []
        for file in environment.files(environment.home.appendingPathComponent(relative)).sorted(by: { $0.modified < $1.modified }).suffix(12) {
            let parsed = ProviderUsageParser.ingest(jsonl: file.text, now: now, fallbackDate: file.modified)
            today.add(parsed.today); month.add(parsed.month)
            if !parsed.rates.isEmpty { rates = parsed.rates }
        }
        return (today, month, rates)
    }
    private static func summaries(_ local: (today: UsageTotals, month: UsageTotals, rates: [QuotaWindow])) -> [TokenUsageSummary] {
        [local.today.summary("Today"), local.month.summary("This month")].compactMap { $0 }
    }
    private static func attachBudget(_ status: inout ProviderStatus, _ settings: ProviderSettings, now: Date) {
        guard let budget = settings.monthlyBudgetUSD[status.id], budget > 0, let used = status.monthCostUSD else { return }
        status.windows.append(QuotaWindow(id: "budget", label: "Monthly budget", used: used, limit: budget, unit: "USD", resetAt: ProviderUsageParser.nextMonth(now, calendar: .current)))
    }
    private static func monthStart(_ date: Date) -> Date { Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: date)) ?? date }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func authorized(_ url: URL, bearer: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("PowerWatch", forHTTPHeaderField: "User-Agent")
        return request
    }
    private static func postJSON(_ url: URL, bearer: String) -> URLRequest {
        var request = authorized(url, bearer: bearer)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return request
    }
    private static func tail(_ url: URL, maxBytes: Int = 131_072) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
            let data = try handle.readToEnd() ?? Data()
            var text = String(data: data, encoding: .utf8) ?? ""
            if size > UInt64(maxBytes), let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            return text
        } catch { return nil }
    }
}

/// A dashboard usage event. Missing values stay missing rather than being treated as zero.
public struct CursorUsageEvent: Equatable, Sendable {
    public let date: Date
    public let model: String
    public let tokens: Double?
    /// Cursor's event-level charged cost in USD; this is not necessarily an out-of-pocket charge.
    public let costUSD: Double?
}

public enum CursorUsageHistory {
    public static func weekStart(_ date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -(calendar.component(.weekday, from: day) - 1), to: day) ?? day
    }

    public static func parsePage(_ data: Data) throws -> (events: [CursorUsageEvent], count: Int) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["usageEventsDisplay"] as? [[String: Any]],
              let count = (root["totalUsageEventsCount"] as? NSNumber)?.intValue, count >= 0 else {
            throw ProviderFetchError(status: 0, message: "Cursor returned an unreadable usage history.")
        }
        let events = try rows.map { row -> CursorUsageEvent in
            guard let rawDate = row["timestamp"], let milliseconds = Double(String(describing: rawDate)), milliseconds.isFinite,
                  let model = row["model"] as? String, !model.isEmpty else {
                throw ProviderFetchError(status: 0, message: "Cursor returned an incomplete usage event.")
            }
            let usage = row["tokenUsage"] as? [String: Any]
            let names = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
            let values = names.compactMap { (usage?[$0] as? NSNumber)?.doubleValue }
            let tokens: Double? = values.isEmpty ? nil : values.reduce(0, +)
            let cents = (row["chargedCents"] as? NSNumber)?.doubleValue
            return CursorUsageEvent(date: Date(timeIntervalSince1970: milliseconds / 1000), model: model, tokens: tokens, costUSD: cents.map { $0 / 100 })
        }
        return (events, count)
    }

    public static func load(start: Date, end: Date, environment: ProviderEnvironment = .live) async throws -> [CursorUsageEvent] {
        guard let token = CursorAuth.accessToken(database: environment.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")) else {
            throw ProviderFetchError(status: 0, message: "Sign in to Cursor on this Mac to see usage history.")
        }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { throw ProviderFetchError(status: 0, message: "Cursor's session cannot open usage history.") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var subject = object["sub"] as? String else { throw ProviderFetchError(status: 0, message: "Cursor's session cannot open usage history.") }
        if subject.hasPrefix("auth0|") { subject = String(subject.dropFirst(6)) }
        guard let cookie = (subject + "::" + token).addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw ProviderFetchError(status: 0, message: "Cursor's session cannot open usage history.") }
        var all: [CursorUsageEvent] = []
        let pageSize = 100
        for page in 1...100 {
            var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("WorkosCursorSessionToken=" + cookie, forHTTPHeaderField: "Cookie")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["startDate": String(Int64(start.timeIntervalSince1970 * 1000)), "endDate": String(Int64(end.timeIntervalSince1970 * 1000) - 1), "page": page, "pageSize": pageSize])
            switch await environment.fetch(request) {
            case .failure(let error): throw error
            case .success(let data):
                let result = try parsePage(data)
                all.append(contentsOf: result.events)
                if all.count >= result.count { return all.filter { $0.date >= start && $0.date < end } }
                if result.events.isEmpty { throw ProviderFetchError(status: 0, message: "Cursor returned an incomplete usage history.") }
            }
        }
        throw ProviderFetchError(status: 0, message: "This week has too many events to display completely.")
    }
}
