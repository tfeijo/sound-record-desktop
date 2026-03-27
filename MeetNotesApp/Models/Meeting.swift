import Foundation
import SwiftData

@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var date: Date
    var startTime: Date?
    var endTime: Date?
    var durationSeconds: Int
    var speakerCount: Int
    var status: MeetingStatus
    var audioPath: String?
    var micPath: String?
    var systemPath: String?
    var transcript: [TranscriptSegment]
    var aiNotes: AINotes?
    var personalNotes: [PersonalNote]
    var comparison: NoteComparison?
    var summary: MeetingSummary?
    var obsidianPath: String?
    var meetUrl: String?
    var error: String?
    var panelState: PanelState
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        date: Date = Date(),
        startTime: Date? = nil,
        endTime: Date? = nil,
        durationSeconds: Int = 0,
        speakerCount: Int = 0,
        status: MeetingStatus = .recording,
        audioPath: String? = nil,
        micPath: String? = nil,
        systemPath: String? = nil,
        transcript: [TranscriptSegment] = [],
        aiNotes: AINotes? = nil,
        personalNotes: [PersonalNote] = [],
        comparison: NoteComparison? = nil,
        summary: MeetingSummary? = nil,
        obsidianPath: String? = nil,
        meetUrl: String? = nil,
        error: String? = nil,
        panelState: PanelState = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.durationSeconds = durationSeconds
        self.speakerCount = speakerCount
        self.status = status
        self.audioPath = audioPath
        self.micPath = micPath
        self.systemPath = systemPath
        self.transcript = transcript
        self.aiNotes = aiNotes
        self.personalNotes = personalNotes
        self.comparison = comparison
        self.summary = summary
        self.obsidianPath = obsidianPath
        self.meetUrl = meetUrl
        self.error = error
        self.panelState = panelState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
