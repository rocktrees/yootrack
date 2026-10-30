import Foundation
import SQLite3

public struct HistoryRow: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var bundlePath: String?
    public var joules: Double
    public var attributedJoules: Double
    public var lossPoints: Double
    public var observedSeconds: Double
    public var shareOfDrain: Double?
    /// Processor power over the observed time. This includes intervals on external power.
    public var averageWatts: Double { observedSeconds > 0 ? joules / observedSeconds : 0 }
    public init(id: String, name: String, bundlePath: String?, joules: Double, attributedJoules: Double, lossPoints: Double, observedSeconds: Double, shareOfDrain: Double?) {
        self.id = id; self.name = name; self.bundlePath = bundlePath; self.joules = joules
        self.attributedJoules = attributedJoules; self.lossPoints = lossPoints; self.observedSeconds = observedSeconds; self.shareOfDrain = shareOfDrain
    }
}
public struct HistoryPoint: Identifiable, Sendable {
    public var timestamp: Date
    public var joules: Double
    public var seconds: Double
    public var id: Date { timestamp }
    public var watts: Double { seconds > 0 ? joules / seconds : 0 }
    public init(timestamp: Date, joules: Double, seconds: Double) { self.timestamp = timestamp; self.joules = joules; self.seconds = seconds }
}
public struct HistorySummary: Sendable {
    public var rows: [HistoryRow]
    public var points: [HistoryPoint]
    public var batteryJoules: Double
    public var batteryLossPoints: Double
    public var validBatteryJoules: Double
    public var remainderJoules: Double
    public var remainderPoints: Double
    public var monitoredSeconds: Double
    public var attributionSeconds: Double
    public var availableSince: Date?
    public var attributionCoverage: Double { monitoredSeconds > 0 ? attributionSeconds / monitoredSeconds : 0 }
    public init(rows: [HistoryRow] = [], points: [HistoryPoint] = [], batteryJoules: Double = 0, batteryLossPoints: Double = 0, validBatteryJoules: Double = 0, remainderJoules: Double = 0, remainderPoints: Double = 0, monitoredSeconds: Double = 0, attributionSeconds: Double = 0, availableSince: Date? = nil) {
        self.rows = rows; self.points = points; self.batteryJoules = batteryJoules; self.batteryLossPoints = batteryLossPoints
        self.validBatteryJoules = validBatteryJoules; self.remainderJoules = remainderJoules; self.remainderPoints = remainderPoints
        self.monitoredSeconds = monitoredSeconds; self.attributionSeconds = attributionSeconds; self.availableSince = availableSince
    }
}

