import SwiftUI

struct AINotesPanel: View {
    let aiNotes: AINotes?
    let summary: MeetingSummary?
    var isSummarizing: Bool = false
    var summaryError: String?

    var body: some View {
        if isSummarizing {
            summarizingView
        } else if let summaryError {
            errorView(summaryError)
        } else if let summary {
            summaryView(summary)
        } else if let aiNotes, !aiNotes.topics.isEmpty {
            aiNotesView(aiNotes)
        } else {
            placeholderView
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

    // MARK: - AI Notes View (live/streaming)

    private func aiNotesView(_ aiNotes: AINotes) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !aiNotes.topics.isEmpty {
                    sectionView(title: "Topics", items: aiNotes.topics)
                }
                if !aiNotes.decisions.isEmpty {
                    sectionView(title: "Decisions", items: aiNotes.decisions)
                }
                if !aiNotes.actionItems.isEmpty {
                    actionItemsSection(aiNotes.actionItems)
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
