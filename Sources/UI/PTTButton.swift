import SwiftUI

/// Hold-to-talk transmit tile.
///
/// Styled after the MPC "ERASE"/"SYSTEM" pills: square corners, hard color,
/// bold mono label, tiny explainer subtitle. VU-style pixel bars flank it
/// top and bottom and come alive while the user is holding to talk.
struct PTTButton: View {
    let isTransmitting: Bool
    let isEnabled: Bool
    let outboundLevel: Double
    let inboundLevel: Double
    let onBegin: () -> Void
    let onEnd: () -> Void

    // Re-randomize the activity bar pattern at ~30 Hz while transmitting.
    @State private var tick: UInt64 = 0
    private let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            meterRow(label: "TX", level: outboundLevel, color: DT.tx, lit: isTransmitting)
            tile
            meterRow(label: "RX", level: inboundLevel, color: DT.info, lit: inboundLevel > 0.02)
        }
        .opacity(isEnabled ? 1 : 0.35)
    }

    // MARK: - Tile

    private var tile: some View {
        ZStack {
            Rectangle()
                .fill(isTransmitting ? DT.tx : DT.panel)
                .overlay(
                    Rectangle()
                        .strokeBorder(isTransmitting ? DT.tx : DT.border, lineWidth: 1)
                )
                .overlay(hazardStripes)

            VStack(spacing: 8) {
                Text(isTransmitting ? "TRANSMITTING" : "TRANSMIT")
                    .walkieLabel(22, weight: .heavy, tracking: 3)
                    .foregroundStyle(.white)
                Text(isTransmitting ? "LIT WHEN KEYED" : "HOLD TO TALK")
                    .walkieCaption()
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .frame(height: 132)
        .scaleEffect(isTransmitting ? 0.98 : 1.0)
        .animation(.easeOut(duration: 0.08), value: isTransmitting)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled else { return }
                    if !isTransmitting { onBegin() }
                }
                .onEnded { _ in
                    if isTransmitting { onEnd() }
                }
        )
        .accessibilityLabel(isTransmitting ? "Transmitting" : "Push to talk")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Meter row

    private func meterRow(label: String, level: Double, color: Color, lit: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .walkieLabel(10)
                .foregroundStyle(DT.textDim)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                let cellSize: CGFloat = 6
                let spacing: CGFloat = 2
                let count = max(1, Int((geo.size.width + spacing) / (cellSize + spacing)))
                ActivityBar(
                    intensity: lit ? max(0.05, level) : 0,
                    cells: count,
                    seed: tick,
                    fill: color,
                    cellSize: cellSize,
                    spacing: spacing
                )
            }
            .frame(height: 6)
            Text(format(level))
                .walkieLabel(10, weight: .regular)
                .foregroundStyle(lit ? color : DT.textDim)
                .frame(width: 28, alignment: .trailing)
        }
        .onReceive(timer) { _ in
            // Cheap: tick is only used as an RNG seed for the activity pattern.
            tick &+= 1
        }
    }

    private func format(_ level: Double) -> String {
        let pct = Int((level * 99).rounded())
        return String(format: "%02d", pct)
    }

    // MARK: - Hazard stripes (MPC "ERASE" style)

    private var hazardStripes: some View {
        // Slash-pattern overlay on the right edge — mirrors the "ERASE" button.
        GeometryReader { geo in
            let stripeWidth: CGFloat = 10
            let count = Int(geo.size.height / stripeWidth) + 4
            Canvas { ctx, size in
                let opacity: Double = isTransmitting ? 0.25 : 0.08
                for i in 0..<count {
                    var path = Path()
                    let x = size.width - 40 + CGFloat(i) * stripeWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + stripeWidth, y: 0))
                    path.addLine(to: CGPoint(x: x - size.height + stripeWidth, y: size.height))
                    path.addLine(to: CGPoint(x: x - size.height, y: size.height))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.white.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    VStack(spacing: 40) {
        PTTButton(isTransmitting: false, isEnabled: true,
                  outboundLevel: 0, inboundLevel: 0,
                  onBegin: {}, onEnd: {})
        PTTButton(isTransmitting: true, isEnabled: true,
                  outboundLevel: 0.6, inboundLevel: 0.0,
                  onBegin: {}, onEnd: {})
        PTTButton(isTransmitting: false, isEnabled: false,
                  outboundLevel: 0, inboundLevel: 0,
                  onBegin: {}, onEnd: {})
    }
    .padding()
    .background(DT.bg)
}
