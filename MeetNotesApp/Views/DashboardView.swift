import SwiftUI

struct DashboardView: View {
    var onStartRecording: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text("No meeting selected")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Start a new recording or select a past meeting from the sidebar.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            if let onStartRecording {
                Button(action: onStartRecording) {
                    Label("Start Recording", systemImage: "record.circle")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
