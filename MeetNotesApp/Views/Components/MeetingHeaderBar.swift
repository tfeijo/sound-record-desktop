import SwiftUI

struct MeetingHeaderBar: View {
    @Binding var meetingTitle: String
    let elapsedSeconds: Int
    let status: MeetingStatus
    let isRecording: Bool
    let audioLevel: Float
    let onToggleRecording: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Editable meeting name
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                TextField("Meeting Name", text: $meetingTitle)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(maxWidth: 260)
            }

            Spacer()

            // Audio level (compact)
            if isRecording {
                AudioLevelMeter(level: audioLevel)
                    .frame(width: 80, height: 10)
                    .transition(.opacity)
            }

            // Record / Stop button (compact)
            Button(action: onToggleRecording) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isRecording ? Color.red : Color.red.opacity(0.85))
                        .frame(width: 12, height: 12)
                    Text(isRecording ? "Stop" : "Record")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isRecording ? Color.red.opacity(0.1) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(isRecording ? Color.red.opacity(0.3) : Color.secondary.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // Duration timer
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Text(formattedDuration)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            // Status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Helpers

    private var formattedDuration: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var statusColor: Color {
        switch status {
        case .recording: return .red
        case .transcribing: return .orange
        case .diarizing: return .purple
        case .summarizing: return .blue
        case .done: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch status {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .diarizing: return "Identifying Speakers"
        case .summarizing: return "Summarizing"
        case .done: return "Done"
        case .error: return "Error"
        }
    }
}
