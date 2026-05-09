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
                case .flash:   decoderPane(title: "CAMERA", level: flash.currentLevel, isOn: flash.signalIsOn)
                case .audio:   decoderPane(title: "AUDIO", level: audio.currentLevel, isOn: audio.signalIsOn)
                }
                Spacer()
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

    // MARK: - Active decoder pane

    private func decoderPane(title: String, level: Double, isOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("VIA \(title)")
                    .walkieLabel(11)
                    .foregroundStyle(DT.textDim)
                Spacer()
                Button("SWITCH") { mode = .picker; decoded.removeAll() }
                    .font(DT.mono(10, weight: .bold))
                    .tracking(DT.labelTracking)
                    .foregroundStyle(DT.info)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Rectangle().strokeBorder(DT.info.opacity(0.6), lineWidth: 1))
                    .buttonStyle(.plain)
            }

            TerminalFrame("LEVEL") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isOn ? DT.ok : DT.textFaint)
                            .frame(width: 8, height: 8)
                        Text(isOn ? "SIGNAL" : "IDLE")
                            .walkieLabel(10)
                            .foregroundStyle(isOn ? DT.ok : DT.textDim)
                    }
                    PixelBar(level: level.clamped(to: 0...1), cells: 30, fill: isOn ? DT.ok : DT.info)
                }
            }
            .frame(height: 72)

            TerminalFrame("DECODED") {
                ScrollView {
                    Text(decoded.isEmpty ? "WAITING FOR PULSES…" : decoded)
                        .font(DT.mono(14, weight: .bold))
                        .foregroundStyle(decoded.isEmpty ? DT.textFaint : DT.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(maxHeight: 220)

            HStack {
                Button("CLEAR") { decoded.removeAll() }
                    .font(DT.mono(11, weight: .bold))
                    .tracking(DT.labelTracking)
                    .foregroundStyle(DT.warn)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(Rectangle().strokeBorder(DT.warn.opacity(0.6), lineWidth: 1))
                    .buttonStyle(.plain)
                Spacer()
                if title == "CAMERA" {
                    Text("AIM AT THE FLASHLIGHT. KEEP STILL.")
                        .walkieCaption()
                        .foregroundStyle(DT.textFaint)
                } else {
                    Text("HOLD NEAR THE SOURCE. KEEP QUIET.")
                        .walkieCaption()
                        .foregroundStyle(DT.textFaint)
                }
            }
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
