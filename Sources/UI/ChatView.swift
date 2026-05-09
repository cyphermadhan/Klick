import SwiftUI

/// Text messaging screen, simplified from the earlier tree-keying UI.
///
/// One composer, one RX scroll, one send button. The only per-send
/// choice is "Send as Morse" — a switch next to the send button. When
/// on, the outgoing text is beeped locally through the tone synth, the
/// flashlight pulses if FLASH is enabled, and the message goes out as
/// `.morseText` so the receiver can replay it the same way. When off,
/// it's a silent `.chatText` send.
///
/// The preset phrase chips (SOS, HELP, OK, …) insert into the composer
/// rather than sending directly — lets the user tweak before transmit.
///
/// A `LISTEN` button opens `ListenView`, which runs a camera or audio
/// decoder and pipes decoded characters back as a received Morse entry.
struct ChatView: View {
    @ObservedObject var session: PTTSession
    @ObservedObject var tracker: MessageDeliveryTracker

    @StateObject private var tone = MorseTone()
    @StateObject private var beacon = FlashlightBeacon()

    @AppStorage("morse.wpm") private var wpm: Int = 12
    @AppStorage("morse.flashEnabled") private var flashEnabled: Bool = false
    @AppStorage("chat.sendAsMorse") private var sendAsMorse: Bool = false

    @State private var draft: String = ""
    @State private var showingListen = false
    @State private var decodedBuffer: String = ""
    @FocusState private var composerFocused: Bool

    @Environment(\.dismiss) private var dismiss

    /// Phrases the user can tap to insert into the composer. Grouped for
    /// the terminal-style divider in the chip row. Keep these short and
    /// punctuation-free — anything ITU Morse can carry.
    private static let presetGroups: [[String]] = [
        ["SOS", "MAYDAY", "HELP"],
        ["OK", "YES", "NO", "HI", "BYE"],
        ["ON MY WAY", "WAIT", "READY", "DONE"]
    ]

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 10) {
                header
                rxScroll
                presetChips
                composer
                morseControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .onReceive(session.$incomingMorse) { msg in
            // Arriving Morse packets still auto-play as beeps / flash,
            // independent of whether the local "send as Morse" toggle
            // is on — receipt is about what the sender intended.
            guard let msg, !msg.isEmpty else { return }
            let frames = MorseCode.encode(msg)
            tone.play(frames, wpm: wpm)
            if flashEnabled { beacon.play(frames, wpm: wpm) }
        }
        .onDisappear {
            tone.stop()
            beacon.stop()
        }
        .sheet(isPresented: $showingListen) {
            ListenView(onCharacter: { char in
                decodedBuffer.append(char)
            })
            .onDisappear {
                // On close, commit the decoded buffer as a received
                // morse entry so it joins the normal RX scroll.
                let trimmed = decodedBuffer.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    session.appendDecodedMorse(trimmed)
                }
                decodedBuffer.removeAll()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Text("◂ BACK")
                    .walkieLabel(11)
                    .foregroundStyle(DT.info)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Rectangle().strokeBorder(DT.info.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("CHAT")
                .walkieLabel(13, weight: .heavy, tracking: 3)
                .foregroundStyle(DT.text)

            Spacer()

            Button { showingListen = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ear.fill")
                    Text("LISTEN").walkieLabel(10)
                }
                .foregroundStyle(DT.sys)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(DT.sys.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button("CLEAR") { draft.removeAll() }
                .font(DT.mono(10, weight: .bold))
                .tracking(DT.labelTracking)
                .foregroundStyle(DT.warn)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(Rectangle().strokeBorder(DT.warn.opacity(0.6), lineWidth: 1))
                .buttonStyle(.plain)
        }
    }

    // MARK: - RX scroll

    private var rxScroll: some View {
        TerminalFrame("RX") {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(session.textHistory) { entry in
                            rxRow(entry)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.textHistory.count) { _ in
                    // Autoscroll to the newest row so incoming messages
                    // don't get buried off-screen.
                    if let last = session.textHistory.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
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

    @ViewBuilder
    private func deliveryGlyph(for entry: TextEntry) -> some View {
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

    // MARK: - Preset chips

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.presetGroups.indices, id: \.self) { idx in
                    let group = Self.presetGroups[idx]
                    ForEach(group, id: \.self) { phrase in
                        chip(phrase)
                    }
                    if idx < Self.presetGroups.count - 1 {
                        // Thin separator between semantic groups
                        // (emergency / everyday / status).
                        Rectangle()
                            .fill(DT.border)
                            .frame(width: 1, height: 20)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 34)
    }

    private func chip(_ phrase: String) -> some View {
        Button { insert(phrase) } label: {
            Text(phrase)
                .walkieLabel(10)
                .foregroundStyle(DT.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DT.panel)
                .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func insert(_ phrase: String) {
        if draft.isEmpty {
            draft = phrase
        } else if draft.hasSuffix(" ") {
            draft.append(phrase)
        } else {
            draft.append(" \(phrase)")
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TerminalFrame("TX") {
                TextField("", text: $draft, axis: .vertical)
                    .font(DT.mono(13, weight: .semibold))
                    .foregroundStyle(DT.text)
                    .tint(DT.ok)
                    .lineLimit(1...3)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
            }
            .frame(minHeight: 44)

            Button(action: send) {
                Text("SEND")
                    .walkieLabel(12, weight: .heavy, tracking: 2)
                    .foregroundStyle(canSend ? DT.bg : DT.textFaint)
                    .frame(width: 80, height: 44)
                    .background(canSend ? DT.ok : DT.panel)
                    .overlay(Rectangle().strokeBorder(canSend ? DT.ok : DT.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    // MARK: - Morse controls

    private var morseControls: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $sendAsMorse) {
                Text("SEND AS MORSE")
                    .walkieLabel(10)
                    .foregroundStyle(DT.text)
            }
            .toggleStyle(.switch)
            .tint(DT.sys)
            .fixedSize()

            if sendAsMorse {
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

            Spacer()
        }
        .animation(.easeOut(duration: 0.15), value: sendAsMorse)
    }

    // MARK: - Send

    private var canSend: Bool {
        session.isRunning && session.isPaired && session.selectedPeer != nil &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if sendAsMorse {
            session.sendMorse(text)
            // Local playback so the sender hears / sees what they sent.
            let frames = MorseCode.encode(text)
            tone.play(frames, wpm: wpm)
            if flashEnabled { beacon.play(frames, wpm: wpm) }
        } else {
            session.sendChat(text)
        }
        draft.removeAll()
    }
}
