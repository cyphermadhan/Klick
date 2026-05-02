import SwiftUI

/// Box with a hairline border and small all-caps title that sits on the top
/// edge — the "┌─ PEERS ─" look of old terminal UIs.
struct TerminalFrame<Content: View>: View {
    let title: String?
    let accent: Color
    @ViewBuilder var content: Content

    init(_ title: String? = nil, accent: Color = DT.border, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DT.tileCorner)
                .strokeBorder(accent, lineWidth: 1)

            if let title {
                Text(title)
                    .walkieLabel(10)
                    .foregroundStyle(DT.textDim)
                    .padding(.horizontal, 6)
                    .background(DT.bg)
                    .offset(x: 14, y: -6)
            }

            content
                .padding(DT.framePad)
                .padding(.top, title == nil ? 0 : 2)
        }
    }
}

/// Fixed-width row of small squares, filled left-to-right according to `level`
/// in `[0, 1]`. The active color is `fill`, the dim color lives in the
/// design tokens.
struct PixelBar: View {
    let level: Double
    var cells: Int = 24
    var fill: Color = DT.tx
    var cellSize: CGFloat = 6
    var spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            let active = Int((level.clamped(to: 0...1)) * Double(cells) + 0.5)
            ForEach(0..<cells, id: \.self) { i in
                Rectangle()
                    .fill(i < active ? fill : DT.textFaint)
                    .frame(width: cellSize, height: cellSize)
            }
        }
    }
}

/// Row of `cells` squares where each cell has a random 0/1 "pulse" state, used
/// as a VU-meter-like activity indicator while transmitting. Deterministic per
/// tick so it animates with the parent's state.
struct ActivityBar: View {
    /// 0 = silent (all dim), 1 = fully lit.
    var intensity: Double
    var cells: Int = 24
    var seed: UInt64 = 0
    var fill: Color = DT.tx
    var cellSize: CGFloat = 6
    var spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<cells, id: \.self) { i in
                Rectangle()
                    .fill(isLit(i) ? fill : DT.textFaint)
                    .frame(width: cellSize, height: cellSize)
            }
        }
    }

    private func isLit(_ i: Int) -> Bool {
        // Deterministic pseudo-random pattern from the seed.
        let h = (seed &* 2654435761) ^ UInt64(i &* 11)
        let normalized = Double(h & 0xFF) / 255.0
        return normalized < intensity
    }
}

/// "LABEL ................. VALUE" dot-leader row. Fixed mono font so dots
/// line up between rows without manual alignment.
struct DotLeader: View {
    let label: String
    let value: String
    var valueColor: Color = DT.text
    var labelColor: Color = DT.textDim

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .walkieLabel(11, weight: .regular)
                .foregroundStyle(labelColor)
            // The leader itself — an endless string of dots clipped by the row.
            GeometryReader { geo in
                Text(String(repeating: ".", count: max(4, Int(geo.size.width / 4))))
                    .font(DT.mono(11))
                    .foregroundStyle(DT.textFaint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: 3)
            }
            .frame(height: 14)
            Text(value)
                .font(DT.mono(11, weight: .semibold))
                .foregroundStyle(valueColor)
        }
    }
}

/// Status tile with icon, bold label, and tiny subtitle — the MPC "BPM /
/// DISPLAY BPM" layout. Optional accent tint lights the tile up when active.
struct StatusTile<Icon: View>: View {
    let title: String
    let subtitle: String
    var accent: Color = DT.text
    var active: Bool = false
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle()
                    .fill(active ? accent.opacity(0.15) : DT.panel)
                    .overlay(
                        Rectangle()
                            .strokeBorder(active ? accent : DT.border, lineWidth: 1)
                    )
                icon()
                    .foregroundStyle(active ? accent : DT.text)
            }
            .frame(height: 56)

            Text(title)
                .walkieLabel(12)
                .foregroundStyle(active ? accent : DT.text)

            Text(subtitle)
                .walkieCaption()
                .foregroundStyle(DT.textDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Utilities

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
