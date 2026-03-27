import SwiftUI

struct AudioLevelMeter: View {
    /// Audio level from 0.0 (silence) to 1.0 (loud).
    let level: Float

    /// Number of segments in the meter bar.
    private let segmentCount = 20

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { index in
                let threshold = Float(index) / Float(segmentCount)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: index).opacity(level > threshold ? 1.0 : 0.15))
                    .frame(height: 12)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func color(for index: Int) -> Color {
        let ratio = Double(index) / Double(segmentCount)
        if ratio < 0.6 {
            return .green
        } else if ratio < 0.8 {
            return .yellow
        } else {
            return .red
        }
    }
}
