import SwiftUI

struct AINotesPanel: View {
    let aiNotes: AINotes?

    var body: some View {
        if let aiNotes, !aiNotes.topics.isEmpty {
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
        } else {
            placeholderView
        }
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
}
