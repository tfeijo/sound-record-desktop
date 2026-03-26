import SwiftUI
import SwiftData

@main
struct MeetNotesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 600)
        .modelContainer(for: [
            Meeting.self,
            SpeakerProfile.self,
            AppSettings.self,
        ])
    }
}
