import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            Text("Select a meeting or start a new recording")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("MeetNotes")
    }
}