/// All access is serialized, including tests and the UI's asynchronous history reads.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var metadataCache: [String: String] = [:]
    private struct StableProcessMetadata: Equatable {
        let parent: Int32
        let uid: UInt32
        let name: String
        let path: String
        let bundle: String?
    }
    private var processMetadataCache: [ProcessIdentity: StableProcessMetadata] = [:]
    // Existing minute buckets finish before switching to finer recent history.
    private var fineCutover = -Double.infinity
    private var lastMaintenance = Date.distantPast
    public let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw error() }
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS entities(key TEXT PRIMARY KEY, name TEXT NOT NULL, bundle TEXT, kind TEXT NOT NULL, details TEXT);
        CREATE TABLE IF NOT EXISTS usage(bucket INTEGER NOT NULL, resolution INTEGER NOT NULL, key TEXT NOT NULL, seconds REAL NOT NULL, joules REAL NOT NULL, attributed REAL NOT NULL, points REAL NOT NULL, covered_start REAL NOT NULL, covered_end REAL NOT NULL, PRIMARY KEY(bucket,resolution,key));
        CREATE INDEX IF NOT EXISTS usage_key_time ON usage(key,bucket);
        CREATE TABLE IF NOT EXISTS system(bucket INTEGER NOT NULL, resolution INTEGER NOT NULL, seconds REAL NOT NULL, battery REAL NOT NULL, loss REAL NOT NULL, valid_battery REAL NOT NULL, remainder REAL NOT NULL, remainder_points REAL NOT NULL, valid_seconds REAL NOT NULL, covered_start REAL NOT NULL, covered_end REAL NOT NULL, PRIMARY KEY(bucket,resolution));
        """)
        for table in ["usage", "system"] {
            let info = try statement("PRAGMA table_info(\(table))"); var names: Set<String> = []
            while sqlite3_step(info) == SQLITE_ROW { names.insert(text(info, 1)) }; sqlite3_finalize(info)
            if !names.contains("covered_start") {
                try exec("ALTER TABLE \(table) ADD COLUMN covered_start REAL NOT NULL DEFAULT 0; ALTER TABLE \(table) ADD COLUMN covered_end REAL NOT NULL DEFAULT 0; UPDATE \(table) SET covered_start=bucket,covered_end=bucket+resolution;")
            }
        }
        let entities = try statement("PRAGMA table_info(entities)"); var entityColumns: Set<String> = []
        while sqlite3_step(entities) == SQLITE_ROW { entityColumns.insert(text(entities, 1)) }; sqlite3_finalize(entities)
        if !entityColumns.contains("parent") { try exec("ALTER TABLE entities ADD COLUMN parent TEXT") }
        try exec("PRAGMA user_version=2;")
        let latestMinute = try statement("SELECT MAX(bucket+60) FROM system WHERE resolution=60")
        if sqlite3_step(latestMinute) == SQLITE_ROW, sqlite3_column_type(latestMinute, 0) != SQLITE_NULL { fineCutover = sqlite3_column_double(latestMinute, 0) }
        sqlite3_finalize(latestMinute)
    }
    deinit { sqlite3_close(db) }
    private func error() -> NSError { NSError(domain: "PowerWatch.History", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw error() }; return result
    }
    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) { if let value { sqlite3_bind_text(statement, index, value, -1, transient) } else { sqlite3_bind_null(statement, index) } }
    private func step(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw error() } }
    private func text(_ statement: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    public func record(_ interval: UsageInterval) throws {
        lock.lock(); defer { lock.unlock() }
        guard interval.seconds > 0 else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            let metadata = try statement("INSERT INTO entities(key,name,bundle,kind,details,parent) VALUES(?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET name=excluded.name,bundle=excluded.bundle,details=excluded.details,parent=COALESCE(excluded.parent,parent)")
            defer { sqlite3_finalize(metadata) }
            var pendingMetadata: [String: String] = [:]
            var pendingProcessMetadata: [ProcessIdentity: StableProcessMetadata] = [:]
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            func entity(key: String, name: String, bundle: String?, kind: String, details: String?, parent: String?) throws {
                let signature = name + (bundle ?? "") + (details ?? "") + (parent ?? "")
                guard metadataCache[key] != signature, pendingMetadata[key] != signature else { return }
                sqlite3_reset(metadata); sqlite3_clear_bindings(metadata)
                for (index, value) in [key, name, bundle, kind, details, parent].enumerated() { bind(value, to: metadata, at: Int32(index + 1)) }
                try step(metadata); pendingMetadata[key] = signature
            }
            for p in interval.processes {
                try entity(key: p.groupKey, name: p.groupName, bundle: p.bundlePath, kind: "group", details: nil, parent: nil)
                // Persist stable identity metadata; changing counters stay in the usage table.
                let snapshot = StableProcessMetadata(parent: p.reading.parentPID, uid: p.reading.uid, name: p.reading.name, path: p.reading.path, bundle: p.bundlePath)
                guard processMetadataCache[p.id] != snapshot else { continue }
                var stable = p.reading; stable.cpuNanoseconds = nil; stable.energyNanojoules = nil; stable.memoryBytes = nil; stable.energyImpact = nil; stable.gpuMillisecondsPerSecond = nil; stable.networkReceivedBytesPerSecond = nil; stable.networkSentBytesPerSecond = nil
                try entity(key: "pid:" + p.id.key, name: p.reading.name, bundle: p.bundlePath, kind: "process", details: String(data: try encoder.encode(stable), encoding: .utf8), parent: p.groupKey)
                pendingProcessMetadata[p.id] = snapshot
            }
            let row = try statement("INSERT INTO usage VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(bucket,resolution,key) DO UPDATE SET seconds=seconds+excluded.seconds,joules=joules+excluded.joules,attributed=attributed+excluded.attributed,points=points+excluded.points,covered_start=MIN(covered_start,excluded.covered_start),covered_end=MAX(covered_end,excluded.covered_end)")
            let system = try statement("INSERT INTO system VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(bucket,resolution) DO UPDATE SET seconds=seconds+excluded.seconds,battery=battery+excluded.battery,loss=loss+excluded.loss,valid_battery=valid_battery+excluded.valid_battery,remainder=remainder+excluded.remainder,remainder_points=remainder_points+excluded.remainder_points,valid_seconds=valid_seconds+excluded.valid_seconds,covered_start=MIN(covered_start,excluded.covered_start),covered_end=MAX(covered_end,excluded.covered_end)")
            defer { sqlite3_finalize(row); sqlite3_finalize(system) }
            var cursor = interval.start.timeIntervalSince1970
            let end = interval.end.timeIntervalSince1970
            while cursor < end {
                let resolution: Int64 = cursor < fineCutover ? 60 : 15
                let bucket = Int64(floor(cursor / Double(resolution)) * Double(resolution))
                let next = min(end, Double(bucket + resolution))
                let fraction = (next - cursor) / (end - interval.start.timeIntervalSince1970)
                let seconds = interval.seconds * fraction
                let groupMembers = Dictionary(grouping: interval.processes, by: \.groupKey)
                var energyRows: [(String, Double)] = interval.processes.compactMap { p in p.joules.map { ("pid:" + p.id.key, $0) } }
                energyRows += groupMembers.map { ($0.key, $0.value.compactMap(\.joules).reduce(0, +)) }
                for (key, energy) in energyRows where energy > 0 {
                    let attributed = interval.attributionValid ? energy : 0
                    let points = interval.attributionValid && (interval.batteryJoules ?? 0) > 0 ? energy / interval.batteryJoules! * (interval.batteryLossPoints ?? 0) : 0
                    sqlite3_reset(row); sqlite3_clear_bindings(row); sqlite3_bind_int64(row, 1, bucket); sqlite3_bind_int64(row, 2, resolution); bind(key, to: row, at: 3)
                    for (index, value) in [seconds, energy * fraction, attributed * fraction, points * fraction, cursor, next].enumerated() { sqlite3_bind_double(row, Int32(index + 4), value) }
                    try step(row)
                }
                let remainder = interval.remainderJoules ?? 0
                let remainderPoints = interval.attributionValid && (interval.batteryJoules ?? 0) > 0 ? remainder / interval.batteryJoules! * (interval.batteryLossPoints ?? 0) : 0
                sqlite3_reset(system); sqlite3_clear_bindings(system); sqlite3_bind_int64(system, 1, bucket); sqlite3_bind_int64(system, 2, resolution)
                let values = [seconds, (interval.batteryJoules ?? 0) * fraction, (interval.batteryLossPoints ?? 0) * fraction, interval.attributionValid ? (interval.batteryJoules ?? 0) * fraction : 0, remainder * fraction, remainderPoints * fraction, interval.attributionValid ? seconds : 0, cursor, next]
                for (index, value) in values.enumerated() { sqlite3_bind_double(system, Int32(index + 3), value) }
                try step(system); cursor = next
            }
            try exec("COMMIT"); metadataCache.merge(pendingMetadata) { _, new in new }
            processMetadataCache.merge(pendingProcessMetadata) { _, new in new }
        } catch { try? exec("ROLLBACK"); throw error }
        if interval.end.timeIntervalSince(lastMaintenance) > 3600 { try maintain(now: interval.end); lastMaintenance = interval.end }
    }
    public func summary(from start: Date, to end: Date, entity: String? = nil, membersOf group: String? = nil) throws -> HistorySummary {
        lock.lock(); defer { lock.unlock() }
        // Include buckets intersecting the selected range; scale the edge buckets by overlap.
        let startTime = start.timeIntervalSince1970, endTime = end.timeIntervalSince1970
        var result = HistorySummary()
        let system = try statement("SELECT bucket,resolution,seconds,battery,loss,valid_battery,remainder,remainder_points,valid_seconds,covered_start,covered_end FROM system WHERE bucket+resolution>? AND bucket<? ORDER BY bucket")
        defer { sqlite3_finalize(system) }
        sqlite3_bind_double(system, 1, startTime); sqlite3_bind_double(system, 2, endTime)
        while sqlite3_step(system) == SQLITE_ROW {
            let a = sqlite3_column_double(system, 9), b = sqlite3_column_double(system, 10)
            let factor = b > a ? max(0, min(endTime, b) - max(startTime, a)) / (b - a) : 0
            result.monitoredSeconds += sqlite3_column_double(system, 2) * factor
            result.batteryJoules += sqlite3_column_double(system, 3) * factor
            result.batteryLossPoints += sqlite3_column_double(system, 4) * factor
            result.validBatteryJoules += sqlite3_column_double(system, 5) * factor
            result.remainderJoules += sqlite3_column_double(system, 6) * factor
            result.remainderPoints += sqlite3_column_double(system, 7) * factor
            result.attributionSeconds += sqlite3_column_double(system, 8) * factor
        }
        let filter = group != nil ? "e.kind='process' AND e.parent=?" : (entity == nil ? "e.kind='group'" : "u.key=?")
        let rows = try statement("SELECT u.bucket,u.resolution,u.key,e.name,e.bundle,u.seconds,u.joules,u.attributed,u.points,u.covered_start,u.covered_end FROM usage u JOIN entities e ON e.key=u.key WHERE u.bucket+u.resolution>? AND u.bucket<? AND \(filter) ORDER BY u.bucket")
        defer { sqlite3_finalize(rows) }
        sqlite3_bind_double(rows, 1, startTime); sqlite3_bind_double(rows, 2, endTime)
        if let group { bind(group, to: rows, at: 3) } else if let entity { bind(entity, to: rows, at: 3) }
        var aggregate: [String: HistoryRow] = [:]; var points: [Date: HistoryPoint] = [:]
        while sqlite3_step(rows) == SQLITE_ROW {
            let bucket = sqlite3_column_double(rows, 0)
            let a = sqlite3_column_double(rows, 9), b = sqlite3_column_double(rows, 10)
            let factor = b > a ? max(0, min(endTime, b) - max(startTime, a)) / (b - a) : 0
            guard factor > 0 else { continue }
            let key = text(rows, 2); let date = Date(timeIntervalSince1970: max(bucket, startTime))
            var value = aggregate[key] ?? HistoryRow(id: key, name: text(rows, 3), bundlePath: sqlite3_column_type(rows, 4) == SQLITE_NULL ? nil : text(rows, 4), joules: 0, attributedJoules: 0, lossPoints: 0, observedSeconds: 0, shareOfDrain: nil)
            let seconds = sqlite3_column_double(rows, 5) * factor, joules = sqlite3_column_double(rows, 6) * factor
            value.observedSeconds += seconds; value.joules += joules; value.attributedJoules += sqlite3_column_double(rows, 7) * factor; value.lossPoints += sqlite3_column_double(rows, 8) * factor
            aggregate[key] = value
            var point = points[date] ?? HistoryPoint(timestamp: date, joules: 0, seconds: 0)
            point.joules += joules; point.seconds = max(point.seconds, seconds); points[date] = point
        }
        result.rows = aggregate.values.map { value in var row = value; row.shareOfDrain = result.validBatteryJoules > 0 ? row.attributedJoules / result.validBatteryJoules * 100 : nil; return row }.sorted { $0.joules > $1.joules }
        result.points = points.values.sorted { $0.timestamp < $1.timestamp }
        let earliest = try statement("SELECT MIN(bucket) FROM system"); defer { sqlite3_finalize(earliest) }
        if sqlite3_step(earliest) == SQLITE_ROW, sqlite3_column_type(earliest, 0) != SQLITE_NULL { result.availableSince = Date(timeIntervalSince1970: sqlite3_column_double(earliest, 0)) }
        return result
    }
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }; try exec("DELETE FROM usage; DELETE FROM system; DELETE FROM entities; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"); metadataCache.removeAll(); processMetadataCache.removeAll(); fineCutover = -Double.infinity
    }
    public func maintain(now: Date, byteLimit: Int64 = 250 * 1024 * 1024) throws {
        lock.lock(); defer { lock.unlock() }
        let fineBoundary = Int64(floor((now.timeIntervalSince1970 - 3600) / 60) * 60)
        let old = Int64(floor((now.timeIntervalSince1970 - 86400) / 300) * 300)
        let oldest = Int64(now.timeIntervalSince1970 - 7 * 86400)
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("""
            INSERT INTO usage SELECT bucket-(bucket%60),60,key,SUM(seconds),SUM(joules),SUM(attributed),SUM(points),MIN(covered_start),MAX(covered_end) FROM usage WHERE resolution=15 AND bucket+15<=\(fineBoundary) GROUP BY bucket-(bucket%60),key
            ON CONFLICT(bucket,resolution,key) DO UPDATE SET seconds=seconds+excluded.seconds,joules=joules+excluded.joules,attributed=attributed+excluded.attributed,points=points+excluded.points,covered_start=MIN(covered_start,excluded.covered_start),covered_end=MAX(covered_end,excluded.covered_end);
            INSERT INTO system SELECT bucket-(bucket%60),60,SUM(seconds),SUM(battery),SUM(loss),SUM(valid_battery),SUM(remainder),SUM(remainder_points),SUM(valid_seconds),MIN(covered_start),MAX(covered_end) FROM system WHERE resolution=15 AND bucket+15<=\(fineBoundary) GROUP BY bucket-(bucket%60)
            ON CONFLICT(bucket,resolution) DO UPDATE SET seconds=seconds+excluded.seconds,battery=battery+excluded.battery,loss=loss+excluded.loss,valid_battery=valid_battery+excluded.valid_battery,remainder=remainder+excluded.remainder,remainder_points=remainder_points+excluded.remainder_points,valid_seconds=valid_seconds+excluded.valid_seconds,covered_start=MIN(covered_start,excluded.covered_start),covered_end=MAX(covered_end,excluded.covered_end);
            DELETE FROM usage WHERE resolution=15 AND bucket+15<=\(fineBoundary);
            DELETE FROM system WHERE resolution=15 AND bucket+15<=\(fineBoundary);
            INSERT INTO usage SELECT bucket-(bucket%300),300,key,SUM(seconds),SUM(joules),SUM(attributed),SUM(points),MIN(covered_start),MAX(covered_end) FROM usage WHERE resolution=60 AND bucket+60<\(old) GROUP BY bucket-(bucket%300),key
            ON CONFLICT(bucket,resolution,key) DO UPDATE SET seconds=seconds+excluded.seconds,joules=joules+excluded.joules,attributed=attributed+excluded.attributed,points=points+excluded.points,covered_start=MIN(covered_start,excluded.covered_start),covered_end=MAX(covered_end,excluded.covered_end);
            INSERT INTO system SELECT bucket-(bucket%300),300,SUM(seconds),SUM(battery),SUM(loss),SUM(valid_battery),SUM(remainder),SUM(remainder_points),SUM(valid_seconds),MIN(covered_start),MAX(covered_end) FROM system WHERE resolution=60 AND bucket+60<\(old) GROUP BY bucket-(bucket%300)
            ON CONFLICT(bucket,resolution) DO UPDATE SET seconds=seconds+excluded.seconds,battery=battery+excluded.battery,loss=loss+excluded.loss,valid_battery=valid_battery+excluded.valid_battery,remainder=remainder+excluded.remainder,remainder_points=remainder_points+excluded.remainder_points,valid_seconds=valid_seconds+excluded.valid_seconds,covered_start=MIN(covered_start,excluded.covered_start),covered_end=MAX(covered_end,excluded.covered_end);
            DELETE FROM usage WHERE (resolution=60 AND bucket+60<\(old)) OR bucket+resolution<\(oldest);
            DELETE FROM system WHERE (resolution=60 AND bucket+60<\(old)) OR bucket+resolution<\(oldest);
            DELETE FROM entities WHERE key NOT IN (SELECT DISTINCT key FROM usage);
            COMMIT;
            """)
        } catch { try? exec("ROLLBACK"); throw error }
        try exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum;")
        func allocatedBytes() -> Int64 {
            let sizes = [url.path, url.path + "-wal", url.path + "-shm"].map { ((try? FileManager.default.attributesOfItem(atPath: $0)[.size]) as? NSNumber)?.int64Value ?? 0 }
            return sizes.reduce(0, +)
        }
        // Trim in six-hour increments, retaining the most recent data and reporting the actual available range.
        while allocatedBytes() > byteLimit {
            let minimum = try statement("SELECT MIN(bucket) FROM system")
            guard sqlite3_step(minimum) == SQLITE_ROW, sqlite3_column_type(minimum, 0) != SQLITE_NULL else { sqlite3_finalize(minimum); break }
            let cutoff = sqlite3_column_int64(minimum, 0) + 21600; sqlite3_finalize(minimum)
            try exec("DELETE FROM usage WHERE bucket<\(cutoff); DELETE FROM system WHERE bucket<\(cutoff); DELETE FROM entities WHERE key NOT IN (SELECT DISTINCT key FROM usage); PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        }
        metadataCache.removeAll()
        processMetadataCache.removeAll()
    }
}
