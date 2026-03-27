import SwiftUI

struct TranscriptPanel: View {
    let segments: [TranscriptSegment]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "text.quote")
                    .foregroundStyle(.secondary)
                Text("Live Transcript")
                    .font(.headline)
                Spacer()
                Text("\(segments.count) segment\(segments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if segments.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Listening...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Transcript will appear as you speak")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(segments) { segment in
                                TranscriptSegmentRow(segment: segment)
                                    .id(segment.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: segments.count) { _, _ in
                        // Auto-scroll to latest segment
                        if let last = segments.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        )
    }
}

// MARK: - Segment Row

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(segment.speaker)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)

                Text(formatTimestamp(segment.start))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fontDesign(.monospaced)

                if segment.confidence < 0.6 {
                    Image(systemName: "ellipsis")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Partial result — may update")
                }
            }

            Text(segment.text)
                .font(.body)
                .foregroundStyle(segment.confidence < 0.6 ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
