import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var audioEngine = AudioEngine()
    @State private var liveTranscriber = LiveTranscriber()

    var body: some View {
        HStack(spacing: 0) {
            // Left: Recording controls
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
                if let error = audioEngine.error ?? liveTranscriber.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right: Live transcript panel (visible during recording)
            if audioEngine.isRecording || !liveTranscriber.liveSegments.isEmpty {
                TranscriptPanel(segments: liveTranscriber.liveSegments)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: audioEngine.isRecording)
        .onAppear {
            liveTranscriber.requestAuthorization()
        }
    }

    // MARK: - Helpers

    private var formattedElapsed: String {
        let minutes = audioEngine.elapsedSeconds / 60
        let seconds = audioEngine.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startRecording() {
        // Wire audio buffers from engine to transcriber
        audioEngine.audioBufferHandler = { [liveTranscriber] buffer in
            liveTranscriber.appendBuffer(buffer)
        }

        let meetingID = audioEngine.startRecording()

        // Start live transcription
        liveTranscriber.start()

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
        do {
            try modelContext.save()
        } catch {
            audioEngine.error = "Failed to save meeting: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        guard let meetingID = audioEngine.currentMeetingID else {
            audioEngine.stopRecording()
            liveTranscriber.stop()
            return
        }

        let elapsed = audioEngine.elapsedSeconds

        // Capture segments before stopping to avoid reading cleared state
        let finalSegments = liveTranscriber.liveSegments

        liveTranscriber.stop()
        audioEngine.stopRecording()

        // Update the Meeting record with transcript segments
        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == meetingID }
        )
        if let meeting = try? modelContext.fetch(descriptor).first {
            meeting.endTime = Date()
            meeting.durationSeconds = elapsed
            meeting.status = .done
            meeting.transcript = finalSegments
            meeting.updatedAt = Date()
            do {
                try modelContext.save()
            } catch {
                audioEngine.error = "Failed to update meeting: \(error.localizedDescription)"
            }
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}
