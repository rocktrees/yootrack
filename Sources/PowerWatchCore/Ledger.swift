import Foundation
import SQLite3

public enum LedgerCategory {
    public static let all = ["Groceries", "Dining", "Transport", "Housing", "Utilities", "Health", "Shopping", "Entertainment", "Income", "Transfer", "Investment", "Other"]
    /// Apply a guess only at or above this confidence. The same gate Sure uses for Jev.
    public static let minimumConfidence = 0.7
}

public struct CategoryGuess: Equatable, Sendable {
    public var category: String
    public var confidence: Double
    public var source: String
    public init(category: String, confidence: Double, source: String) {
        self.category = category; self.confidence = confidence; self.source = source
    }
    public var applies: Bool { LedgerCategory.all.contains(category) && confidence >= LedgerCategory.minimumConfidence }
}

public enum LocalCategorizer {
    private static let rules: [(String, [String])] = [
        ("Groceries", ["kroger", "whole foods", "trader joe", "safeway", "aldi", "grocery", "publix", "heb", "costco", "wegmans"]),
        ("Dining", ["starbucks", "mcdonald", "restaurant", "doordash", "uber eats", "chipotle", "cafe", "coffee", "grubhub"]),
        ("Transport", ["uber", "lyft", "shell", "chevron", "exxon", "parking", "transit", "metro"]),
        ("Housing", ["rent", "mortgage", "apartment", "landlord"]),
        ("Utilities", ["electric", "utility", "water bill", "internet", "comcast", "verizon", "at&t"]),
        ("Health", ["pharmacy", "cvs", "walgreens", "clinic", "dental", "hospital"]),
        ("Shopping", ["amazon", "target", "walmart", "etsy", "best buy"]),
        ("Entertainment", ["netflix", "spotify", "hulu", "steam", "cinema", "movie"]),
        ("Income", ["payroll", "direct dep", "salary", "paycheck"]),
        ("Transfer", ["transfer", "venmo", "zelle", "payment thank"]),
        ("Investment", ["brokerage", "dividend", "vanguard", "fidelity", "schwab"])
    ]
    public static func key(_ payee: String) -> String {
        let folded = payee.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
        return folded.split(separator: " ").prefix(4).joined(separator: " ")
    }
    /// Memory from a correction wins. Keyword rules are the fast private fallback. Nothing leaves the Mac.
    public static func guess(payee: String, memory: [String: String] = [:]) -> CategoryGuess? {
        let normalized = key(payee)
        guard !normalized.isEmpty else { return nil }
        if let category = memory[normalized] ?? memory.first(where: { normalized.hasPrefix($0.key + " ") && $0.key.count >= 4 })?.value {
            return CategoryGuess(category: category, confidence: 0.99, source: "memory")
        }
        let haystack = payee.lowercased()
        for (category, words) in rules where words.contains(where: { haystack.contains($0) }) {
            return CategoryGuess(category: category, confidence: 0.85, source: "rule")
        }
        return nil
    }
    public static func fromPlaid(primary: String?, detailed: String?) -> CategoryGuess? {
        let detailed = detailed?.uppercased() ?? ""
        if detailed.contains("GROCER") { return CategoryGuess(category: "Groceries", confidence: 0.75, source: "plaid") }
        switch primary?.uppercased() {
        case "FOOD_AND_DRINK": return CategoryGuess(category: "Dining", confidence: 0.75, source: "plaid")
        case "TRANSPORTATION": return CategoryGuess(category: "Transport", confidence: 0.75, source: "plaid")
        case "RENT_AND_UTILITIES": return CategoryGuess(category: "Utilities", confidence: 0.75, source: "plaid")
        case "HOME_IMPROVEMENT", "LOAN_PAYMENTS": return CategoryGuess(category: "Housing", confidence: 0.75, source: "plaid")
        case "MEDICAL": return CategoryGuess(category: "Health", confidence: 0.75, source: "plaid")
        case "GENERAL_MERCHANDISE": return CategoryGuess(category: "Shopping", confidence: 0.75, source: "plaid")
        case "ENTERTAINMENT": return CategoryGuess(category: "Entertainment", confidence: 0.75, source: "plaid")
        case "INCOME": return CategoryGuess(category: "Income", confidence: 0.75, source: "plaid")
        case "TRANSFER_IN", "TRANSFER_OUT": return CategoryGuess(category: "Transfer", confidence: 0.75, source: "plaid")
        default: return nil
        }
    }
}

