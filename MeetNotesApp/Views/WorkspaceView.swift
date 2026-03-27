import SwiftUI
import SwiftData

struct WorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var audioEngine = AudioEngine()
    @State private var liveTranscriber = LiveTranscriber()

    /// The active meeting being recorded or viewed.
    @State private var activeMeeting: Meeting?
    @State private var meetingTitle: String = ""
    @State private var personalNotesText: String = ""

    // Panel visibility state
    @State private var transcriptVisible: Bool = true
    @State private var aiNotesVisible: Bool = true
    @State private var personalNotesVisible: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            // Three-panel workspace
            HStack(spacing: 4) {
                // Transcript panel
                CollapsiblePanel(
                    title: "Transcript",
                    systemImage: "mic.fill",
                    isVisible: $transcriptVisible
                ) {
                    TranscriptPanel(segments: currentSegments)
                        .environment(\.collapsiblePanelWrapped, true)
                }

                // AI Notes panel
                CollapsiblePanel(
                    title: "AI Notes",
                    systemImage: "brain",
                    isVisible: $aiNotesVisible
                ) {
                    AINotesPanel(aiNotes: activeMeeting?.aiNotes)
                }

                // Personal Notes panel
                CollapsiblePanel(
                    title: "Notes",
                    systemImage: "pencil.line",
                    isVisible: $personalNotesVisible
                ) {
                    PersonalNotesPanel(
                        notesText: $personalNotesText,
                        elapsedSeconds: audioEngine.elapsedSeconds
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Meeting header bar at the bottom
            MeetingHeaderBar(
                meetingTitle: $meetingTitle,
                elapsedSeconds: audioEngine.elapsedSeconds,
                status: activeMeeting?.status ?? (audioEngine.isRecording ? .recording : .done),
                isRecording: audioEngine.isRecording,
                audioLevel: audioEngine.audioLevel,
                onToggleRecording: {
                    if audioEngine.isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
            )
        }
        .animation(.easeInOut(duration: 0.25), value: transcriptVisible)
        .animation(.easeInOut(duration: 0.25), value: aiNotesVisible)
        .animation(.easeInOut(duration: 0.25), value: personalNotesVisible)
        .onAppear {
            liveTranscriber.requestAuthorization()
        }
        .onChange(of: transcriptVisible) { _, _ in savePanelState() }
        .onChange(of: aiNotesVisible) { _, _ in savePanelState() }
        .onChange(of: personalNotesVisible) { _, _ in savePanelState() }
        .onChange(of: meetingTitle) { _, newValue in
            activeMeeting?.title = newValue
            activeMeeting?.updatedAt = Date()
        }
        .onChange(of: personalNotesText) { _, newValue in
            savePersonalNotes(newValue)
        }
    }

    // MARK: - Computed

    private var currentSegments: [TranscriptSegment] {
        if audioEngine.isRecording {
            return liveTranscriber.liveSegments
        }
        return activeMeeting?.transcript ?? []
    }

    // MARK: - Recording

    private func startRecording() {
        audioEngine.audioBufferHandler = { [liveTranscriber] buffer in
            liveTranscriber.appendBuffer(buffer)
        }

        let meetingID = audioEngine.startRecording()
        liveTranscriber.start()

        let title = "Meeting \(formattedDate)"
        meetingTitle = title
        personalNotesText = ""

        // Reset panel state to defaults for new meeting
        transcriptVisible = true
        aiNotesVisible = true
        personalNotesVisible = true

        let meeting = Meeting(
            id: meetingID,
            title: title,
            date: Date(),
            startTime: Date(),
            status: .recording,
            micPath: AudioEngine.micPath(for: meetingID)
        )
        modelContext.insert(meeting)
        activeMeeting = meeting

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
        let finalSegments = liveTranscriber.liveSegments

        liveTranscriber.stop()
        audioEngine.stopRecording()

        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == meetingID }
        )
        if let meeting = try? modelContext.fetch(descriptor).first {
            meeting.endTime = Date()
            meeting.durationSeconds = elapsed
            meeting.status = .done
            meeting.transcript = finalSegments
            meeting.title = meetingTitle
            meeting.updatedAt = Date()
            activeMeeting = meeting
            do {
                try modelContext.save()
            } catch {
                audioEngine.error = "Failed to update meeting: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Panel State Persistence

    private func savePanelState() {
        guard let meeting = activeMeeting else { return }
        meeting.panelState = PanelState(
            transcriptVisible: transcriptVisible,
            aiNotesVisible: aiNotesVisible,
            personalNotesVisible: personalNotesVisible
        )
        meeting.updatedAt = Date()
    }

    private func restorePanelState(from meeting: Meeting) {
        let state = meeting.panelState
        transcriptVisible = state.transcriptVisible
        aiNotesVisible = state.aiNotesVisible
        personalNotesVisible = state.personalNotesVisible
        meetingTitle = meeting.title

        // Restore personal notes text from meeting's personalNotes
        personalNotesText = meeting.personalNotes
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.text)
            .joined(separator: "\n")
    }

    private func savePersonalNotes(_ text: String) {
        guard let meeting = activeMeeting else { return }
        // Store as a single PersonalNote for simplicity
        if meeting.personalNotes.isEmpty {
            let note = PersonalNote(
                id: UUID(),
                text: text,
                timestamp: Double(audioEngine.elapsedSeconds),
                createdAt: Date()
            )
            meeting.personalNotes = [note]
        } else {
            meeting.personalNotes[0].text = text
        }
        meeting.updatedAt = Date()
    }

    // MARK: - Public API for external meeting loading

    func loadMeeting(_ meeting: Meeting) {
        activeMeeting = meeting
        restorePanelState(from: meeting)
    }

    // MARK: - Helpers

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}

// MARK: - Environment Key for TranscriptPanel wrapped detection

private struct CollapsiblePanelWrappedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var collapsiblePanelWrapped: Bool {
        get { self[CollapsiblePanelWrappedKey.self] }
        set { self[CollapsiblePanelWrappedKey.self] = newValue }
    }
}
