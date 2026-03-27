import SwiftUI

struct PersonalNotesPanel: View {
    @Binding var notes: [PersonalNote]
    let elapsedSeconds: Int
    let onSave: () -> Void

    @State private var newNoteText: String = ""
    @State private var editingNoteID: UUID?
    @State private var editingText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Note input area
            noteInputBar

            Divider()

            // Notes list
            if notes.isEmpty {
                emptyState
            } else {
                notesList
            }
        }
    }

    // MARK: - Input Bar

    private var noteInputBar: some View {
        HStack(spacing: 8) {
            timestampBadge(seconds: elapsedSeconds)

            TextField("Add a note...", text: $newNoteText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isInputFocused)
                .onSubmit {
                    addNote()
                }

            Button {
                addNote()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add note (Enter)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "note.text")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No notes yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Type above and press Enter to add a timestamped note")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Notes List

    private var notesList: some View {
        List {
            ForEach(sortedNotes) { note in
                if editingNoteID == note.id {
                    editingRow(note: note)
                } else {
                    noteRow(note: note)
                }
            }
            .onDelete(perform: deleteNotes)
        }
        .listStyle(.plain)
    }

    private var sortedNotes: [PersonalNote] {
        notes.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Note Row

    private func noteRow(note: PersonalNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            timestampBadge(seconds: Int(note.timestamp))

            Text(note.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)

            Button {
                beginEditing(note)
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit note")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit") { beginEditing(note) }
            Button("Delete", role: .destructive) { deleteNote(note) }
        }
    }

    // MARK: - Editing Row

    private func editingRow(note: PersonalNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            timestampBadge(seconds: Int(note.timestamp))

            TextField("Edit note...", text: $editingText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit {
                    commitEdit(for: note)
                }

            HStack(spacing: 4) {
                Button {
                    commitEdit(for: note)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Save edit")

                Button {
                    cancelEdit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel edit")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Timestamp Badge

    private func timestampBadge(seconds: Int) -> some View {
        let minutes = seconds / 60
        let secs = seconds % 60
        return Text(String(format: "%02d:%02d", minutes, secs))
            .font(.caption.monospaced())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.8))
            )
    }

    // MARK: - Actions

    private func addNote() {
        let trimmed = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let note = PersonalNote(
            id: UUID(),
            text: trimmed,
            timestamp: Double(elapsedSeconds),
            createdAt: Date()
        )
        notes.append(note)
        newNoteText = ""
        onSave()
        isInputFocused = true
    }

    private func beginEditing(_ note: PersonalNote) {
        editingNoteID = note.id
        editingText = note.text
    }

    private func commitEdit(for note: PersonalNote) {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteNote(note)
            return
        }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index].text = trimmed
        }
        editingNoteID = nil
        editingText = ""
        onSave()
    }

    private func cancelEdit() {
        editingNoteID = nil
        editingText = ""
    }

    private func deleteNote(_ note: PersonalNote) {
        notes.removeAll { $0.id == note.id }
        if editingNoteID == note.id {
            editingNoteID = nil
            editingText = ""
        }
        onSave()
    }

    private func deleteNotes(at offsets: IndexSet) {
        let sorted = sortedNotes
        let idsToRemove = offsets.map { sorted[$0].id }
        notes.removeAll { idsToRemove.contains($0.id) }
        onSave()
    }
}
