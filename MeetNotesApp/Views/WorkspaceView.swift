import SwiftUI
import SwiftData

struct WorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var audioEngine = AudioEngine()
    @State private var liveTranscriber = LiveTranscriber()
    @State private var whisperTranscriber = WhisperTranscriber()
    @State private var summaryEngine = SummaryEngine()

    /// Optional meeting passed in for viewing/resuming an existing meeting.
    var meeting: Meeting?
    /// Callback to return to the dashboard.
    var onReturnToDashboard: (() -> Void)?

    /// The active meeting being recorded or viewed.
    @State private var activeMeeting: Meeting?
    @State private var meetingTitle: String = ""

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
                    AINotesPanel(
                        aiNotes: activeMeeting?.aiNotes,
                        summary: activeMeeting?.summary,
                        isSummarizing: summaryEngine.isProcessing,
                        summaryError: summaryEngine.error
                    )
                }

                // Personal Notes panel
                CollapsiblePanel(
                    title: "Notes",
                    systemImage: "pencil.line",
                    isVisible: $personalNotesVisible
                ) {
                    PersonalNotesPanel(
                        notes: Binding(
                            get: { activeMeeting?.personalNotes ?? [] },
                            set: { newNotes in
                                activeMeeting?.personalNotes = newNotes
                            }
                        ),
                        elapsedSeconds: audioEngine.elapsedSeconds,
                        onSave: { savePersonalNotes() }
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
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = audioEngine.error ?? liveTranscriber.error ?? whisperTranscriber.error ?? summaryEngine.error {
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
                    whisperTranscriber.error = nil
                    summaryEngine.error = nil
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

        // Whisper transcription progress banner
        if whisperTranscriber.isProcessing {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text(whisperTranscriber.downloadManager.isDownloading
                         ? "Downloading model..."
                         : "Transcribing with whisper.cpp...")
                        .font(.subheadline.weight(.medium))

                    ProgressView(value: Double(whisperTranscriber.progress))
                        .progressViewStyle(.linear)
                        .tint(.orange)

                    Text("\(Int(whisperTranscriber.progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    whisperTranscriber.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel transcription")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
        }
    }

    // MARK: - Computed

    private var currentSegments: [TranscriptSegment] {
        if audioEngine.isRecording {
            return liveTranscriber.liveSegments
        }
        // While transcribing, keep showing live segments so UI isn't empty
        if whisperTranscriber.isProcessing {
            return activeMeeting?.transcript ?? []
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
        let liveSegments = liveTranscriber.liveSegments

        liveTranscriber.stop()
        audioEngine.stopRecording()

        let descriptor = FetchDescriptor<Meeting>(
            predicate: #Predicate { $0.id == meetingID }
        )
        guard let savedMeeting = try? modelContext.fetch(descriptor).first else { return }

        // Save live transcript and transition to transcribing
        savedMeeting.endTime = Date()
        savedMeeting.durationSeconds = elapsed
        savedMeeting.transcript = liveSegments
        savedMeeting.title = meetingTitle
        savedMeeting.status = .transcribing
        savedMeeting.updatedAt = Date()
        activeMeeting = savedMeeting
        try? modelContext.save()

        // Run whisper.cpp final transcription in background
        let micPath = AudioEngine.micPath(for: meetingID)
        Task {
            await runWhisperTranscription(
                meeting: savedMeeting,
                audioPath: micPath,
                liveSegments: liveSegments
            )
        }
    }

    /// Run whisper.cpp on the recorded audio, then update the meeting.
    /// Falls back to keeping the live transcript if whisper returns no segments.
    private func runWhisperTranscription(
        meeting: Meeting,
        audioPath: String,
        liveSegments: [TranscriptSegment]
    ) async {
        let whisperSegments = await whisperTranscriber.transcribe(audioPath: audioPath)

        // If whisper produced segments, replace the live transcript; otherwise keep it
        if !whisperSegments.isEmpty {
            meeting.transcript = whisperSegments
        }
        // else: keep liveSegments already stored on the meeting

        meeting.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            audioEngine.error = "Failed to save final transcript: \(error.localizedDescription)"
        }

        // Run LLM summarization on the final transcript
        await runSummarization(meeting: meeting)

        // Return to dashboard after summarization completes
        onReturnToDashboard?()
    }

    // MARK: - Summarization

    /// Build a plain-text transcript from segments and run the LLM summary engine.
    private func runSummarization(meeting: Meeting) async {
        let segments = meeting.transcript
        guard !segments.isEmpty else {
            meeting.status = .done
            meeting.updatedAt = Date()
            try? modelContext.save()
            return
        }

        meeting.status = .summarizing
        meeting.updatedAt = Date()
        try? modelContext.save()

        // Build plain-text transcript from segments
        let transcriptText = segments.map { segment in
            "[\(segment.speaker)] \(segment.text)"
        }.joined(separator: "\n")

        let settings = AppSettings.current(in: modelContext)

        do {
            let summary = try await summaryEngine.summarize(
                transcript: transcriptText,
                settings: settings
            )
            meeting.summary = summary
            meeting.status = .done
        } catch {
            // Summarization failure is non-fatal; meeting is still usable
            meeting.status = .done
            meeting.error = error.localizedDescription
        }

        meeting.updatedAt = Date()
        activeMeeting = meeting

        do {
            try modelContext.save()
        } catch {
            audioEngine.error = "Failed to save summary: \(error.localizedDescription)"
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
    }

    private func savePersonalNotes() {
        guard let meeting = activeMeeting else { return }
        meeting.updatedAt = Date()
        try? modelContext.save()
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
