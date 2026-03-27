import Foundation
import SwiftData
import SQLite3

/// Migrates data from the old Tauri/Go MeetNotes app's SQLite database
/// into SwiftData on first launch.
///
/// Detects the old database at ~/Library/Application Support/MeetNotes/meetnotes.db,
/// reads meetings and speaker profiles, and creates corresponding SwiftData objects.
/// Audio files remain in their original locations (no copy needed).
/// Migration runs once, tracked via UserDefaults flag.
@MainActor @Observable
final class DataMigrator {
    private(set) var isProcessing = false
    private(set) var progress: Double = 0.0
    var error: String?

    private static let migrationKey = "com.meetnotes.migrationCompleted"

    /// Check if migration is needed and run if so.
    func migrateIfNeeded(modelContext: ModelContext) async {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else { return }

        let dbPath = Self.oldDatabasePath()
        guard FileManager.default.fileExists(atPath: dbPath) else {
            // No old database — mark as done and skip
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            return
        }

        isProcessing = true
        progress = 0.0
        error = nil

        do {
            try await performMigration(dbPath: dbPath, modelContext: modelContext)
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
        } catch {
            self.error = "Migration failed: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    // MARK: - Database Path

    private static func oldDatabasePath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("MeetNotes")
            .appendingPathComponent("meetnotes.db")
            .path
    }

    // MARK: - Migration

    private func performMigration(dbPath: String, modelContext: ModelContext) async throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw MigrationError.cannotOpenDatabase
        }
        defer { sqlite3_close(db) }

        // Migrate meetings
        let meetingCount = try countRows(db: db, table: "meetings")
        try migrateMeetings(db: db, modelContext: modelContext, totalCount: meetingCount)

        progress = 0.8

        // Migrate speaker profiles (if table exists)
        if tableExists(db: db, table: "speaker_profiles") {
            try migrateSpeakerProfiles(db: db, modelContext: modelContext)
        }

        progress = 0.9

        // Save all at once
        try modelContext.save()
        progress = 1.0
    }

    // MARK: - Meetings

    private func migrateMeetings(
        db: OpaquePointer?,
        modelContext: ModelContext,
        totalCount: Int
    ) throws {
        let query = """
            SELECT id, title, date, start_time, end_time, duration_seconds,
                   status, mic_path, system_path, transcript_json, summary_json,
                   meet_url, speaker_count
            FROM meetings
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            // Table might not exist or have different schema — skip gracefully
            return
        }
        defer { sqlite3_finalize(stmt) }

        var imported = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let meeting = try parseMeetingRow(stmt: stmt)
            modelContext.insert(meeting)
            imported += 1

            if totalCount > 0 {
                progress = Double(imported) / Double(totalCount) * 0.8
            }
        }
    }

    private func parseMeetingRow(stmt: OpaquePointer?) throws -> Meeting {
        let idString = columnString(stmt, index: 0) ?? UUID().uuidString
        let id = UUID(uuidString: idString) ?? UUID()
        let title = columnString(stmt, index: 1) ?? "Untitled Meeting"
        let dateStr = columnString(stmt, index: 2)
        let startStr = columnString(stmt, index: 3)
        let endStr = columnString(stmt, index: 4)
        let duration = Int(sqlite3_column_int(stmt, 5))
        let statusStr = columnString(stmt, index: 6) ?? "done"
        let micPath = columnString(stmt, index: 7)
        let systemPath = columnString(stmt, index: 8)
        let transcriptJSON = columnString(stmt, index: 9)
        let summaryJSON = columnString(stmt, index: 10)
        let meetUrl = columnString(stmt, index: 11)
        let speakerCount = Int(sqlite3_column_int(stmt, 12))

        let date = Self.parseDate(dateStr) ?? Date()
        let startTime = Self.parseDate(startStr)
        let endTime = Self.parseDate(endStr)
        let status = MeetingStatus(rawValue: statusStr) ?? .done

        let meeting = Meeting(
            id: id,
            title: title,
            date: date,
            startTime: startTime,
            status: status,
            micPath: micPath,
            systemPath: systemPath
        )
        meeting.endTime = endTime
        meeting.durationSeconds = duration
        meeting.speakerCount = speakerCount
        meeting.meetUrl = meetUrl

        // Parse transcript JSON
        if let json = transcriptJSON, let data = json.data(using: .utf8) {
            meeting.transcript = (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
        }

        // Parse summary JSON
        if let json = summaryJSON, let data = json.data(using: .utf8) {
            meeting.summary = try? JSONDecoder().decode(MeetingSummary.self, from: data)
        }

        return meeting
    }

    // MARK: - Speaker Profiles

    private func migrateSpeakerProfiles(db: OpaquePointer?, modelContext: ModelContext) throws {
        let query = "SELECT id, name, embedding_data, created_at FROM speaker_profiles"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let idStr = columnString(stmt, index: 0) ?? UUID().uuidString
            let id = UUID(uuidString: idStr) ?? UUID()
            let name = columnString(stmt, index: 1) ?? ""
            let createdStr = columnString(stmt, index: 3)
            let createdAt = Self.parseDate(createdStr) ?? Date()

            // Embedding data (blob)
            var embeddingData: Data?
            let blobSize = sqlite3_column_bytes(stmt, 2)
            if blobSize > 0, let blob = sqlite3_column_blob(stmt, 2) {
                embeddingData = Data(bytes: blob, count: Int(blobSize))
            }

            let profile = SpeakerProfile(
                id: id,
                name: name,
                embeddingData: embeddingData,
                createdAt: createdAt
            )
            modelContext.insert(profile)
        }
    }

    // MARK: - Helpers

    private func tableExists(db: OpaquePointer?, table: String) -> Bool {
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func countRows(db: OpaquePointer?, table: String) throws -> Int {
        let query = "SELECT COUNT(*) FROM \(table)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private func columnString(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
        return formats.map { format in
            let f = DateFormatter()
            f.dateFormat = format
            return f
        }
    }()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        // Try TimeInterval (epoch seconds)
        if let interval = Double(string) {
            return Date(timeIntervalSince1970: interval)
        }
        return nil
    }
}

// MARK: - Migration Error

enum MigrationError: LocalizedError {
    case cannotOpenDatabase

    var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase:
            return "Cannot open old MeetNotes database"
        }
    }
}
