import Foundation

// MARK: - Enums

enum MeetingStatus: String, Codable {
    case recording
    case transcribing
    case summarizing
    case done
    case error
}

enum SummaryProvider: String, Codable {
    case claude
    case gemini
    case local
}

// MARK: - Codable Structs

struct TranscriptSegment: Codable, Identifiable {
    var id: UUID
    var speaker: String
    var start: Double   // seconds
    var end: Double
    var text: String
    var confidence: Double
}

struct PersonalNote: Codable, Identifiable {
    var id: UUID
    var text: String
    var timestamp: Double   // seconds into meeting
    var createdAt: Date
}

struct AINotes: Codable {
    var topics: [String]        // with [[wikilinks]]
    var decisions: [String]
    var actionItems: [String]
    var lastUpdated: Date
}

struct NoteComparison: Codable {
    var aligned: [ComparisonItem]
    var userOnly: [ComparisonItem]
    var aiOnly: [ComparisonItem]
    var conflicts: [ComparisonItem]
}

struct ComparisonItem: Codable {
    var description: String
    var userNote: String?
    var aiNote: String?
}

struct MeetingSummary: Codable {
    var title: String
    var summary: String
    var decisions: [String]
    var actionItems: [String]
    var topics: [String]
}

struct PanelState: Codable {
    var transcriptVisible: Bool
    var aiNotesVisible: Bool
    var personalNotesVisible: Bool

    static let `default` = PanelState(
        transcriptVisible: true,
        aiNotesVisible: true,
        personalNotesVisible: true
    )
}
