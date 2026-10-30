import XCTest
@testable import PowerWatchCore

final class LedgerTests: XCTestCase {
    func testLocalCategorizerPrefersMemoryAndWithholdsWeakGuesses() {
        let payee = "STARBUCKS STORE 123"
        XCTAssertEqual(LocalCategorizer.guess(payee: payee)?.category, "Dining")
        XCTAssertEqual(LocalCategorizer.guess(payee: payee, memory: [LocalCategorizer.key(payee): "Shopping"])?.category, "Shopping")
        XCTAssertNil(LocalCategorizer.guess(payee: "ACME WIDGET"))
        XCTAssertFalse(CategoryGuess(category: "Dining", confidence: 0.69, source: "jev").applies)
        XCTAssertEqual(MoneyMath.cents(from: "12.34"), 1234)
        XCTAssertEqual(MoneyMath.cents(fromPlaidAmount: 12.34), -1234)
        XCTAssertNil(MoneyMath.cents(from: ""))
    }
    func testLedgerKeepsSpendingPrivateAndRemembersCorrections() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal")); try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm")) }
        let store = try LedgerStore(url: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
        let saved = try store.add(payee: "Corner Cafe", cents: -450, category: "Dining")
        _ = try store.add(payee: "Payroll", cents: 200_000, category: "Income")
        let again = try store.add(payee: "Corner Cafe downtown", cents: -300, category: nil)
        XCTAssertEqual(again.category, "Dining")
        try store.setBudget(category: "Dining", monthlyCents: 5_000)
        let budget = try store.budget()
        XCTAssertEqual(budget.first { $0.category == "Dining" }?.spentCents, 750)
        XCTAssertEqual(budget.first { $0.category == "Dining" }?.remainingCents, 4_250)
        XCTAssertFalse(budget.contains { $0.category == "Income" })
        try store.setCategory(id: saved.id, category: "Shopping")
        XCTAssertEqual(try store.add(payee: "Corner Cafe", cents: -100, category: nil).category, "Shopping")
        XCTAssertEqual(try store.categorizeLocally(), 0)
        try store.addManualHolding(symbol: "aapl", valueCents: 15_000, day: "2026-10-23")
        XCTAssertEqual(try store.holdings().first?.symbol, "AAPL")
        XCTAssertEqual(try store.portfolio().first?.valueCents, 15_000)
    }
    func testPlaidSyncKeepsTheMaskAndDropsTheAccountIdentifier() throws {
        let body = """
        {"added":[{"transaction_id":"tx1","account_id":"acc-secret","amount":4.50,"date":"2026-10-01","merchant_name":"Starbucks","pending":false,"personal_finance_category":{"primary":"FOOD_AND_DRINK"}}],"modified":[],"removed":[{"transaction_id":"old"}],"next_cursor":"cursor-1","has_more":false,"accounts":[{"account_id":"acc-secret","mask":"1234","name":"Checking"}]}
        """.data(using: .utf8)!
        let page = try XCTUnwrap(FinanceParser.syncPage(body))
        XCTAssertEqual(page.added.first?.accountMask, "1234")
        XCTAssertEqual(page.added.first?.cents, -450)
        XCTAssertEqual(page.added.first?.category, "Dining")
        XCTAssertEqual(page.removedIDs, ["old"])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).isEmpty)
        let encoded = String(describing: page.added.first!)
        XCTAssertFalse(encoded.contains("acc-secret"))
        let link = """
        {"link_token":"link-sandbox-1","hosted_link_url":"https://secure.plaid.com/hl/example","request_id":"req"}
        """.data(using: .utf8)!
        XCTAssertEqual(FinanceParser.hostedLink(link)?.token, "link-sandbox-1")
        let session = """
        {"link_sessions":[{"results":{"item_add_results":[{"public_token":"public-sandbox-abc"}]}}]}
        """.data(using: .utf8)!
        XCTAssertEqual(FinanceParser.publicTokens(session), ["public-sandbox-abc"])
        let jev = """
        {"decision":"Dining","confidence":0.91}
        """.data(using: .utf8)!
        XCTAssertEqual(FinanceParser.jevDecision(jev)?.applies, true)
        let weak = """
        {"decision":"Dining","confidence":0.4}
        """.data(using: .utf8)!
        XCTAssertEqual(FinanceParser.jevDecision(weak)?.applies, false)
        let holdings = """
        {"holdings":[{"security_id":"sec","institution_value":10.5}],"securities":[{"security_id":"sec","ticker_symbol":"VTI","name":"Total Market"}]}
        """.data(using: .utf8)!
        XCTAssertEqual(FinanceParser.holdings(holdings).first?.symbol, "VTI")
        XCTAssertEqual(FinanceParser.holdings(holdings).first?.valueCents, 1050)
    }
}
