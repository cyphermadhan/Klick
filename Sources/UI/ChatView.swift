import SwiftUI

/// Text-messaging screen with two input modes under one header:
///
///   - **CHAT** — system keyboard, plain text composer. Fast and familiar
///     for anyone who's ever typed on a phone. Sends as `.chatText`.
///   - **MORSE** — tree-driven dit/dah keying with audio beeps, flashlight
///     pulses, KEY or TAP input, WPM-configurable. Sends as `.morseText`.
///
/// Both modes share the same RX scroll (`PTTSession.textHistory`) so you
/// can reply to a keyboard-typed message with Morse, or vice versa. The
/// RX entry's `kind` drives a small prefix glyph (`· −` for Morse, none
/// for Chat) so the list stays readable.
///
/// Received Morse messages also replay as beeps / flashes, gated on
/// `incomingMorse` — chat arrivals are silent.
struct ChatView: View {
    @ObservedObject var session: PTTSession
    /// Mesh delivery state for outgoing rows. Explicit observation
    /// (rather than reading through `session`) is needed because the
    /// tracker is its own `ObservableObject` — SwiftUI wouldn't re-render
    /// on its publishes if we only held the session.
    @ObservedObject var tracker: MessageDeliveryTracker

    @StateObject private var tree = MorseTree()
    @StateObject private var tone = MorseTone()
    @StateObject private var beacon = FlashlightBeacon()

    // Persisted user preferences.
    @AppStorage("chat.mode") private var screenModeRaw: String = ScreenMode.chat.rawValue
    @AppStorage("morse.wpm") private var wpm: Int = 12
    @AppStorage("morse.flashEnabled") private var flashEnabled: Bool = false
    @AppStorage("morse.mode") private var inputModeRaw: String = MorseInputMode.key.rawValue

    // Chat mode state.
    @State private var chatDraft: String = ""

    // Morse mode state.
    @State private var flashChar: Character?
    @State private var commitTimer: Task<Void, Never>?
    @State private var tapDownAt: Date?
    @State private var tapCrossedDah: Bool = false
    @State private var tapThresholdTask: Task<Void, Never>?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var chatFieldFocused: Bool

    /// Auto-commit window. After this many ms of no dit/dah, the current
    /// path commits to a letter. Twice this is a word gap commit.
    private let autoCommitMs: Int = 600

    /// Dit/dah boundary in TAP mode: 1.5 dit-units per standard CW.
    private var tapDahThreshold: TimeInterval {
        (1.2 / Double(wpm)) * 1.5
    }

