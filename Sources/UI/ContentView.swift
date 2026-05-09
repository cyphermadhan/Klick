import SwiftUI

/// Main screen — laid out like a hardware front panel crossed with a
/// terminal readout. From top to bottom:
///   1. Slim status header (WALKIE · CH 01 · OPUS 48K · SEC XS20/P1305)
///   2. Three MPC-style status tiles (LINK / PAIR / PEER)
///   3. Peer list (terminal rows)
///   4. PTT transmit tile with VU meters
///   5. Diagnostic strip (PKT TX/RX, LOSS, SEQ)
struct ContentView: View {
    @StateObject private var session = PTTSession()
    @State private var showingPairing = false
    @State private var showingSettings = false
    @State private var showingChat = false

    /// 10 Hz decay pulse for VU bars — cheap, visible, and keeps UI feeling live.
    private let levelTick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 14) {
                headerBar

                statusTiles

                TerminalFrame("PEERS") {
                    PeerListView(directory: session.directory,
                                 selectedPeer: $session.selectedPeer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

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

                diagnosticStrip

                hintLine
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden)
        .onReceive(levelTick) { _ in session.tickLevels() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingChat) { ChatView(session: session) }
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

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 8) {
            // Row 1: brand + codec/cipher metadata. Laid out as a mono strip
            // with vertical bar separators so it reads like a status header.
            HStack(spacing: 8) {
                Text("WALKIE")
                    .walkieLabel(14, weight: .heavy, tracking: 3)
                    .foregroundStyle(DT.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle().fill(DT.border).frame(width: 1, height: 12)
                Text("CH 01")
                    .walkieLabel(11)
                    .foregroundStyle(DT.textDim)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle().fill(DT.border).frame(width: 1, height: 12)
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

            // Row 2: action pills. Separated so the labels never wrap even
            // on narrower phones (the header was squeezing to "PAI\nR" before).
            HStack(spacing: 6) {
                Spacer()
                headerButton("PAIR") { showingPairing = true }
                headerButton("CHAT", accent: DT.sys) { showingChat = true }
                headerButton("SYS") { showingSettings = true }
                headerButton(session.isRunning ? "STOP" : "START",
                             accent: session.isRunning ? DT.warn : DT.ok) {
                    if session.isRunning { session.stop() }
                    else { Task { await session.start() } }
                }
            }
        }
    }

    private func headerButton(_ title: String,
                              accent: Color = DT.info,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .walkieLabel(11)
                .foregroundStyle(accent)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .overlay(
                    Rectangle().strokeBorder(accent.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status tiles

    private var statusTiles: some View {
        // `.top` alignment: one tile's subtitle may wrap to two lines while
        // another stays at one — without this the HStack centers each tile
        // vertically and the short ones sag below the tall ones.
        HStack(alignment: .top, spacing: 10) {
            StatusTile(
                title: "LINK",
                subtitle: session.isRunning ? "STACK UP · BONJOUR ACTIVE" : "TAP START TO GO LIVE",
                accent: DT.info,
                active: session.isRunning
            ) {
                Image(systemName: session.isRunning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 22, weight: .bold))
            }

            StatusTile(
                title: "PAIR",
                // Show the fingerprint here so two paired phones can be
                // verified at a glance — both should read the same hex groups.
                subtitle: session.isPaired
                    ? "FPRINT · \(session.keyFingerprint ?? "----")"
                    : "NO KEY · PAIR TO ENCRYPT",
                accent: session.isPaired ? DT.ok : DT.warn,
                active: session.isPaired
            ) {
                Image(systemName: session.isPaired ? "lock.shield.fill" : "lock.open")
                    .font(.system(size: 22, weight: .bold))
            }

            StatusTile(
                title: "PEER",
                subtitle: peerSubtitle,
                accent: DT.sys,
                active: session.selectedPeer != nil
            ) {
                Image(systemName: session.selectedPeer != nil ? "iphone.gen3.radiowaves.left.and.right" : "iphone.slash")
                    .font(.system(size: 22, weight: .bold))
            }
        }
    }

    private var peerSubtitle: String {
        if let peer = session.selectedPeer {
            return "TARGET · \(peer.name.uppercased())"
        }
        if session.directory.peers.isEmpty {
            return "NO PEERS IN RANGE"
        }
        return "\(session.directory.peers.count) SEEN · SELECT ONE"
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
            return ("SYSTEM HALTED · PRESS START", DT.textDim)
        }
        if !session.isPaired {
            return ("PAIR REQUIRED · TAP PAIR → SHOW CODE", DT.warn)
        }
        if session.selectedPeer == nil {
            return ("SELECT PEER FROM LIST TO ARM TRANSMIT", DT.info)
        }
        let name = session.selectedPeer!.name.uppercased()
        return ("HOLD TRANSMIT · LINK SECURE TO \(name)", DT.ok)
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

#Preview {
    ContentView()
}
