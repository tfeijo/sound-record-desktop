import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedMeeting: Meeting?
    @State private var showWorkspace = false
    @State private var showSettings = false

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
    }
}
