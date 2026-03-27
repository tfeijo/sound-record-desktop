import SwiftUI

struct AINotesPanel: View {
    let aiNotes: AINotes?
    let summary: MeetingSummary?
    var isSummarizing: Bool = false
    var summaryError: String?
    var isLiveProcessing: Bool = false
    var liveNotesError: String?
    var lastUpdateTime: Date?

    var body: some View {
        if isSummarizing {
            summarizingView
        } else if let summaryError {
            errorView(summaryError)
        } else if let summary {
            summaryView(summary)
        } else if let aiNotes, !aiNotes.topics.isEmpty || !aiNotes.decisions.isEmpty || !aiNotes.actionItems.isEmpty {
            liveAINotesView(aiNotes)
        } else if isLiveProcessing {
            liveProcessingView
        } else {
            placeholderView
        }
    }

    // MARK: - Live AI Notes View

    private func liveAINotesView(_ aiNotes: AINotes) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Topics with [[wikilinks]]
                    if !aiNotes.topics.isEmpty {
                        wikilinksTopicsSection(aiNotes.topics)
                    }

                    // Decisions as bullet list
                    if !aiNotes.decisions.isEmpty {
                        sectionView(title: "Decisions", items: aiNotes.decisions)
                    }

                    // Action items as checkbox list
                    if !aiNotes.actionItems.isEmpty {
                        checkboxActionItemsSection(aiNotes.actionItems)
                    }
                }
                .padding(12)
            }

            // Footer with update indicator
            liveNotesFooter
        }
    }

    // MARK: - Live Processing View

    private var liveProcessingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Analyzing transcript...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Live AI notes will appear shortly")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var liveNotesFooter: some View {
        HStack {
            if isLiveProcessing {
                ProgressView()
                    .controlSize(.mini)
                Text("Updating...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let liveNotesError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(liveNotesError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer()

            if let lastUpdateTime {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let seconds = Int(timeline.date.timeIntervalSince(lastUpdateTime))
                    Text("Updated \(formatTimeAgo(seconds))ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .separatorColor).opacity(0.3))
    }

    private func formatTimeAgo(_ seconds: Int) -> String {
        if seconds < 5 {
            return "just now "
        } else if seconds < 60 {
            return "\(seconds)s "
        } else {
            let minutes = seconds / 60
            return "\(minutes)m "
        }
    }

    // MARK: - Wikilinks Topics Section

    private func wikilinksTopicsSection(_ topics: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Topics")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(topics, id: \.self) { topic in
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                    Text(highlightWikilinks(topic))
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Renders [[wikilinks]] with a distinct visual style (purple, medium weight).
    private func highlightWikilinks(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)

        // Find all [[...]] patterns and style them
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let openRange = attributed[searchRange].range(of: "[["),
              let closeRange = attributed[openRange.upperBound..<attributed.endIndex].range(of: "]]") {
            let fullRange = openRange.lowerBound..<closeRange.upperBound
            attributed[fullRange].foregroundColor = .purple
            attributed[fullRange].font = .body.weight(.medium)
            searchRange = closeRange.upperBound..<attributed.endIndex
        }

        return attributed
    }

    // MARK: - Checkbox Action Items Section

    private func checkboxActionItemsSection(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Action Items")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.description) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "square")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description)
                            .font(.body)
                            .textSelection(.enabled)
                        if let assignee = item.assignee {
                            Text("@\(assignee)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Summary View

    private func summaryView(_ summary: MeetingSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(summary.title)
                    .font(.headline)
                    .textSelection(.enabled)

                // Summary
                Text(summary.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                // Decisions
                if !summary.decisions.isEmpty {
                    sectionView(title: "Decisions", items: summary.decisions)
                }

                // Action Items
                if !summary.actionItems.isEmpty {
                    actionItemsSection(summary.actionItems)
                }

                // Topics
                if !summary.topics.isEmpty {
                    topicsSection(summary.topics)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Summarizing Progress

    private var summarizingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Generating Summary...")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Analyzing transcript with AI")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Summary Failed")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "brain")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("AI Notes")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("AI-generated topics, decisions, and action items will appear here during the meeting.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    private func sectionView(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func actionItemsSection(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Action Items")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.description) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.description)
                            .font(.body)
                            .textSelection(.enabled)
                        if let assignee = item.assignee {
                            Text(assignee)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func topicsSection(_ topics: [Topic]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Topics")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(topics, id: \.title) { topic in
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.body.weight(.medium))
                        .textSelection(.enabled)
                    if let topicSummary = topic.summary {
                        Text(topicSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}
