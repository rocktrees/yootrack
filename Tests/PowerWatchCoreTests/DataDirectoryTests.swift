import XCTest
@testable import PowerWatchCore

final class DataDirectoryTests: XCTestCase {
    func testMigratesExistingDataAndSQLiteSidecars() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("Power Watch")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for name in ["history.sqlite", "history.sqlite-wal", "ledger.sqlite"] {
            try Data(name.utf8).write(to: legacy.appendingPathComponent(name))
        }
        let result = try DataDirectory.prepare(in: base)
        XCTAssertEqual(result.lastPathComponent, "YooTrack")
        for name in ["history.sqlite", "history.sqlite-wal", "ledger.sqlite"] {
            XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent(name)), Data(name.utf8))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testRefusesMigrationWhileOlderInstanceIsRunning() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("Power Watch")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DataDirectory.prepare(in: base, allowLegacyMigration: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("YooTrack").path))
    }

    func testExistingNewDirectoryIsNeverOverwritten() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["Power Watch", "YooTrack"] {
            let directory = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: directory.appendingPathComponent("history.sqlite"))
        }
        let result = try DataDirectory.prepare(in: base)
        XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("history.sqlite")), Data("YooTrack".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("Power Watch/history.sqlite").path))
    }
}
