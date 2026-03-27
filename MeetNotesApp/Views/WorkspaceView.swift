import SwiftUI
import SwiftData

struct WorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var audioEngine = AudioEngine()
    @State private var liveTranscriber = LiveTranscriber()

    /// Optional meeting passed in for viewing/resuming an existing meeting.
    var meeting: Meeting?
    /// Callback to return to the dashboard.
    var onReturnToDashboard: (() -> Void)?

    /// The active meeting being recorded or viewed.
    @State private var activeMeeting: Meeting?
    @State private var meetingTitle: String = ""
    @State private var personalNotesText: String = ""

    // Panel visibility state
    @State private var transcriptVisible: Bool = true
    @State private var aiNotesVisible: Bool = true
    @State private var personalNotesVisible: Bool = true

    // MARK: - Date Formatter

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            errorBanner

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
            if let meeting {
                loadMeeting(meeting)
            }
        }
        .onChange(of: transcriptVisible) { _, _ in savePanelState() }
        .onChange(of: aiNotesVisible) { _, _ in savePanelState() }
        .onChange(of: personalNotesVisible) { _, _ in savePanelState() }
        .onChange(of: meetingTitle) { _, newValue in
            guard activeMeeting != nil else { return }
            activeMeeting?.title = newValue
            activeMeeting?.updatedAt = Date()
            try? modelContext.save()
        }
        .onChange(of: personalNotesText) { _, newValue in
            savePersonalNotes(newValue)
        }
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = audioEngine.error ?? liveTranscriber.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                Button {
                    audioEngine.error = nil
                    liveTranscriber.error = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red)
        }

        if let warning = audioEngine.systemAudioWarning {
            HStack(spacing: 8) {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(.black)
                Text(warning)
                    .font(.subheadline)
                    .foregroundStyle(.black)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.9))
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

        let title = "Meeting \(Self.dateFormatter.string(from: Date()))"
        meetingTitle = title
        personalNotesText = ""

        // Reset panel state to defaults for new meeting
        transcriptVisible = true
        aiNotesVisible = true
        personalNotesVisible = true

        let newMeeting = Meeting(
            id: meetingID,
            title: title,
            date: Date(),
            startTime: Date(),
            status: .recording,
            micPath: AudioEngine.micPath(for: meetingID),
            systemPath: audioEngine.systemAudioWarning == nil ? AudioEngine.systemPath(for: meetingID) : nil
        )
        modelContext.insert(newMeeting)
        activeMeeting = newMeeting

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
        if let savedMeeting = try? modelContext.fetch(descriptor).first {
            savedMeeting.endTime = Date()
            savedMeeting.durationSeconds = elapsed
            savedMeeting.status = .done
            savedMeeting.transcript = finalSegments
            savedMeeting.title = meetingTitle
            savedMeeting.updatedAt = Date()
            activeMeeting = savedMeeting
            do {
                try modelContext.save()
            } catch {
                audioEngine.error = "Failed to update meeting: \(error.localizedDescription)"
            }
        }

        // Return to dashboard after stopping
        onReturnToDashboard?()
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
        // Always replace entire personalNotes array with a single note
        let note = PersonalNote(
            id: meeting.personalNotes.first?.id ?? UUID(),
            text: text,
            timestamp: Double(audioEngine.elapsedSeconds),
            createdAt: meeting.personalNotes.first?.createdAt ?? Date()
        )
        meeting.personalNotes = [note]
        meeting.updatedAt = Date()
    }

    // MARK: - Meeting Loading

    func loadMeeting(_ meeting: Meeting) {
        activeMeeting = meeting
        restorePanelState(from: meeting)
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
