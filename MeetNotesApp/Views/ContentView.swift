import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMeeting: Meeting?
    @State private var showWorkspace = false
    @State private var showSettings = false

    // Meet auto-detection
    @State private var meetDetector = MeetDetector()
    @State private var autoRecordingActive = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedMeeting: $selectedMeeting,
                onSelectMeeting: { meeting in
                    selectedMeeting = meeting
                    showSettings = false
                    showWorkspace = true
                },
                onOpenSettings: {
                    withAnimation {
                        showWorkspace = false
                        selectedMeeting = nil
                        showSettings = true
                    }
                },
                onStartRecording: {
                    withAnimation {
                        showSettings = false
                        selectedMeeting = nil
                        showWorkspace = true
                    }
                }
            )
        } detail: {
            if showSettings {
                SettingsView()
            } else if showWorkspace {
                WorkspaceView(
                    meeting: selectedMeeting,
                    onReturnToDashboard: {
                        withAnimation {
                            showWorkspace = false
                            selectedMeeting = nil
                        }
                    }
                )
            } else {
                DashboardView(onStartRecording: {
                    withAnimation {
                        selectedMeeting = nil
                        showWorkspace = true
                    }
                })
            }
        }
        .navigationTitle("MeetNotes")
        .overlay(alignment: .topTrailing) {
            if meetDetector.isDetected {
                meetDetectedBanner
            }
        }
        .onAppear {
            startAutoDetectionIfEnabled()
        }
        .onChange(of: meetDetector.isDetected) { _, detected in
            handleMeetDetectionChange(detected: detected)
        }
    }

    // MARK: - Meet Detection Banner

    private var meetDetectedBanner: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            Image(systemName: "video.fill")
                .font(.caption)
            Text(autoRecordingActive
                 ? "Auto-recording: Google Meet"
                 : "Google Meet detected")
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.green.opacity(0.15))
        .clipShape(Capsule())
        .padding(8)
    }

    // MARK: - Auto-Detection Logic

    private func startAutoDetectionIfEnabled() {
        let settings = AppSettings.current(in: modelContext)
        if settings.autoRecord {
            meetDetector.startMonitoring()
        }
    }

    private func handleMeetDetectionChange(detected: Bool) {
        let settings = AppSettings.current(in: modelContext)
        guard settings.autoRecord else { return }

        // Don't interfere with manual recording
        guard !showWorkspace else { return }

        if detected && !autoRecordingActive {
            // Auto-start recording
            autoRecordingActive = true
            withAnimation {
                showSettings = false
                selectedMeeting = nil
                showWorkspace = true
            }
        } else if !detected && autoRecordingActive {
            // Meet session ended — the WorkspaceView will handle stop
            autoRecordingActive = false
        }
    }
}
