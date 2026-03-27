import SwiftUI

struct ContentView: View {
    @State private var showWorkspace = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if showWorkspace {
                WorkspaceView()
            } else {
                DashboardView(onStartRecording: {
                    withAnimation {
                        showWorkspace = true
                    }
                })
            }
        }
        .navigationTitle("MeetNotes")
    }
}