    private var screenMode: ScreenMode {
        ScreenMode(rawValue: screenModeRaw) ?? .chat
    }

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 10) {
                header
                screenModeToggle
                rxScroll
                if screenMode == .chat {
                    chatComposer
                } else {
                    morseSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .onChange(of: tree.buffer) { new in
            guard let last = new.last, last != " " else { return }
            flashChar = Character(String(last).uppercased())
            commitTimer?.cancel()
            commitTimer = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                flashChar = nil
            }
        }
        .onReceive(session.$incomingMorse) { msg in
            // Replay inbound Morse as beeps + optional flash. Chat messages
            // don't populate this publisher, so this only fires for Morse.
            guard let msg, !msg.isEmpty else { return }
            let frames = MorseCode.encode(msg)
            tone.play(frames, wpm: wpm)
            if flashEnabled { beacon.play(frames, wpm: wpm) }
        }
        .onDisappear {
            tone.stop()
            beacon.stop()
            commitTimer?.cancel()
            tapThresholdTask?.cancel()
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

            Text("CHAT")
                .walkieLabel(13, weight: .heavy, tracking: 3)
                .foregroundStyle(DT.text)

            Spacer()

            // WPM stepper is Morse-specific — collapse entirely in CHAT mode
            // rather than showing a disabled control.
            if screenMode == .morse {
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
            }

            Button("CLEAR") {
                if screenMode == .chat { chatDraft.removeAll() }
                else { tree.clear() }
            }
                .font(DT.mono(10, weight: .bold))
                .tracking(DT.labelTracking)
                .foregroundStyle(DT.warn)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(DT.warn.opacity(0.6), lineWidth: 1))
                .buttonStyle(.plain)
        }
    }

    // MARK: - Mode toggle (CHAT / MORSE)

    private var screenModeToggle: some View {
        HStack(spacing: 6) {
            screenModePill("CHAT", active: screenMode == .chat) {
                screenModeRaw = ScreenMode.chat.rawValue
                // Tree buffer is stale when moving back to Chat; clear
                // it so returning to Morse starts fresh.
                tree.clear()
            }
            screenModePill("MORSE", active: screenMode == .morse) {
                screenModeRaw = ScreenMode.morse.rawValue
                chatFieldFocused = false
            }
            Spacer()
        }
    }

    private func screenModePill(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .walkieLabel(10)
                .foregroundStyle(active ? DT.bg : DT.textDim)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? DT.sys : .clear)
                .overlay(Rectangle().strokeBorder(active ? DT.sys : DT.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - RX scroll (shared)

    private var rxScroll: some View {
        TerminalFrame("RX") {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.textHistory) { entry in
                        rxRow(entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // CHAT mode gives RX more vertical room since there's no tree
        // below it; MORSE mode keeps it compact to leave room for the
        // tree canvas.
        .frame(height: screenMode == .chat ? 260 : 72)
        .animation(.easeOut(duration: 0.15), value: screenMode)
        .accessibilityLabel("Received messages")
    }

    private func rxRow(_ entry: TextEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.isIncoming ? "◂" : "▸")
                .foregroundStyle(entry.isIncoming ? DT.info : DT.ok)
            if entry.kind == .morse {
                Text("·−")
                    .foregroundStyle(DT.sys)
                    .font(DT.mono(9))
            }
            Text(entry.text)
                .foregroundStyle(DT.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            deliveryGlyph(for: entry)
        }
        .font(DT.mono(11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.isIncoming ? "Received" : "Sent") \(entry.kind.rawValue)")
        .accessibilityValue(entry.text)
    }

    /// Small status glyph shown at the end of outgoing rows whose delivery
    /// is being tracked (mesh only). Incoming rows and non-mesh sends get
    /// nothing — no need for a green ✓ on every WiFi message.
    @ViewBuilder
    private func deliveryGlyph(for entry: TextEntry) -> some View {
        // Reading `tracker.stateVersion` here is enough for SwiftUI to
        // re-render this row when delivery state changes — the tracker
        // is `@ObservedObject` above so `stateVersion` bumps propagate.
        let _ = tracker.stateVersion
        if !entry.isIncoming, let state = tracker.state(entryId: entry.id) {
            switch state {
            case .sending:   Text("…").foregroundStyle(DT.textDim)
            case .delivered: Text("✓").foregroundStyle(DT.ok)
            case .failed:    Text("✗").foregroundStyle(DT.tx)
            case .timedOut:  Text("⏲").foregroundStyle(DT.warn)
            case .sent:      EmptyView()
            }
        }
    }

    // MARK: - CHAT mode

    private var chatComposer: some View {
        VStack(spacing: 8) {
            TerminalFrame("TX") {
                TextField("", text: $chatDraft, axis: .vertical)
                    .font(DT.mono(13, weight: .semibold))
                    .foregroundStyle(DT.text)
                    .tint(DT.ok)
                    .lineLimit(1...4)
                    .focused($chatFieldFocused)
                    .submitLabel(.send)
                    .onSubmit(sendChat)
            }
            .frame(minHeight: 44)

            HStack(spacing: 8) {
                Spacer()
                txButton(label: "SEND", enabled: canSendChat, action: sendChat)
                    .frame(width: 120, height: 44)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat composer")
    }

    private func sendChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.sendChat(text)
        chatDraft.removeAll()
    }

    // MARK: - MORSE mode

    private var morseSection: some View {
        VStack(spacing: 10) {
            TerminalFrame("TX") {
                Text(tree.buffer.isEmpty ? "_" : tree.buffer + "_")
                    .font(DT.mono(14, weight: .bold))
                    .foregroundStyle(tree.isOffTree ? DT.tx : DT.ok)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(height: 42)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Outgoing Morse")
            .accessibilityValue(tree.buffer.isEmpty ? "empty" : tree.buffer)
            .accessibilityAddTraits(.updatesFrequently)

            TerminalFrame("TREE") {
                MorseTreeView(tree: tree, flashChar: flashChar)
            }
            .frame(maxHeight: .infinity)

            inputRow
            modeRow
        }
    }

    private var inputRow: some View {
        Group {
            if inputMode == .key { keyModeRow } else { tapModeRow }
        }
    }

    private var keyModeRow: some View {
        HStack(spacing: 8) {
            morseButton(label: "·", color: DT.info, accessibilityLabel: "dit", action: handleDit)
            controlButton(label: "⌫", color: DT.warn, accessibilityLabel: "backspace") {
                if tree.currentPath.isEmpty { tree.deleteLastCharacter() }
                else { tree.undoStep() }
            }
            controlButton(label: "␣", color: DT.textDim, accessibilityLabel: "word gap") {
                armCommit(cancel: true)
                tree.addWordGap()
            }
            morseButton(label: "−", color: DT.info, accessibilityLabel: "dah", action: handleDah)
            txButton(label: "TX", enabled: canSendMorse, action: sendMorse)
                .frame(width: 80)
        }
        .frame(height: 64)
    }

    private var tapModeRow: some View {
        HStack(spacing: 8) {
            controlButton(label: "⌫", color: DT.warn, accessibilityLabel: "backspace") {
                if tree.currentPath.isEmpty { tree.deleteLastCharacter() }
                else { tree.undoStep() }
            }
            controlButton(label: "␣", color: DT.textDim, accessibilityLabel: "word gap") {
                armCommit(cancel: true)
                tree.addWordGap()
            }
            tapKey
            txButton(label: "TX", enabled: canSendMorse, action: sendMorse)
                .frame(width: 80)
        }
        .frame(height: 64)
    }

    private var tapKey: some View {
        let (label, accent): (String, Color) = {
            guard tapDownAt != nil else { return ("KEY", DT.info) }
            return tapCrossedDah ? ("DAH", DT.ok) : ("DIT", DT.warn)
        }()
        return Rectangle()
            .fill(tapDownAt == nil ? DT.panel : accent.opacity(0.25))
            .overlay(Rectangle().strokeBorder(accent, lineWidth: 1))
            .overlay(
                Text(label)
                    .walkieLabel(12, weight: .heavy, tracking: 2)
                    .foregroundStyle(accent)
            )
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.08), value: tapCrossedDah)
            .animation(.easeOut(duration: 0.08), value: tapDownAt)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if tapDownAt == nil { tapStart() }
                    }
                    .onEnded { _ in tapEnd() }
            )
            .accessibilityLabel("Morse key")
            .accessibilityHint("Short press for dit, long press for dah")
    }

    private var modeRow: some View {
        HStack(spacing: 6) {
            modePill("KEY", active: inputMode == .key) {
                inputModeRaw = MorseInputMode.key.rawValue
            }
            modePill("TAP", active: inputMode == .tap) {
                inputModeRaw = MorseInputMode.tap.rawValue
            }
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

    // MARK: - Shared buttons

    private func morseButton(label: String, color: Color, accessibilityLabel: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DT.panel)
                .overlay(Rectangle().strokeBorder(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func controlButton(label: String, color: Color, accessibilityLabel: String,
                               action: @escaping () -> Void) -> some View {
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
        .accessibilityLabel(accessibilityLabel)
    }

    private func txButton(label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .walkieLabel(13, weight: .heavy, tracking: 3)
                .foregroundStyle(enabled ? DT.bg : DT.textFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(enabled ? DT.ok : DT.panel)
                .overlay(Rectangle().strokeBorder(enabled ? DT.ok : DT.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Transmit")
        .accessibilityHint("Sends the outgoing message to the selected peer")
    }

    // MARK: - Enable gates

    private var canSendMorse: Bool {
        session.isRunning && session.isPaired && session.selectedPeer != nil &&
            !tree.buffer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSendChat: Bool {
        session.isRunning && session.isPaired && session.selectedPeer != nil &&
            !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputMode: MorseInputMode {
        MorseInputMode(rawValue: inputModeRaw) ?? .key
    }

    // MARK: - Morse interactions

    private func handleDit() {
        tree.step(.dit)
        armCommit(cancel: false)
    }

    private func handleDah() {
        tree.step(.dah)
        armCommit(cancel: false)
    }

    private func armCommit(cancel: Bool) {
        commitTimer?.cancel()
        if cancel { return }
        commitTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(autoCommitMs))
            guard !Task.isCancelled else { return }
            tree.commit()
        }
    }

    private func tapStart() {
        tapDownAt = Date()
        tapCrossedDah = false
        let threshold = tapDahThreshold
        tapThresholdTask?.cancel()
        tapThresholdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(threshold))
            guard !Task.isCancelled else { return }
            tapCrossedDah = true
        }
    }

    private func tapEnd() {
        tapThresholdTask?.cancel()
        tapThresholdTask = nil
        guard let start = tapDownAt else { return }
        let held = Date().timeIntervalSince(start)
        tapDownAt = nil
        tapCrossedDah = false
        if held >= tapDahThreshold { handleDah() } else { handleDit() }
    }

    private func sendMorse() {
        if !tree.currentPath.isEmpty { tree.commit() }
        let text = tree.buffer.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        session.sendMorse(text)
        tone.play(MorseCode.encode(text), wpm: wpm)
        if flashEnabled { beacon.play(MorseCode.encode(text), wpm: wpm) }
        tree.clear()
    }

    // MARK: - Mode enums

    enum ScreenMode: String {
        case chat
        case morse
    }

    enum MorseInputMode: String {
        case key
        case tap
    }
}
