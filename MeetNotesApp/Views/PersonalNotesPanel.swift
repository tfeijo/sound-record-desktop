import SwiftUI

struct PersonalNotesPanel: View {
    @Binding var notesText: String
    let elapsedSeconds: Int

    @State private var lastSavedText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $notesText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Footer with character count and timestamp shortcut
            HStack {
                Text("\(notesText.count) characters")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    insertTimestamp()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                        Text("Timestamp")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Insert current timestamp")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func insertTimestamp() {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        let stamp = String(format: "[%02d:%02d] ", minutes, seconds)
        if notesText.isEmpty || notesText.hasSuffix("\n") {
            notesText.append(stamp)
        } else {
            notesText.append("\n" + stamp)
        }
    }
}
