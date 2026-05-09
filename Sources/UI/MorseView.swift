import SwiftUI

/// Morse screen. Reached from the `MORSE` header pill on `ContentView`.
///
/// Layout (top → bottom):
///   1. Header: ◂ BACK · MORSE · WPM · CLEAR
///   2. TX buffer (current draft, editable via the tree)
///   3. RX buffer (scroll of received messages)
///   4. Tree canvas — 55–65 % of available height, the input surface
///   5. Input row: KEY mode [·] [⌫] [␣] [−]  or TAP mode single key
///   6. Mode toggles: KEY / TAP / FLASH · TX button
///
/// Sending: on TX button tap, the composed buffer is handed to
/// `PTTSession.sendMorse`, which encrypts + routes on whichever transport
/// the selected peer lives on. Receiving: `PTTSession.incomingMorse`
/// pushes into the RX scroll; the tone synth optionally replays each
/// message as beeps; the flashlight beacon pulses in sync when FLASH is on.
struct MorseView: View {
    @ObservedObject var session: PTTSession

    @StateObject private var tree = MorseTree()
    @StateObject private var tone = MorseTone()
    @StateObject private var beacon = FlashlightBeacon()

    @AppStorage("morse.wpm") private var wpm: Int = 12
    @AppStorage("morse.flashEnabled") private var flashEnabled: Bool = false
    @AppStorage("morse.mode") private var inputModeRaw: String = InputMode.key.rawValue

    /// Character that just committed — used to flash the node orange.
    @State private var flashChar: Character?
    @State private var commitTimer: Task<Void, Never>?
    /// Pending touch state for TAP mode.
    @State private var tapDownAt: Date?

    @Environment(\.dismiss) private var dismiss

