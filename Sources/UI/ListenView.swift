import SwiftUI

/// Morse listen screen.
///
/// Opens as a sheet from Chat with a two-button mode picker. Camera
/// mode points the back camera at another phone's flashlight and
/// decodes the pulses. Audio mode listens on the mic for 600 Hz beeps.
/// Both feed into the same `MorseDemodulator` plumbing, and both append
/// decoded characters to a local buffer plus (via a callback) to the
/// session's RX scroll.
///
/// The two decoders are kept as separate `@StateObject`s so picking a
/// mode doesn't tear down the other one. Stop/start cycles are handled
/// on mode switch.
struct ListenView: View {
    /// Called with each decoded character so the caller can mirror into
    /// its own RX buffer. Optional; when nil, the view is self-contained.
    var onCharacter: ((Character) -> Void)?

    @StateObject private var flash = FlashlightDecoder()
    @StateObject private var audio = AudioToneDecoder()

    @State private var mode: Mode = .picker
    @State private var decoded: String = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 14) {
                header
                switch mode {
                case .picker:  picker
                case .flash:   cameraPane
                case .audio:   audioPane
                }
                if mode == .picker { Spacer() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .task(id: mode) {
            await switchTo(mode)
        }
        .onDisappear {
            flash.stop()
            audio.stop()
        }
        .onAppear {
            // Wire both decoders' character callbacks to the same sink.
            flash.onCharacter = { appendChar($0) }
            audio.onCharacter = { appendChar($0) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Text("◂ BACK")
                    .walkieLabel(11)
                    .foregroundStyle(DT.info)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Rectangle().strokeBorder(DT.info.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
            Text("LISTEN")
                .walkieLabel(13, weight: .heavy, tracking: 3)
                .foregroundStyle(DT.text)
            Spacer()
            Text("").frame(width: 60)
        }
    }

    // MARK: - Mode picker

    private var picker: some View {
        VStack(spacing: 14) {
            Text("PICK AN INPUT")
                .walkieLabel(11)
                .foregroundStyle(DT.textDim)
                .padding(.top, 20)

            modeButton(
                title: "CAMERA",
                subtitle: "POINT THE BACK CAMERA AT ANOTHER PHONE'S FLASHLIGHT",
                icon: "camera.fill",
                action: { mode = .flash }
            )

            modeButton(
                title: "AUDIO",
                subtitle: "HOLD THE MIC NEAR ANOTHER PHONE'S SPEAKER",
                icon: "mic.fill",
                action: { mode = .audio }
            )
        }
    }

    private func modeButton(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DT.info)
                    .frame(width: 48, height: 48)
                    .overlay(Rectangle().strokeBorder(DT.info, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .walkieLabel(13, weight: .heavy, tracking: 2)
                        .foregroundStyle(DT.text)
                    Text(subtitle)
                        .walkieCaption()
                        .foregroundStyle(DT.textDim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DT.textDim)
            }
            .padding(12)
            .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active decoder panes

    /// Active-mode caption: just a "VIA CAMERA" / "VIA AUDIO" label.
    /// SWITCH button removed — BACK already takes the user back to the
    /// mode picker, so SWITCH was a duplicate control.
    private func modeHeader(title: String) -> some View {
        HStack {
            Text("VIA \(title)")
                .walkieLabel(11)
                .foregroundStyle(DT.textDim)
            Spacer()
        }
    }

    /// Shared decoded-text panel + clear/caption row.
    private func decodedPanel(caption: String) -> some View {
        VStack(spacing: 10) {
            TerminalFrame("DECODED") {
                ScrollView {
                    Text(decoded.isEmpty ? "WAITING FOR PULSES…" : decoded)
                        .font(DT.mono(14, weight: .bold))
                        .foregroundStyle(decoded.isEmpty ? DT.textFaint : DT.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(maxHeight: 180)

            HStack {
                Button("CLEAR") { decoded.removeAll() }
                    .font(DT.mono(11, weight: .bold))
                    .tracking(DT.labelTracking)
                    .foregroundStyle(DT.warn)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(Rectangle().strokeBorder(DT.warn.opacity(0.6), lineWidth: 1))
                    .buttonStyle(.plain)
                Spacer()
                Text(caption)
                    .walkieCaption()
                    .foregroundStyle(DT.textFaint)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// CAMERA mode — live preview with a draggable reticle instead of
    /// a level bar. The decoder samples only the pixels under the
    /// reticle; the user positions it over the other phone's flashlight.
    private var cameraPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            modeHeader(title: "CAMERA")
            TerminalFrame("VIEWFINDER") {
                CameraReticleView(decoder: flash)
            }
            .frame(maxHeight: .infinity)
            decodedPanel(caption: "DRAG THE RETICLE OVER THE FLASHLIGHT.")
        }
    }

    /// AUDIO mode — still a classic level bar; no visual "aim" concept
    /// to replace it with.
    private var audioPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            modeHeader(title: "AUDIO")
            TerminalFrame("LEVEL") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(audio.signalIsOn ? DT.ok : DT.textFaint)
                            .frame(width: 8, height: 8)
                        Text(audio.signalIsOn ? "SIGNAL" : "IDLE")
                            .walkieLabel(10)
                            .foregroundStyle(audio.signalIsOn ? DT.ok : DT.textDim)
                    }
                    PixelBar(level: audio.currentLevel.clamped(to: 0...1),
                             cells: 30,
                             fill: audio.signalIsOn ? DT.ok : DT.info)
                }
            }
            .frame(height: 72)
            decodedPanel(caption: "HOLD NEAR THE SOURCE. KEEP QUIET.")
        }
    }

    // MARK: - Lifecycle

    private func appendChar(_ c: Character) {
        decoded.append(c)
        onCharacter?(c)
    }

    private func switchTo(_ newMode: Mode) async {
        switch newMode {
        case .picker:
            flash.stop()
            audio.stop()
        case .flash:
            audio.stop()
            await flash.start()
        case .audio:
            flash.stop()
            await audio.start()
        }
    }

    enum Mode { case picker, flash, audio }
}

// Local copy of the clamp helper since TerminalPrimitives hides it.
private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Camera preview with a draggable reticle overlay. Whatever rectangle
/// the user positions on the preview is what the decoder samples — so
/// this is both the "what am I pointing at" and the "decode only here"
/// surface.
///
/// Mapping assumes the preview uses `.resizeAspect` (letterboxed, set
/// in `CameraPreviewView`): in that gravity mode the visible preview
/// rect maps 1:1 to normalized video coordinates, so the normalized
/// rect we compute here == the normalized rect the decoder samples.
private struct CameraReticleView: View {
    @ObservedObject var decoder: FlashlightDecoder

    /// Reticle center in local preview coordinates. Recentered on first
    /// layout when `previewSize` goes from zero to non-zero.
    @State private var reticleCenter: CGPoint?
    /// Size of the reticle overlay on screen. A compact square so the
    /// user can target a single flashlight without including a lot of
    /// ambient room light.
    private let reticleSize: CGFloat = 90

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(session: decoder.session)

                // Reticle — drawn in the view's own coordinate space so
                // the DragGesture translation values apply directly.
                let center = reticleCenter ?? CGPoint(x: geo.size.width / 2,
                                                       y: geo.size.height / 2)
                reticleOverlay(center: center, bounds: geo.size)
            }
            .contentShape(.rect)
            .onAppear {
                if reticleCenter == nil {
                    reticleCenter = CGPoint(x: geo.size.width / 2,
                                            y: geo.size.height / 2)
                    pushSampleRect(center: reticleCenter!, bounds: geo.size)
                }
            }
            .onChange(of: geo.size) { newSize in
                // Keep the reticle proportionally placed if the preview
                // frame resizes (rotation, sheet re-present).
                if let old = reticleCenter {
                    let rx = old.x / max(1, geo.size.width)
                    let ry = old.y / max(1, geo.size.height)
                    let new = CGPoint(x: rx * newSize.width, y: ry * newSize.height)
                    reticleCenter = new
                    pushSampleRect(center: new, bounds: newSize)
                }
            }
        }
    }

    @ViewBuilder
    private func reticleOverlay(center: CGPoint, bounds: CGSize) -> some View {
        let signalColor: Color = decoder.signalIsOn ? DT.ok : DT.info
        ZStack {
            Rectangle()
                .strokeBorder(signalColor, lineWidth: decoder.signalIsOn ? 3 : 2)
                .background(Rectangle().fill(signalColor.opacity(0.10)))
                .frame(width: reticleSize, height: reticleSize)
                .overlay(cornerTicks(color: signalColor))
            // Faint crosshair to help the user aim precisely.
            crosshair(color: signalColor.opacity(0.6))
                .frame(width: reticleSize, height: reticleSize)
        }
        .position(center)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let clamped = clampCenter(value.location, bounds: bounds)
                    reticleCenter = clamped
                    pushSampleRect(center: clamped, bounds: bounds)
                }
        )
        .animation(.easeOut(duration: 0.12), value: decoder.signalIsOn)
    }

    /// Small L-shaped corner ticks — gives the reticle the
    /// "targeting viewfinder" look without overwhelming the preview.
    private func cornerTicks(color: Color) -> some View {
        let tick: CGFloat = 12
        return Canvas { ctx, size in
            var path = Path()
            // Top-left
            path.move(to: CGPoint(x: 0, y: tick))
            path.addLine(to: .zero)
            path.addLine(to: CGPoint(x: tick, y: 0))
            // Top-right
            path.move(to: CGPoint(x: size.width - tick, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: tick))
            // Bottom-right
            path.move(to: CGPoint(x: size.width, y: size.height - tick))
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: size.width - tick, y: size.height))
            // Bottom-left
            path.move(to: CGPoint(x: tick, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height - tick))
            ctx.stroke(path, with: .color(color), lineWidth: 3)
        }
    }

    private func crosshair(color: Color) -> some View {
        Canvas { ctx, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            let armLen: CGFloat = 12
            var path = Path()
            path.move(to: CGPoint(x: mid.x - armLen, y: mid.y))
            path.addLine(to: CGPoint(x: mid.x + armLen, y: mid.y))
            path.move(to: CGPoint(x: mid.x, y: mid.y - armLen))
            path.addLine(to: CGPoint(x: mid.x, y: mid.y + armLen))
            ctx.stroke(path, with: .color(color), lineWidth: 1)
        }
    }

    private func clampCenter(_ p: CGPoint, bounds: CGSize) -> CGPoint {
        let half = reticleSize / 2
        return CGPoint(
            x: min(max(half, p.x), bounds.width - half),
            y: min(max(half, p.y), bounds.height - half)
        )
    }

    /// Write the reticle's current position back to the decoder as a
    /// normalized sample rect.
    private func pushSampleRect(center: CGPoint, bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let half = reticleSize / 2
        let rect = CGRect(
            x: (center.x - half) / bounds.width,
            y: (center.y - half) / bounds.height,
            width: reticleSize / bounds.width,
            height: reticleSize / bounds.height
        )
        decoder.sampleRect = rect
    }
}
