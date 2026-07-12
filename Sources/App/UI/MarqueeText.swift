import SwiftUI

/// Single-line text that horizontally scrolls when it overflows its container:
/// pause → glide left to reveal the end → pause → glide back → repeat.
/// Fits itself to the container's width; height comes from the font.
struct MarqueeText: View {
    let text: String
    let font: Font

    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offsetX: CGFloat = 0
    @State private var cycler: Task<Void, Never>?

    private static let pointsPerSecond: Double = 25

    var body: some View {
        // Invisible copy defines height and claims the available width.
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                boxWidth = width
                restart()
            }
            .overlay(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        textWidth = width
                        restart()
                    }
                    .offset(x: offsetX)
            }
            .clipped()
            .onChange(of: text) { _, _ in restart() }
            .onDisappear { cycler?.cancel() }
    }

    private func restart() {
        cycler?.cancel()
        withAnimation(.none) { offsetX = 0 }
        let overflow = textWidth - boxWidth
        guard overflow > 2 else { return }
        cycler = Task { @MainActor in
            let travel = Double(overflow) / Self.pointsPerSecond
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: travel)) { offsetX = -overflow }
                try? await Task.sleep(nanoseconds: UInt64((travel + 1.6) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.7)) { offsetX = 0 }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }
}
