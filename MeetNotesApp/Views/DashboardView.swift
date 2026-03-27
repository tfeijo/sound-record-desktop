import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var audioEngine = AudioEngine()

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Status text
            Text(audioEngine.isRecording ? "Recording..." : "Ready to record")
                .font(.title2)
                .foregroundStyle(audioEngine.isRecording ? .red : .secondary)

            // Elapsed time
            if audioEngine.isRecording {
                Text(formattedElapsed)
                    .font(.system(.title, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            // Record / Stop button
            RecordButton(isRecording: audioEngine.isRecording) {
                if audioEngine.isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }

            // Audio level meter
            if audioEngine.isRecording {
                AudioLevelMeter(level: audioEngine.audioLevel)
                    .frame(maxWidth: 300)
                    .transition(.opacity)
            }

            // Error display
            if let error = audioEngine.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        let minutes = audioEngine.elapsedSeconds / 60
        let seconds = audioEngine.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startRecording() {
        let meetingID = audioEngine.startRecording()

        // Create a Meeting record in SwiftData
        let meeting = Meeting(
            id: meetingID,
            title: "Meeting \(formattedDate)",
            date: Date(),
            startTime: Date(),
            status: .recording,
            micPath: AudioEngine.micPath(for: meetingID)
        )
        modelContext.insert(meeting)
        try? modelContext.save()
    }

    private func stopRecording() {
        guard let meetingID = audioEngine.currentMeetingID else {
            audioEngine.stopRecording()
            return
        }

        let elapsed = audioEngine.elapsedSeconds
        audioEngine.stopRecording()

        // Update the Meeting record
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == meetingID }
        )
        if let meeting = try? modelContext.fetch(descriptor).first {
            meeting.endTime = Date()
            meeting.durationSeconds = elapsed
            meeting.status = .done
            meeting.updatedAt = Date()
            try? modelContext.save()
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}
