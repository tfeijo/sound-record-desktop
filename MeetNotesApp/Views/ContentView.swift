import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedMeeting: Meeting?
    @State private var showWorkspace = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedMeeting: $selectedMeeting,
                onSelectMeeting: { meeting in
                    selectedMeeting = meeting
                    showWorkspace = true
                }
            )
        } detail: {
            if showWorkspace {
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
