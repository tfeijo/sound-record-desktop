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

struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id: UUID
    var speaker: String
    var start: Double   // seconds
    var end: Double
    var text: String
    var confidence: Double
}

struct PersonalNote: Codable, Identifiable, Hashable {
    var id: UUID
    var text: String
    var timestamp: Double   // seconds into meeting
    var createdAt: Date
}

struct AINotes: Codable, Hashable {
    var topics: [String]        // with [[wikilinks]]
    var decisions: [String]
    var actionItems: [ActionItem]
    var lastUpdated: Date
}

struct ActionItem: Codable, Hashable {
    var description: String
    var assignee: String?
}

struct NoteComparison: Codable, Hashable {
    var aligned: [ComparisonItem]
    var userOnly: [ComparisonItem]
    var aiOnly: [ComparisonItem]
    var conflicts: [ComparisonItem]
}

struct ComparisonItem: Codable, Hashable {
    var description: String
    var userNote: String?
    var aiNote: String?
}

struct MeetingSummary: Codable, Hashable {
    var title: String
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var topics: [Topic]
}

struct Topic: Codable, Hashable {
    var title: String
    var summary: String?
}

struct PanelState: Codable, Hashable {
    var transcriptVisible: Bool
    var aiNotesVisible: Bool
    var personalNotesVisible: Bool

    static let `default` = PanelState(
        transcriptVisible: true,
        aiNotesVisible: true,
        personalNotesVisible: true
    )
}