    /// Auto-commit window. After this many ms of no dit/dah, the current
    /// path commits to a letter. Twice this is a word gap commit.
    private let autoCommitMs: Int = 600
    /// Boundary between dit and dah press in TAP mode.
    private let tapDahThreshold: TimeInterval = 0.15

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 10) {
                header
                buffers
                TerminalFrame("TREE") {
                    MorseTreeView(tree: tree, flashChar: flashChar)
                }
                .frame(maxHeight: .infinity)

                inputRow

                modeRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .onChange(of: tree.buffer) { new in
            // Letter committed — figure out which one and flash it.
            guard let last = new.last, last != " " else { return }
            flashChar = Character(String(last).uppercased())
            commitTimer?.cancel()
            commitTimer = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                flashChar = nil
            }
        }
        .onReceive(session.$incomingMorse) { msg in
            guard let msg, !msg.isEmpty else { return }
            let frames = MorseCode.encode(msg)
            tone.play(frames, wpm: wpm)
            if flashEnabled { beacon.play(frames, wpm: wpm) }
        }
        .onDisappear {
            tone.stop()
            beacon.stop()
            commitTimer?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Text("◂ BACK")
                    .walkieLabel(11)
                    .foregroundStyle(DT.info)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().strokeBorder(DT.info.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("MORSE")
                .walkieLabel(13, weight: .heavy, tracking: 3)
                .foregroundStyle(DT.text)

            Spacer()

            HStack(spacing: 4) {
                Text("WPM")
                    .walkieLabel(10)
                    .foregroundStyle(DT.textDim)
                Stepper(value: $wpm, in: 5...30) {
                    Text("\(wpm)")
                        .font(DT.mono(12, weight: .bold))
                        .foregroundStyle(DT.text)
                }
                .labelsHidden()
            }

            Button("CLEAR") { tree.clear() }
                .font(DT.mono(10, weight: .bold))
                .tracking(DT.labelTracking)
                .foregroundStyle(DT.warn)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(DT.warn.opacity(0.6), lineWidth: 1))
                .buttonStyle(.plain)
        }
    }

    // MARK: - Buffers

    private var buffers: some View {
        VStack(alignment: .leading, spacing: 6) {
            TerminalFrame("TX") {
                Text(tree.buffer.isEmpty ? "_" : tree.buffer + "_")
                    .font(DT.mono(14, weight: .bold))
                    .foregroundStyle(tree.isOffTree ? DT.tx : DT.ok)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(height: 42)

            TerminalFrame("RX") {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.morseHistory) { entry in
                            HStack(spacing: 6) {
                                Text(entry.isIncoming ? "◂" : "▸")
                                    .foregroundStyle(entry.isIncoming ? DT.info : DT.ok)
                                Text(entry.text)
                                    .foregroundStyle(DT.text)
                            }
                            .font(DT.mono(11))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 72)
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        Group {
            if inputMode == .key {
                keyModeRow
            } else {
                tapModeRow
            }
        }
    }

    private var keyModeRow: some View {
        HStack(spacing: 8) {
            morseButton(label: "·", color: DT.info) {
                handleDit()
            }
            controlButton(label: "⌫", color: DT.warn) {
                if tree.currentPath.isEmpty { tree.deleteLastCharacter() }
                else { tree.undoStep() }
            }
            controlButton(label: "␣", color: DT.textDim) {
                armCommit(cancel: true)
                tree.addWordGap()
            }
            morseButton(label: "−", color: DT.info) {
                handleDah()
            }
            txButton
        }
        .frame(height: 64)
    }

    private var tapModeRow: some View {
        HStack(spacing: 8) {
            controlButton(label: "⌫", color: DT.warn) {
                if tree.currentPath.isEmpty { tree.deleteLastCharacter() }
                else { tree.undoStep() }
            }
            controlButton(label: "␣", color: DT.textDim) {
                armCommit(cancel: true)
                tree.addWordGap()
            }
            tapKey
            txButton
        }
        .frame(height: 64)
    }

    private var tapKey: some View {
        Rectangle()
            .fill(tapDownAt == nil ? DT.panel : DT.info.opacity(0.25))
            .overlay(Rectangle().strokeBorder(DT.info, lineWidth: 1))
            .overlay(
                Text("KEY")
                    .walkieLabel(12, weight: .heavy, tracking: 2)
                    .foregroundStyle(DT.info)
            )
            .frame(maxWidth: .infinity)
            // DragGesture with minimumDistance: 0 is the reliable way to get
            // both press-down and release callbacks in SwiftUI.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if tapDownAt == nil { tapDownAt = Date() }
                    }
                    .onEnded { _ in
                        guard let start = tapDownAt else { return }
                        let held = Date().timeIntervalSince(start)
                        tapDownAt = nil
                        if held >= tapDahThreshold { handleDah() } else { handleDit() }
                    }
            )
    }

    private var txButton: some View {
        Button(action: sendBuffer) {
            Text("TX")
                .walkieLabel(13, weight: .heavy, tracking: 3)
                .foregroundStyle(canTX ? DT.bg : DT.textFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(canTX ? DT.ok : DT.panel)
                .overlay(Rectangle().strokeBorder(canTX ? DT.ok : DT.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!canTX)
        .frame(width: 80)
    }

    // MARK: - Mode row

    private var modeRow: some View {
        HStack(spacing: 6) {
            modePill("KEY", active: inputMode == .key) { inputModeRaw = InputMode.key.rawValue }
            modePill("TAP", active: inputMode == .tap) { inputModeRaw = InputMode.tap.rawValue }
            Spacer()
            Toggle(isOn: $flashEnabled) {
                Text("FLASH")
                    .walkieLabel(10)
                    .foregroundStyle(beacon.isAvailable ? DT.text : DT.textFaint)
            }
            .toggleStyle(.switch)
            .tint(DT.tx)
            .disabled(!beacon.isAvailable)
            .fixedSize()
        }
    }

    private func modePill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .walkieLabel(10)
                .foregroundStyle(active ? DT.bg : DT.textDim)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? DT.info : .clear)
                .overlay(Rectangle().strokeBorder(active ? DT.info : DT.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Buttons

    private func morseButton(label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DT.panel)
                .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func controlButton(label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DT.panel)
                .overlay(Rectangle().strokeBorder(color.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(width: 56)
    }

    // MARK: - Interactions

    private var canTX: Bool {
        session.isRunning && session.isPaired && session.selectedPeer != nil &&
            !tree.buffer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var inputMode: InputMode {
        InputMode(rawValue: inputModeRaw) ?? .key
    }

    private func handleDit() {
        tree.step(.dit)
        armCommit(cancel: false)
    }

    private func handleDah() {
        tree.step(.dah)
        armCommit(cancel: false)
    }

    /// Restart the auto-commit timer. `cancel=true` wipes it without
    /// rescheduling — used after an explicit word-gap button press.
    private func armCommit(cancel: Bool) {
        commitTimer?.cancel()
        if cancel { return }
        commitTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(autoCommitMs))
            guard !Task.isCancelled else { return }
            tree.commit()
        }
    }

    private func sendBuffer() {
        // Commit any pending letter first so a user who taps TX mid-letter
        // doesn't lose it.
        if !tree.currentPath.isEmpty { tree.commit() }
        let text = tree.buffer.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        session.sendMorse(text)
        // Also play locally so the sender hears what they sent.
        tone.play(MorseCode.encode(text), wpm: wpm)
        if flashEnabled { beacon.play(MorseCode.encode(text), wpm: wpm) }
        tree.clear()
    }

    enum InputMode: String {
        case key
        case tap
    }
}
