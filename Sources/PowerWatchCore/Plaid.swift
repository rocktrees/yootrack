import Foundation

public enum FinanceParser {
    public static func hostedLink(_ data: Data) -> (url: URL, token: String)? {
        guard let root = ProviderUsageParser.jsonObject(data),
              let token = root["link_token"] as? String, token.hasPrefix("link-"),
              let text = root["hosted_link_url"] as? String, let url = URL(string: text), url.scheme == "https" else { return nil }
        return (url, token)
    }
    /// Reads public tokens from `/link/token/get` without keeping the rest of the session.
    public static func publicTokens(_ data: Data) -> [String] {
        var found: [String] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let token = dict["public_token"] as? String { found.append(token) }
                if let tokens = dict["public_tokens"] as? [String] { found.append(contentsOf: tokens) }
                dict.values.forEach(walk)
            } else if let list = value as? [Any] { list.forEach(walk) }
        }
        if let root = try? JSONSerialization.jsonObject(with: data) { walk(root) }
        var seen = Set<String>(), unique: [String] = []
        for token in found where token.hasPrefix("public-") && seen.insert(token).inserted { unique.append(token) }
        return unique
    }
    public static func exchange(_ data: Data) -> (access: String, item: String)? {
        guard let root = ProviderUsageParser.jsonObject(data),
              let access = root["access_token"] as? String, access.hasPrefix("access-"),
              let item = root["item_id"] as? String, !item.isEmpty else { return nil }
        return (access, item)
    }
    public static func syncPage(_ data: Data) -> PlaidSyncChange? {
        guard let root = ProviderUsageParser.jsonObject(data), let cursor = root["next_cursor"] as? String else { return nil }
        let masks = accountMasks(root["accounts"])
        let added = transactions(root["added"], masks: masks)
        let modified = transactions(root["modified"], masks: masks)
        let removed = (root["removed"] as? [[String: Any]] ?? []).compactMap { $0["transaction_id"] as? String }
        return PlaidSyncChange(added: added, modified: modified, removedIDs: removed, nextCursor: cursor, hasMore: (root["has_more"] as? NSNumber)?.boolValue == true)
    }
    public static func holdings(_ data: Data) -> [Holding] {
        guard let root = ProviderUsageParser.jsonObject(data) else { return [] }
        var names: [String: (symbol: String, name: String)] = [:]
        for security in root["securities"] as? [[String: Any]] ?? [] {
            guard let id = security["security_id"] as? String else { continue }
            let symbol = (security["ticker_symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
            names[id] = (symbol, (security["name"] as? String) ?? symbol)
        }
        var totals: [String: Holding] = [:]
        for row in root["holdings"] as? [[String: Any]] ?? [] {
            guard let id = row["security_id"] as? String, let value = ProviderUsageParser.number(row["institution_value"]) else { continue }
            let known = names[id] ?? ("—", "Holding")
            let cents = MoneyMath.cents(fromValue: value)
            let key = known.symbol + "\u{0}" + known.name
            let prior = totals[key]?.valueCents ?? 0
            totals[key] = Holding(symbol: known.symbol, name: known.name, valueCents: prior + cents)
        }
        return totals.values.sorted { $0.valueCents > $1.valueCents }
    }
    /// Jev and the OpenRouter Decisions API both return a label plus a confidence. Below 0.7 is not applied.
    public static func jevDecision(_ data: Data) -> CategoryGuess? {
        guard let root = ProviderUsageParser.jsonObject(data) else { return nil }
        let box = ProviderUsageParser.dictionary(root["output"]) ?? ProviderUsageParser.dictionary(root["result"]) ?? root
        let label = ["decision", "answer", "output", "category", "label", "result"].compactMap { box[$0] as? String }.first { LedgerCategory.all.contains($0) }
        let confidence = ["confidence", "probability", "score"].compactMap { ProviderUsageParser.number(box[$0]) }.first
        guard let label, let confidence else { return nil }
        return CategoryGuess(category: label, confidence: confidence, source: "jev")
    }
    public static func plaidErrorCode(_ data: Data) -> String? { ProviderUsageParser.jsonObject(data)?["error_code"] as? String }
    private static func accountMasks(_ value: Any?) -> [String: String] {
        var masks: [String: String] = [:]
        for account in value as? [[String: Any]] ?? [] {
            if let id = account["account_id"] as? String, let mask = account["mask"] as? String, mask.count <= 4 { masks[id] = mask }
        }
        return masks
    }
    private static func transactions(_ value: Any?, masks: [String: String]) -> [LedgerEntry] {
        (value as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["transaction_id"] as? String, let amount = ProviderUsageParser.number(row["amount"]),
                  let posted = ProviderUsageParser.dateValue(row["date"]) else { return nil }
            let payee = (row["merchant_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row["name"] as? String) ?? "Transaction"
            let cents = MoneyMath.cents(fromPlaidAmount: amount)
            let categoryBox = row["personal_finance_category"] as? [String: Any]
            let guess = LocalCategorizer.guess(payee: payee) ?? LocalCategorizer.fromPlaid(primary: categoryBox?["primary"] as? String, detailed: categoryBox?["detailed"] as? String)
            let applied = guess?.applies == true ? guess : nil
            let account = row["account_id"] as? String
            return LedgerEntry(id: id, posted: posted, payee: String(payee.prefix(120)), cents: cents, category: applied?.category, confidence: applied?.confidence, source: applied?.source ?? "plaid", pending: (row["pending"] as? NSNumber)?.boolValue == true, accountMask: account.flatMap { masks[$0] })
        }
    }
}

public struct PlaidClient: Sendable {
    public var host: String
    private let session: URLSession
    public init(environment: String) {
        host = environment == "production" ? "https://production.plaid.com" : "https://sandbox.plaid.com"
        session = CredentialNetwork.session
    }
    public func createHostedLink(clientID: String, secret: String, userID: String) async throws -> (url: URL, token: String) {
        let body: [String: Any] = ["client_id": clientID, "secret": secret, "client_name": "Power Watch", "language": "en", "country_codes": ["US"], "user": ["client_user_id": userID], "products": ["transactions"], "optional_products": ["investments"], "transactions": ["days_requested": 90], "hosted_link": ["url_lifetime_seconds": 1800]]
        let data = try await post("/link/token/create", body)
        guard let link = FinanceParser.hostedLink(data) else { throw failure(data) }
        return link
    }
    public func publicTokens(clientID: String, secret: String, linkToken: String) async throws -> [String] {
        try FinanceParser.publicTokens(await post("/link/token/get", ["client_id": clientID, "secret": secret, "link_token": linkToken]))
    }
    public func exchange(clientID: String, secret: String, publicToken: String) async throws -> (access: String, item: String) {
        let data = try await post("/item/public_token/exchange", ["client_id": clientID, "secret": secret, "public_token": publicToken])
        guard let exchanged = FinanceParser.exchange(data) else { throw failure(data) }
        return exchanged
    }
    public func sync(clientID: String, secret: String, access: String, cursor: String?) async throws -> PlaidSyncChange {
        var body: [String: Any] = ["client_id": clientID, "secret": secret, "access_token": access]
        if let cursor, !cursor.isEmpty { body["cursor"] = cursor }
        let data = try await post("/transactions/sync", body)
        guard let page = FinanceParser.syncPage(data) else { throw failure(data) }
        return page
    }
    public func investments(clientID: String, secret: String, access: String) async throws -> [Holding] {
        FinanceParser.holdings(try await post("/investments/holdings/get", ["client_id": clientID, "secret": secret, "access_token": access]))
    }
    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: host + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw failure(data) }
        return data
    }
    private func failure(_ data: Data) -> NSError {
        let code = FinanceParser.plaidErrorCode(data) ?? "REQUEST_FAILED"
        return NSError(domain: "PowerWatch.Plaid", code: 1, userInfo: [NSLocalizedDescriptionKey: "Plaid could not complete that request (\(code))."])
    }
}

public struct JevClient: Sendable {
    public var endpoint: URL
    private let session: URLSession
    public init(endpoint: URL = URL(string: "https://api.typesafe.ai/v1/systemone")!) {
        self.endpoint = endpoint
        session = CredentialNetwork.session
    }
    /// Sends the payee and the category list only. Callers must already have an explicit opt-in.
    public func categorize(payee: String, key: String) async throws -> CategoryGuess? {
        guard endpoint.scheme == "https" || endpoint.host == "localhost" || endpoint.host == "127.0.0.1" else {
            throw NSError(domain: "PowerWatch.Jev", code: 1, userInfo: [NSLocalizedDescriptionKey: "Jev only runs over HTTPS."])
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": "jev-latest", "input": String(payee.prefix(120)), "options": LedgerCategory.all]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "PowerWatch.Jev", code: 2, userInfo: [NSLocalizedDescriptionKey: "Jev did not categorize that payee."])
        }
        return FinanceParser.jevDecision(data)
    }
}
