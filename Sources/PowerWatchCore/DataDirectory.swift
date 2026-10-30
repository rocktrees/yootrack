import Foundation

/// Moves the existing data directory as a unit, including SQLite WAL files.
public enum DataDirectory {
    public static func prepare(in base: URL, allowLegacyMigration: Bool = true) throws -> URL {
        let files = FileManager.default
        let current = base.appendingPathComponent("YooTrack", isDirectory: true)
        let legacy = base.appendingPathComponent("Power Watch", isDirectory: true)
        if !files.fileExists(atPath: current.path), files.fileExists(atPath: legacy.path) {
            guard allowLegacyMigration else {
                throw NSError(domain: "YooTrack.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Quit the older app before starting YooTrack so its data can be moved safely."])
            }
            try files.moveItem(at: legacy, to: current)
        }
        return current
    }
}
