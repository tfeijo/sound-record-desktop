import SwiftUI
import SwiftData

@main
struct MeetNotesApp: App {
    @State private var migrator = DataMigrator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .overlay {
                    if migrator.isProcessing {
                        migrationOverlay
                    }
                }
                .task {
                    // Run migration check on first launch
                    if let container = try? ModelContainer(for: Meeting.self, SpeakerProfile.self, AppSettings.self) {
                        let context = ModelContext(container)
                        await migrator.migrateIfNeeded(modelContext: context)
                    }
                }
        }
        .defaultSize(width: 900, height: 600)
        .modelContainer(for: [
            Meeting.self,
            SpeakerProfile.self,
            AppSettings.self,
        ])
    }

    private var migrationOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Migrating data from previous version...")
                    .font(.headline)
                ProgressView(value: migrator.progress)
                    .frame(width: 200)
                Text("\(Int(migrator.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
