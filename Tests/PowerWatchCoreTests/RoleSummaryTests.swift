import XCTest
@testable import PowerWatchCore

@MainActor final class RoleSummaryTests: XCTestCase {
    func testDecodingFailureUsesBuiltInBrowserExplanation() async throws {
        struct Generated: Decodable { var explanation: String }
        let summary = try await RoleSummaries.explain(roles: ["Web renderer", "Browser graphics / GPU process", "Browser network service", "Browser storage service", "Executable"]) { _ in
            _ = try JSONDecoder().decode(Generated.self, from: Data(#"{"explanation":42}"#.utf8))
            return "unused"
        }
        XCTAssertEqual(summary.source, .builtIn)
        XCTAssertTrue(summary.text.contains("display web content"))
        XCTAssertTrue(summary.text.contains("network connections"))
        XCTAssertTrue(summary.text.contains("specific purpose is unidentified"))
        XCTAssertFalse(summary.notice!.contains("deserialize"))
    }
    func testUnavailableModelSkipsGeneration() async throws {
        let summary = try await RoleSummaries.explain(roles: ["Application process"], unavailableReason: "The local model is not ready.") { _ in
            XCTFail("Generation must not run when the model is unavailable")
            return "unused"
        }
        XCTAssertEqual(summary.source, .builtIn)
        XCTAssertTrue(summary.notice!.contains("not ready"))
        XCTAssertTrue(summary.text.contains("installed app"))
    }
    func testEmptyOversizedMalformedAndTruncatedOutputUseBuiltInDescription() async throws {
        for output in [" \n ", String(repeating: "x", count: 601) + ".", #"{"explanation":"Something"}"#, "Renderers handle content and", "**Browser roles**: Content rendering.", "# Explanation.", "First role.\n\nSecond role."] {
            let summary = try await RoleSummaries.explain(roles: ["Web renderer"]) { _ in output }
            XCTAssertEqual(summary.source, .builtIn)
            XCTAssertTrue(summary.text.contains("tab or frame"))
        }
    }
    func testSuccessfulTextIsTrimmedAndLabeledGenerated() async throws {
        let summary = try await RoleSummaries.explain(roles: ["Web renderer", "Web renderer"]) { roles in
            XCTAssertEqual(roles, ["Web renderer"])
            return "  Renderers display web content.\n"
        }
        XCTAssertEqual(summary.text, "Renderers display web content.")
        XCTAssertEqual(summary.source, .generated)
        XCTAssertNil(summary.notice)
    }
    func testCancellationDoesNotPublishFallback() async {
        do {
            _ = try await RoleSummaries.explain(roles: ["Web renderer"]) { _ in throw CancellationError() }
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testKnownServiceAndUnknownRoleStayDistinct() async throws {
        let reading = ProcessReading(identity: ProcessIdentity(pid: 1, start: 1), name: "coreaudiod", path: "/usr/libexec/coreaudiod")
        let purpose = ServiceDescriptions.guide(for: reading)!.purpose
        let summary = try await RoleSummaries.explain(roles: [purpose, "macOS's mystery executable steals secrets"], unavailableReason: "Unavailable") { _ in "unused" }
        XCTAssertTrue(summary.text.contains(purpose))
        XCTAssertFalse(summary.text.contains("steals secrets"))
        XCTAssertTrue(summary.text.contains("no built-in explanation"))
    }
    func testUnavailableModelIncludesConcreteDigestInFallback() async throws {
        let digest = "Process: node (PID 42) — Script · server.js\nWorking directory: /Users/me/app\nHead of 1 child process(es): esbuild"
        let summary = try await RoleSummaries.explain(roles: ["Script"], digest: digest, unavailableReason: "The local model is not ready.") { _ in
            XCTFail("Generation must not run when the model is unavailable")
            return "unused"
        }
        XCTAssertEqual(summary.source, .builtIn)
        XCTAssertTrue(summary.text.contains("Working directory: /Users/me/app"))
        XCTAssertTrue(summary.text.contains("Head of 1 child process(es): esbuild"))
    }
}
