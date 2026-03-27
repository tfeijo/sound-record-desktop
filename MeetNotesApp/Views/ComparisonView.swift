import SwiftUI

/// Displays the comparison between user personal notes and AI-generated notes.
/// Shows four sections: Aligned, User Only, AI Only, and Conflicts.
struct ComparisonView: View {
    let comparison: NoteComparison?
    let isProcessing: Bool
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isProcessing {
                processingView
            } else if let comparison, !isEmpty(comparison) {
                comparisonContent(comparison)
            } else if error != nil {
                errorView
            } else {
                emptyView
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func comparisonContent(_ comparison: NoteComparison) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !comparison.aligned.isEmpty {
                    comparisonSection(
                        title: "Aligned",
                        systemImage: "checkmark.circle.fill",
                        color: .green,
                        items: comparison.aligned
                    )
                }

                if !comparison.userOnly.isEmpty {
                    comparisonSection(
                        title: "Your Insights",
                        systemImage: "person.fill",
                        color: .blue,
                        items: comparison.userOnly
                    )
                }

                if !comparison.aiOnly.isEmpty {
                    comparisonSection(
                        title: "AI Insights",
                        systemImage: "brain",
                        color: .purple,
                        items: comparison.aiOnly
                    )
                }

                if !comparison.conflicts.isEmpty {
                    comparisonSection(
                        title: "Conflicts",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange,
                        items: comparison.conflicts
                    )
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func comparisonSection(
        title: String,
        systemImage: String,
        color: Color,
        items: [ComparisonItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("(\(items.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ComparisonItemRow(item: item, accentColor: color)
            }
        }
    }

    // MARK: - States

    private var processingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Comparing notes...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Analyzing differences between your notes and AI notes")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.on.doc")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No comparison available")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Add personal notes during a meeting to compare with AI insights")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Comparison failed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func isEmpty(_ comparison: NoteComparison) -> Bool {
        comparison.aligned.isEmpty
            && comparison.userOnly.isEmpty
            && comparison.aiOnly.isEmpty
            && comparison.conflicts.isEmpty
    }
}

// MARK: - Comparison Item Row

private struct ComparisonItemRow: View {
    let item: ComparisonItem
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.description)
                .font(.callout)

            if let userNote = item.userNote, !userNote.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(userNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let aiNote = item.aiNote, !aiNote.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text(aiNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
