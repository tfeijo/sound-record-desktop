import SwiftUI

struct SidebarView: View {
    var body: some View {
        List {
            Text("No meetings yet")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    // TODO: Start recording
                }) {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start a new recording")
            }
        }
    }
}