public enum MoneyMath {
    public static func cents(from text: String) -> Int? {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        guard let decimal = Decimal(string: cleaned), decimal >= 0, decimal < 100_000_000 else { return nil }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return (rounded as NSDecimalNumber).intValue
    }
    public static func dollars(_ cents: Int) -> String { String(format: "%@%.2f", cents < 0 ? "−" : "", Double(abs(cents)) / 100) }
    /// Plaid amounts are positive when money leaves the account. Stored cents use the opposite sign.
    public static func cents(fromPlaidAmount amount: Double) -> Int {
        var scaled = Decimal(amount) * -100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return (rounded as NSDecimalNumber).intValue
    }
    public static func cents(fromValue amount: Double) -> Int {
        var scaled = Decimal(amount) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return (rounded as NSDecimalNumber).intValue
    }
}

public struct LedgerEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var posted: Date
    public var payee: String
    public var cents: Int
    public var category: String?
    public var confidence: Double?
    public var source: String
    public var pending: Bool
    public var accountMask: String?
    public init(id: String, posted: Date, payee: String, cents: Int, category: String?, confidence: Double?, source: String, pending: Bool, accountMask: String?) {
        self.id = id; self.posted = posted; self.payee = payee; self.cents = cents; self.category = category
        self.confidence = confidence; self.source = source; self.pending = pending; self.accountMask = accountMask
    }
}

public struct BudgetRow: Identifiable, Equatable, Sendable {
    public var category: String
    public var spentCents: Int
    public var limitCents: Int
    public var id: String { category }
    public var remainingCents: Int { limitCents - spentCents }
    public init(category: String, spentCents: Int, limitCents: Int) {
        self.category = category; self.spentCents = spentCents; self.limitCents = limitCents
    }
}

public struct Holding: Identifiable, Equatable, Sendable {
    public var symbol: String
    public var name: String
    public var valueCents: Int
    public var id: String { symbol + name }
    public init(symbol: String, name: String, valueCents: Int) { self.symbol = symbol; self.name = name; self.valueCents = valueCents }
}

public struct PortfolioPoint: Identifiable, Equatable, Sendable {
    public var day: String
    public var valueCents: Int
    public var id: String { day }
    public init(day: String, valueCents: Int) { self.day = day; self.valueCents = valueCents }
}

public struct PlaidSyncChange: Equatable, Sendable {
    public var added: [LedgerEntry]
    public var modified: [LedgerEntry]
    public var removedIDs: [String]
    public var nextCursor: String
    public var hasMore: Bool
    public init(added: [LedgerEntry], modified: [LedgerEntry], removedIDs: [String], nextCursor: String, hasMore: Bool) {
        self.added = added; self.modified = modified; self.removedIDs = removedIDs; self.nextCursor = nextCursor; self.hasMore = hasMore
    }
}

