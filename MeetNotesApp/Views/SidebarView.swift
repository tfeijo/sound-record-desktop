import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Binding var selectedMeeting: Meeting?
    var onSelectMeeting: ((Meeting) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onStartRecording: (() -> Void)?

    @State private var searchText = ""
    @State private var meetingToDelete: Meeting?
    @State private var showDeleteConfirmation = false

    private var filteredMeetings: [Meeting] {
        if searchText.isEmpty {
            return meetings
        }
        return meetings.filter { meeting in
            let name = meeting.title.isEmpty ? "Untitled Meeting" : meeting.title
            return name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List(selection: $selectedMeeting) {
            if meetings.isEmpty {
                emptyState
            } else if filteredMeetings.isEmpty {
                noSearchResults
            } else {
                ForEach(filteredMeetings) { meeting in
                    Button {
                        onSelectMeeting?(meeting)
                    } label: {
                        MeetingCard(meeting: meeting)
                    }
                    .buttonStyle(.plain)
                    .tag(meeting)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            meetingToDelete = meeting
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            meetingToDelete = meeting
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Meeting", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search meetings")
        .alert(
            "Delete Meeting?",
            isPresented: $showDeleteConfirmation,
            presenting: meetingToDelete
        ) { meeting in
            Button("Cancel", role: .cancel) {
                meetingToDelete = nil
            }
            Button("Delete", role: .destructive) {
                deleteMeeting(meeting)
                meetingToDelete = nil
            }
        } message: { meeting in
            let name = meeting.title.isEmpty ? "Untitled Meeting" : meeting.title
            Text("Are you sure you want to delete \"\(name)\"? This will also remove associated audio files. This action cannot be undone.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    onStartRecording?()
                }) {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start a new recording")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    onOpenSettings?()
                } label: {
                    Label("Settings", systemImage: "gear")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Spacer()
            }
            .background(.bar)
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("No meetings yet.\nClick Record to start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var noSearchResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No meetings match\n\"\(searchText)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
        .listRowSeparator(.hidden)
    }

    // MARK: - Deletion

    private func deleteMeeting(_ meeting: Meeting) {
        // Remove audio files from disk
        deleteAudioFiles(for: meeting)

        // If the deleted meeting is currently selected, clear selection
        if selectedMeeting?.id == meeting.id {
            selectedMeeting = nil
        }

        // Remove from SwiftData
        modelContext.delete(meeting)
        try? modelContext.save()
    }

    private func deleteAudioFiles(for meeting: Meeting) {
        let fileManager = FileManager.default

        // Delete mic audio file
        let micPath = AudioEngine.micPath(for: meeting.id)
        if fileManager.fileExists(atPath: micPath) {
            try? fileManager.removeItem(atPath: micPath)
        }

        // Delete system audio file
        let systemPath = AudioEngine.systemPath(for: meeting.id)
        if fileManager.fileExists(atPath: systemPath) {
            try? fileManager.removeItem(atPath: systemPath)
        }

        // Also try paths stored on the meeting model itself
        if let storedMicPath = meeting.micPath, fileManager.fileExists(atPath: storedMicPath) {
            try? fileManager.removeItem(atPath: storedMicPath)
        }
        if let storedSystemPath = meeting.systemPath, fileManager.fileExists(atPath: storedSystemPath) {
            try? fileManager.removeItem(atPath: storedSystemPath)
        }
    }
}

// MARK: - Meeting Card

private struct MeetingCard: View {
    let meeting: Meeting

    private var displayTitle: String {
        meeting.title.isEmpty ? "Untitled Meeting" : meeting.title
    }

    private var formattedDuration: String {
        let minutes = meeting.durationSeconds / 60
        let seconds = meeting.durationSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: meeting.date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title and status badge
            HStack {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                StatusBadge(status: meeting.status)
            }

            // Metadata row
            HStack(spacing: 12) {
                // Date
                Label(formattedDate, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Duration
                if meeting.durationSeconds > 0 {
                    Label(formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Speaker count
                if meeting.speakerCount > 0 {
                    Label(
                        "\(meeting.speakerCount)",
                        systemImage: meeting.speakerCount == 1 ? "person" : "person.2"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: MeetingStatus

    private var color: Color {
        switch status {
        case .recording:
            return .red
        case .transcribing:
            return .orange
        case .summarizing:
            return .orange
        case .done:
            return .green
        case .error:
            return .red
        }
    }

    private var label: String {
        switch status {
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .summarizing:
            return "Summarizing"
        case .done:
            return "Done"
        case .error:
            return "Error"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)

            Text(label)
                .font(.caption2)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
    }
}
