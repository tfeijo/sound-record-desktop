import SwiftUI

struct CollapsiblePanel<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isVisible: Bool
    @ViewBuilder let content: () -> Content

    private let collapsedWidth: CGFloat = 30

    var body: some View {
        if isVisible {
            expandedView
        } else {
            collapsedView
        }
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    isVisible = false
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Collapse panel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Panel content
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        )
    }

    // MARK: - Collapsed

    private var collapsedView: some View {
        VStack(spacing: 8) {
            Button {
                isVisible = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Expand \(title)")

            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(-90))
                .fixedSize()
        }
        .frame(width: collapsedWidth)
        .frame(maxHeight: .infinity)
        .padding(.vertical, 8)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        )
    }
}