/// Money stays in this file. Access tokens never do.
public final class LedgerStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw error() }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS entries(id TEXT PRIMARY KEY, posted REAL NOT NULL, payee TEXT NOT NULL, cents INTEGER NOT NULL, category TEXT, confidence REAL, source TEXT NOT NULL, plaid_id TEXT UNIQUE, account_mask TEXT, pending INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS merchant_rules(payee_key TEXT PRIMARY KEY, category TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS budgets(category TEXT PRIMARY KEY, monthly_cents INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS plaid_items(item_id TEXT PRIMARY KEY, institution TEXT, cursor TEXT, environment TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS holdings(item_id TEXT NOT NULL, symbol TEXT NOT NULL, name TEXT NOT NULL, value_cents INTEGER NOT NULL, PRIMARY KEY(item_id, symbol));
        CREATE TABLE IF NOT EXISTS portfolio_days(day TEXT PRIMARY KEY, value_cents INTEGER NOT NULL);
        """)
        tighten()
    }
    public func entries(limit: Int = 200) throws -> [LedgerEntry] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT id,posted,payee,cents,category,confidence,source,pending,account_mask FROM entries ORDER BY posted DESC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        return readEntries(statement)
    }
    public func add(payee: String, cents: Int, category: String?, posted: Date = Date(), source: String = "manual") throws -> LedgerEntry {
        let trimmed = String(payee.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !trimmed.isEmpty, cents != 0 else { throw NSError(domain: "PowerWatch.Ledger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a payee and an amount."]) }
        let guess = category == nil ? LocalCategorizer.guess(payee: trimmed, memory: try memory()) : nil
        let chosen = category ?? (guess?.applies == true ? guess?.category : nil)
        let entry = LedgerEntry(id: UUID().uuidString, posted: posted, payee: trimmed, cents: cents, category: chosen, confidence: category == nil ? guess?.confidence : 1, source: category == nil ? (guess?.source ?? source) : source, pending: false, accountMask: nil)
        try insert(entry, plaidID: nil)
        if let chosen, source == "manual" || category != nil { try remember(payee: trimmed, category: chosen) }
        return entry
    }
    public func setCategory(id: String, category: String) throws {
        guard LedgerCategory.all.contains(category) else { return }
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("UPDATE entries SET category=?, confidence=1, source='manual' WHERE id=?")
        defer { sqlite3_finalize(statement) }
        bind(category, to: statement, at: 1); bind(id, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        let payee = try prepare("SELECT payee FROM entries WHERE id=?")
        defer { sqlite3_finalize(payee) }
        bind(id, to: payee, at: 1)
        if sqlite3_step(payee) == SQLITE_ROW { try remember(payee: text(payee, 0), category: category) }
    }
    /// Fills only blank categories. A correction already stored as memory is reused.
    public func categorizeLocally() throws -> Int {
        let remembered = try memory()
        let pending = try entries(limit: 500).filter { $0.category == nil }
        var applied = 0
        for entry in pending {
            guard let guess = LocalCategorizer.guess(payee: entry.payee, memory: remembered), guess.applies else { continue }
            try assign(id: entry.id, guess: guess)
            applied += 1
        }
        return applied
    }
    public func applyGuess(id: String, guess: CategoryGuess) throws {
        guard guess.applies else { return }
        try assign(id: id, guess: guess)
    }
    public func addManualHolding(symbol: String, valueCents: Int, day: String) throws {
        let symbol = String(symbol.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12)).uppercased()
        guard !symbol.isEmpty, valueCents > 0 else { throw NSError(domain: "PowerWatch.Ledger", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a symbol and a value."]) }
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("INSERT INTO holdings(item_id,symbol,name,value_cents) VALUES('manual',?,?,?) ON CONFLICT(item_id,symbol) DO UPDATE SET value_cents=excluded.value_cents, name=excluded.name")
        bind(symbol, to: statement, at: 1); bind(symbol, to: statement, at: 2); sqlite3_bind_int64(statement, 3, Int64(valueCents))
        guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_finalize(statement); throw error() }
        sqlite3_finalize(statement)
        let total = try holdingsTotal()
        let dayStatement = try prepare("INSERT INTO portfolio_days(day,value_cents) VALUES(?,?) ON CONFLICT(day) DO UPDATE SET value_cents=excluded.value_cents")
        defer { sqlite3_finalize(dayStatement) }
        bind(day, to: dayStatement, at: 1); sqlite3_bind_int64(dayStatement, 2, Int64(total))
        guard sqlite3_step(dayStatement) == SQLITE_DONE else { throw error() }
    }
    public func setBudget(category: String, monthlyCents: Int) throws {
        guard LedgerCategory.all.contains(category), monthlyCents >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("INSERT INTO budgets(category,monthly_cents) VALUES(?,?) ON CONFLICT(category) DO UPDATE SET monthly_cents=excluded.monthly_cents")
        defer { sqlite3_finalize(statement) }
        bind(category, to: statement, at: 1); sqlite3_bind_int64(statement, 2, Int64(monthlyCents))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    public func budget(in month: Date = Date(), calendar: Calendar = .current) throws -> [BudgetRow] {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? month
        var spent: [String: Int] = [:]
        for entry in try entries(limit: 2000) where entry.posted >= start && entry.posted < end && entry.cents < 0 {
            spent[entry.category ?? "Uncategorized", default: 0] += -entry.cents
        }
        lock.lock(); defer { lock.unlock() }
        let limits = try prepare("SELECT category,monthly_cents FROM budgets")
        defer { sqlite3_finalize(limits) }
        var cap: [String: Int] = [:]
        while sqlite3_step(limits) == SQLITE_ROW { cap[text(limits, 0)] = Int(sqlite3_column_int64(limits, 1)) }
        let names = Array(Set(spent.keys).union(cap.keys)).sorted()
        return names.map { BudgetRow(category: $0, spentCents: spent[$0] ?? 0, limitCents: cap[$0] ?? 0) }
    }
    public func apply(_ change: PlaidSyncChange, item: String, environment: String) throws {
        for id in change.removedIDs { try deletePlaid(id) }
        for entry in change.modified { try upsertPlaid(entry) }
        for entry in change.added { try upsertPlaid(entry) }
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("INSERT INTO plaid_items(item_id,institution,cursor,environment) VALUES(?,?,?,?) ON CONFLICT(item_id) DO UPDATE SET cursor=excluded.cursor, environment=excluded.environment")
        defer { sqlite3_finalize(statement) }
        bind(item, to: statement, at: 1); bind("", to: statement, at: 2); bind(change.nextCursor, to: statement, at: 3); bind(environment, to: statement, at: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    public func plaidItems() throws -> [(id: String, cursor: String?, environment: String)] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT item_id,cursor,environment FROM plaid_items")
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String?, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((text(statement, 0), sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : text(statement, 1), text(statement, 2)))
        }
        return rows
    }
    public func replaceHoldings(_ rows: [Holding], item: String, day: String) throws {
        lock.lock(); defer { lock.unlock() }
        let clear = try prepare("DELETE FROM holdings WHERE item_id=?")
        bind(item, to: clear, at: 1)
        guard sqlite3_step(clear) == SQLITE_DONE else { sqlite3_finalize(clear); throw error() }
        sqlite3_finalize(clear)
        for row in rows {
            let statement = try prepare("INSERT INTO holdings(item_id,symbol,name,value_cents) VALUES(?,?,?,?)")
            bind(item, to: statement, at: 1); bind(row.symbol, to: statement, at: 2); bind(row.name, to: statement, at: 3)
            sqlite3_bind_int64(statement, 4, Int64(row.valueCents))
            let ok = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            guard ok else { throw error() }
        }
        let total = try holdingsTotal()
        let statement = try prepare("INSERT INTO portfolio_days(day,value_cents) VALUES(?,?) ON CONFLICT(day) DO UPDATE SET value_cents=excluded.value_cents")
        defer { sqlite3_finalize(statement) }
        bind(day, to: statement, at: 1); sqlite3_bind_int64(statement, 2, Int64(total))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    public func holdings() throws -> [Holding] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT symbol,name,SUM(value_cents) FROM holdings GROUP BY symbol,name ORDER BY SUM(value_cents) DESC")
        defer { sqlite3_finalize(statement) }
        var rows: [Holding] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(Holding(symbol: text(statement, 0), name: text(statement, 1), valueCents: Int(sqlite3_column_int64(statement, 2)))) }
        return rows
    }
    public func portfolio() throws -> [PortfolioPoint] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT day,value_cents FROM portfolio_days ORDER BY day")
        defer { sqlite3_finalize(statement) }
        var rows: [PortfolioPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(PortfolioPoint(day: text(statement, 0), valueCents: Int(sqlite3_column_int64(statement, 1)))) }
        return rows
    }
    public func memory() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payee_key,category FROM merchant_rules")
        defer { sqlite3_finalize(statement) }
        var rows: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW { rows[text(statement, 0)] = text(statement, 1) }
        return rows
    }
    private func holdingsTotal() throws -> Int {
        let statement = try prepare("SELECT COALESCE(SUM(value_cents),0) FROM holdings")
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func assign(id: String, guess: CategoryGuess) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("UPDATE entries SET category=?, confidence=?, source=? WHERE id=? AND category IS NULL")
        defer { sqlite3_finalize(statement) }
        bind(guess.category, to: statement, at: 1); sqlite3_bind_double(statement, 2, guess.confidence); bind(guess.source, to: statement, at: 3); bind(id, to: statement, at: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func remember(payee: String, category: String) throws {
        lock.lock(); defer { lock.unlock() }
        let key = LocalCategorizer.key(payee)
        guard !key.isEmpty else { return }
        let statement = try prepare("INSERT INTO merchant_rules(payee_key,category) VALUES(?,?) ON CONFLICT(payee_key) DO UPDATE SET category=excluded.category")
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1); bind(category, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func insert(_ entry: LedgerEntry, plaidID: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("INSERT OR IGNORE INTO entries(id,posted,payee,cents,category,confidence,source,plaid_id,account_mask,pending) VALUES(?,?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        bindEntry(entry, plaidID: plaidID, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func upsertPlaid(_ entry: LedgerEntry) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("""
        INSERT INTO entries(id,posted,payee,cents,category,confidence,source,plaid_id,account_mask,pending) VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(plaid_id) DO UPDATE SET posted=excluded.posted, payee=excluded.payee, cents=excluded.cents, pending=excluded.pending,
        category=CASE WHEN entries.source='manual' THEN entries.category ELSE excluded.category END,
        confidence=CASE WHEN entries.source='manual' THEN entries.confidence ELSE excluded.confidence END,
        source=CASE WHEN entries.source='manual' THEN entries.source ELSE excluded.source END
        """)
        defer { sqlite3_finalize(statement) }
        bindEntry(entry, plaidID: entry.id, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func deletePlaid(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("DELETE FROM entries WHERE plaid_id=?")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    private func bindEntry(_ entry: LedgerEntry, plaidID: String?, to statement: OpaquePointer) {
        bind(entry.id, to: statement, at: 1); sqlite3_bind_double(statement, 2, entry.posted.timeIntervalSince1970); bind(entry.payee, to: statement, at: 3)
        sqlite3_bind_int64(statement, 4, Int64(entry.cents))
        if let category = entry.category { bind(category, to: statement, at: 5) } else { sqlite3_bind_null(statement, 5) }
        if let confidence = entry.confidence { sqlite3_bind_double(statement, 6, confidence) } else { sqlite3_bind_null(statement, 6) }
        bind(entry.source, to: statement, at: 7)
        if let plaidID { bind(plaidID, to: statement, at: 8) } else { sqlite3_bind_null(statement, 8) }
        if let mask = entry.accountMask { bind(mask, to: statement, at: 9) } else { sqlite3_bind_null(statement, 9) }
        sqlite3_bind_int(statement, 10, entry.pending ? 1 : 0)
    }
    private func readEntries(_ statement: OpaquePointer) -> [LedgerEntry] {
        var rows: [LedgerEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(LedgerEntry(id: text(statement, 0), posted: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), payee: text(statement, 2), cents: Int(sqlite3_column_int64(statement, 3)), category: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : text(statement, 4), confidence: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5), source: text(statement, 6), pending: sqlite3_column_int(statement, 7) == 1, accountMask: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : text(statement, 8)))
        }
        return rows
    }
    private func tighten() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix) }
    }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func prepare(_ sql: String) throws -> OpaquePointer { var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }; return statement }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) { sqlite3_bind_text(statement, index, value, -1, transient) }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    private func error() -> NSError { NSError(domain: "PowerWatch.Ledger", code: 2, userInfo: [NSLocalizedDescriptionKey: "The local money ledger could not be saved."]) }
}
