import SwiftUI

/// Main screen — terminal-style hardware-front-panel layout.
///
/// Layout, top → bottom:
///   1. Brand strip (WALKIE · CH 01 · OPUS 48K · SEC XS20·P1305)
///   2. Four nav pills: TALK (current) / CHAT / LISTEN / SETTINGS
///   3. Three tappable status tiles: LINK / PAIR / PEER — each does
///      double duty as indicator and action. LINK toggles start/stop,
///      PAIR opens the pair sheet, PEER opens the peer-list sheet.
///   4. Telemetry strip
///   5. Hint line
///   6. PTT transmit button pinned at the extreme bottom
///
/// The peer list used to fill the middle of the screen; now it lives
/// behind the PEER tile so this screen stays focused on the two most
/// common verbs: "go live" (LINK) and "hold to talk" (PTT).
struct ContentView: View {
    @StateObject private var session = PTTSession()
    @State private var showingPairing = false
    @State private var showingSettings = false
    @State private var showingChat = false
    @State private var showingListen = false
    @State private var showingPeers = false
    /// Buffer for characters streamed from ListenView. Committed to the
    /// session's RX scroll as one entry when the listen sheet closes.
    @State private var decodedListenBuffer = ""

    /// 10 Hz decay pulse for VU bars — cheap, visible, and keeps UI feeling live.
    private let levelTick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 12) {
                brandStrip
                navPills
                statusTiles
                diagnosticStrip
                hintLine
                Spacer(minLength: 0)
                pttButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .onReceive(levelTick) { _ in session.tickLevels() }
        .sheet(isPresented: $showingSettings) {
            SettingsView(radio: session.radio,
                         meshLink: session.meshLink as? CoreBluetoothMeshtasticLink)
        }
        .sheet(isPresented: $showingChat) {
            ChatView(session: session, tracker: session.deliveryTracker)
        }
        .sheet(isPresented: $showingListen, onDismiss: flushDecodedListenBuffer) {
            ListenView(onCharacter: { char in
                // Accumulate here rather than pushing each char as its
                // own session entry — one dash-and-dit message should
                // appear as one row in the RX scroll, not twenty.
                decodedListenBuffer.append(char)
            })
        }
        .sheet(isPresented: $showingPeers) {
            PeerListSheet(session: session)
        }
        .sheet(isPresented: $showingPairing) {
            PairingView()
                .onDisappear {
                    if session.isRunning {
                        session.stop()
                        Task { await session.start() }
                    }
                }
        }
    }

    // MARK: - Brand strip

    private var brandStrip: some View {
        HStack(spacing: 8) {
            Text("KLICK")
                .walkieLabel(14, weight: .heavy, tracking: 3)
                .foregroundStyle(DT.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle().fill(DT.border).frame(width: 1, height: 12)
            // "CH 01" — walkie-talkie channel indicator, aesthetic only.
            // Klick uses key-based pairing (one shared libsodium key per
            // install), not frequency channels like traditional radios,
            // so there's only ever one "channel" per pair. Kept for the
            // terminal look.
            Text("CH 01")
                .walkieLabel(11)
                .foregroundStyle(DT.textDim)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle().fill(DT.border).frame(width: 1, height: 12)
            // Codec + cipher badges — part of the terminal aesthetic.
            // "OPUS 48K" = Opus audio codec @ 48 kHz; "XS20·P1305" =
            // libsodium XSalsa20 + Poly1305 (encryption/auth).
            Text("OPUS 48K")
                .walkieLabel(11)
                .foregroundStyle(DT.textDim)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle().fill(DT.border).frame(width: 1, height: 12)
            Text("XS20·P1305")
                .walkieLabel(11)
                .foregroundStyle(DT.textDim)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Nav pills (TALK / CHAT / LISTEN / SETTINGS)

    private var navPills: some View {
        // Equal-width distribution so the four pills fill the row edge
        // to edge. `minimumScaleFactor` rescues SETTINGS on narrower
        // devices where "SETTINGS" plus icon would otherwise wrap.
        HStack(spacing: 6) {
            navPill(title: "TALK", icon: "dot.radiowaves.left.and.right",
                    accent: DT.navTalk, active: true, action: {})
            navPill(title: "CHAT", icon: "bubble.left.fill",
                    accent: DT.navChat, active: false) { showingChat = true }
            navPill(title: "LISTEN", icon: "ear.fill",
                    accent: DT.navListen, active: false) { showingListen = true }
            navPill(title: "SETTINGS", icon: "slider.horizontal.3",
                    accent: DT.navSettings, active: false) { showingSettings = true }
        }
    }

    /// Uniform icon+text pill. Active state uses a subtle tinted
    /// background + heavier border instead of inverted colors — that
    /// swap lost contrast against bright accents and rendered text
    /// effectively invisible on some displays.
    ///
    /// Each nav pill has its own hue (TALK yellow / CHAT pink /
    /// LISTEN purple / SETTINGS grey) so they read as distinct tabs
    /// rather than overloading the app's semantic action colors
    /// (green / red / blue / amber).
    private func navPill(title: String, icon: String, accent: Color,
                         active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .walkieLabel(10)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(active ? accent.opacity(0.20) : Color.clear)
            .overlay(Rectangle().strokeBorder(accent.opacity(active ? 1 : 0.6),
                                              lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(active) // TALK is the current screen — disable interaction
    }

    // MARK: - Status tiles (now tappable)

    private var statusTiles: some View {
        HStack(alignment: .top, spacing: 10) {
            tappableTile(action: toggleRunning) {
                StatusTile(
                    title: "LINK",
                    subtitle: session.isRunning ? "LIVE · TAP TO STOP" : "TAP TO GO LIVE",
                    accent: session.isRunning ? DT.ok : DT.info,
                    active: session.isRunning
                ) {
                    Image(systemName: session.isRunning
                          ? "dot.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 22, weight: .bold))
                }
            }

            tappableTile(action: { showingPairing = true }) {
                StatusTile(
                    title: "PAIR",
                    subtitle: session.isPaired
                        ? "FPRINT · \(session.keyFingerprint ?? "----")"
                        : "NO KEY · TAP TO PAIR",
                    accent: session.isPaired ? DT.ok : DT.warn,
                    active: session.isPaired
                ) {
                    Image(systemName: session.isPaired ? "lock.shield.fill" : "lock.open")
                        .font(.system(size: 22, weight: .bold))
                }
            }

            tappableTile(action: { showingPeers = true }) {
                StatusTile(
                    title: "PEER",
                    subtitle: peerSubtitle,
                    accent: DT.sys,
                    active: session.selectedPeer != nil
                ) {
                    Image(systemName: session.selectedPeer != nil
                          ? "iphone.gen3.radiowaves.left.and.right"
                          : "iphone.slash")
                        .font(.system(size: 22, weight: .bold))
                }
            }
        }
    }

    /// Wraps a `StatusTile` in a plain button so the whole tile becomes
    /// a tap target. Keeps `StatusTile` a pure display component.
    private func tappableTile<Content: View>(action: @escaping () -> Void,
                                             @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) { content() }
            .buttonStyle(.plain)
            .contentShape(.rect)
    }

    private var peerSubtitle: String {
        if let peer = session.selectedPeer {
            return "TARGET · \(peer.name.uppercased())"
        }
        if session.directory.peers.isEmpty {
            return "NO PEERS · TAP TO RESCAN"
        }
        return "\(session.directory.peers.count) SEEN · TAP TO PICK"
    }

    private func toggleRunning() {
        if session.isRunning {
            session.stop()
        } else {
            Task { await session.start() }
        }
    }

    /// Flushes whatever the listen sheet decoded into the session's RX
    /// scroll as a single morse entry, then resets the buffer.
    private func flushDecodedListenBuffer() {
        let trimmed = decodedListenBuffer.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            session.appendDecodedMorse(trimmed)
        }
        decodedListenBuffer.removeAll()
    }

    // MARK: - Diagnostic strip

    private var diagnosticStrip: some View {
        TerminalFrame("TELEMETRY") {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    DiagCell(label: "PKT TX", value: String(format: "%05d", session.packetsSent))
                    DiagCell(label: "PKT RX", value: String(format: "%05d", session.packetsReceived))
                    DiagCell(label: "LOSS",   value: String(format: "%04.1f%%", session.lossPercent))
                }
                HStack {
                    DiagCell(label: "SEQ",    value: String(format: "0x%04X", session.lastIncomingSequence ?? 0))
                    DiagCell(label: "DROP",   value: String(format: "%05d", session.packetsDropped))
                    DiagCell(label: "STATE",
                             value: session.isTransmitting ? "TX" : (session.isRunning ? "LIVE" : "IDLE"),
                             valueColor: session.isTransmitting ? DT.tx : (session.isRunning ? DT.ok : DT.textDim))
                }
            }
        }
    }

    // MARK: - Hint line

    private var hintLine: some View {
        let content = hintContent
        return HStack(spacing: 6) {
            PulsingDot(color: content.color)
            Text(content.msg)
                .walkieLabel(10)
                .foregroundStyle(content.color)
        }
    }

    private var hintContent: (msg: String, color: Color) {
        if !session.isRunning {
            return ("SYSTEM HALTED · TAP LINK TO GO LIVE", DT.textDim)
        }
        if !session.isPaired {
            return ("PAIR REQUIRED · TAP PAIR TILE", DT.warn)
        }
        if session.selectedPeer == nil {
            return ("SELECT PEER · TAP PEER TILE", DT.info)
        }
        let name = session.selectedPeer!.name.uppercased()
        return ("HOLD TRANSMIT · LINK SECURE TO \(name)", DT.ok)
    }

    // MARK: - PTT button (pinned bottom)

    private var pttButton: some View {
        PTTButton(
            isTransmitting: session.isTransmitting,
            isEnabled: canTransmit,
            outboundLevel: session.outboundLevel,
            inboundLevel: session.inboundLevel,
            onBegin: {
                session.playPressSound()
                session.beginTransmit()
            },
            onEnd: {
                session.playReleaseSound()
                session.endTransmit()
            }
        )
    }

    private var canTransmit: Bool {
        session.isRunning && session.isPaired && session.selectedPeer != nil
    }
}

private struct DiagCell: View {
    let label: String
    let value: String
    var valueColor: Color = DT.text

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .walkieLabel(10, weight: .regular)
                .foregroundStyle(DT.textDim)
            Text(value)
                .font(DT.mono(11, weight: .bold))
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Modal peer-list sheet. The peer list used to fill the main screen;
/// now it lives here, reachable via the PEER tile, and closes itself
/// once a peer is picked so the user lands back on the PTT screen
/// ready to transmit.
struct PeerListSheet: View {
    @ObservedObject var session: PTTSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Text("PEERS")
                        .walkieLabel(13, weight: .heavy, tracking: 3)
                        .foregroundStyle(DT.text)
                    Spacer()
                    Button("CLOSE") { dismiss() }
                        .font(DT.mono(11, weight: .bold))
                        .tracking(DT.labelTracking)
                        .foregroundStyle(DT.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Rectangle().strokeBorder(DT.border, lineWidth: 1))
                        .buttonStyle(.plain)
                }
                TerminalFrame("DISCOVERED") {
                    PeerListView(directory: session.directory,
                                 selectedPeer: Binding(
                                    get: { session.selectedPeer },
                                    set: { new in
                                        session.selectedPeer = new
                                        // Close on pick so the user drops
                                        // back to the PTT screen.
                                        if new != nil { dismiss() }
                                    }
                                 ))
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
