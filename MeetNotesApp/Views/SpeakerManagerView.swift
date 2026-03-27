import SwiftUI
import SwiftData

/// CRUD view for managing speaker profiles.
/// Accessible from SettingsView. Lists enrolled speakers with name and date,
/// supports add/rename/delete. Speaker matching is architecture-ready
/// (requires CoreML model for real embedding extraction).
struct SpeakerManagerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SpeakerProfile.name) private var profiles: [SpeakerProfile]

    @State private var showAddSheet = false
    @State private var editingProfile: SpeakerProfile?
    @State private var deleteTarget: SpeakerProfile?
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if profiles.isEmpty {
                emptyState
            } else {
                profileList
            }
        }
        .navigationTitle("Speaker Profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Speaker", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSpeakerSheet { name in
                addSpeaker(name: name)
            }
        }
        .sheet(item: $editingProfile) { profile in
            EditSpeakerSheet(profile: profile) { newName in
                renameSpeaker(profile, to: newName)
            }
        }
        .confirmationDialog(
            "Delete Speaker Profile?",
            isPresented: $showDeleteConfirmation,
            presenting: deleteTarget
        ) { profile in
            Button("Delete", role: .destructive) {
                deleteSpeaker(profile)
            }
        } message: { profile in
            Text("Delete \"\(profile.name)\"? This cannot be undone.")
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Speaker Profiles")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Add speaker profiles to identify voices in recordings.\nSpeaker matching requires a CoreML model (coming soon).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button {
                showAddSheet = true
            } label: {
                Label("Add Speaker", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var profileList: some View {
        List {
            ForEach(profiles) { profile in
                SpeakerProfileRow(profile: profile)
                    .contextMenu {
                        Button {
                            editingProfile = profile
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteTarget = profile
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteTarget = profile
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    // MARK: - Actions

    private func addSpeaker(name: String) {
        let profile = SpeakerProfile(name: name)
        modelContext.insert(profile)
        try? modelContext.save()
    }

    private func renameSpeaker(_ profile: SpeakerProfile, to newName: String) {
        profile.name = newName
        try? modelContext.save()
    }

    private func deleteSpeaker(_ profile: SpeakerProfile) {
        modelContext.delete(profile)
        try? modelContext.save()
    }
}

// MARK: - Speaker Profile Row

private struct SpeakerProfileRow: View {
    let profile: SpeakerProfile

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? "Unnamed" : profile.name)
                    .font(.body)
                Text("Added \(Self.dateFormatter.string(from: profile.createdAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if profile.embeddingData != nil {
                Image(systemName: "waveform.badge.checkmark")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .help("Voice embedding enrolled")
            } else {
                Image(systemName: "waveform.badge.minus")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("No voice embedding — name-only profile")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Speaker Sheet

private struct AddSpeakerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    let onSave: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Speaker Profile")
                .font(.headline)

            TextField("Speaker Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            Text("Voice embedding enrollment will be available when CoreML model is integrated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Add") {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onSave(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - Edit Speaker Sheet

private struct EditSpeakerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: SpeakerProfile
    let onSave: (String) -> Void
    @State private var name: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Speaker")
                .font(.headline)

            TextField("Speaker Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    onSave(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { name = profile.name }
    }
}
