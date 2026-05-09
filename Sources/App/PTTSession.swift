import Foundation
import os

/// Top-level coordinator that owns every subsystem and exposes a small
/// surface to the UI: "start the app", "begin transmitting", "end transmitting",
/// "pick this peer".
///
/// Responsibilities:
/// - Start the configured transports (WiFi/UDP, Nearby/MPC, or both —
///   driven by the user's RangeMode preference).
/// - Start audio capture + playback.
/// - On mic frame: encrypt → send to selected peer on its own transport.
/// - On transport receive: decrypt → enqueue for playback.
/// - Merge per-transport peer lists into a single `PeerDirectory` for the UI.
///
/// Only transmits while `isTransmitting` is true (PTT button held).
@MainActor
final class PTTSession: ObservableObject {
    // Observable state for the UI
    @Published private(set) var isRunning = false
    @Published private(set) var isTransmitting = false
    @Published private(set) var isPaired = false
    /// Human-checkable fingerprint of the currently-stored shared key.
    /// Displayed on the main screen so users can confirm both phones have
    /// identical keys without re-opening the pairing sheet.
    @Published private(set) var keyFingerprint: String?
    @Published var selectedPeer: PeerInfo?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastIncomingSequence: UInt32?

    // MARK: Live diagnostics (for the terminal-style bottom strip)
    @Published private(set) var packetsSent: UInt32 = 0
    @Published private(set) var packetsReceived: UInt32 = 0
    /// Packets that failed to decrypt / parse since start.
    @Published private(set) var packetsDropped: UInt32 = 0
    /// Packets whose sequence number jumped past the last-seen one (inferred loss).
    @Published private(set) var packetsLost: UInt32 = 0
    /// Rough outbound level in [0,1] taken from the last encoded Opus frame size.
    @Published private(set) var outboundLevel: Double = 0
    /// Rough inbound level in [0,1] from the last received audio packet's payload size.
    @Published private(set) var inboundLevel: Double = 0

    // MARK: Text (Morse + Chat share this plumbing)
    /// Fires once per inbound morse message so `ChatView` can replay it
    /// as beeps / torch flashes. Transient — cleared immediately after
    /// each fire. Chat messages do NOT populate this (no replay needed).
    @Published private(set) var incomingMorse: String?
    /// Unified scrollback for both Morse and Chat messages. `kind`
    /// distinguishes them so the RX list can render Morse with a small
    /// dit/dah glyph while Chat is plain text. Capped to avoid unbounded
    /// growth.
    @Published private(set) var textHistory: [TextEntry] = []
    private static let textHistoryLimit = 50

    /// Loss percentage clamped to a display-friendly 0…100.
    var lossPercent: Double {
        let total = Double(packetsReceived + packetsLost)
        guard total > 0 else { return 0 }
        return (Double(packetsLost) / total) * 100
    }

    // Sub-systems
    let pipeline = AudioPipeline()
    let directory = PeerDirectory()
    private let crypto = CryptoService()
    private let pairing = PairingService()
    private let sounds = WalkieSoundSynth()
    private let log = Logger(subsystem: "world.madhans.klick", category: "PTTSession")

    /// Transports spun up on start() based on `RangeModeStore.current`.
    /// Keyed by their `.kind` so outbound audio can route by peer transport
    /// without a linear scan.
    private var transports: [PeerTransport: AudioTransport] = [:]
    private var sharedKey: Data?

    init() {
        let existingKey = try? pairing.currentKey()
        self.isPaired = existingKey != nil
        self.keyFingerprint = existingKey.map(PairingService.fingerprint(of:))
        self.pipeline.loopback = false
        wireAudioToTransport()
    }

    // MARK: - Lifecycle

    /// Start the full networking stack. Call once when the user is ready —
    /// typically on the main screen after pairing.
    func start() async {
        guard !isRunning else { return }
        errorMessage = nil

        // Refresh the paired key into memory.
        do {
            sharedKey = try pairing.currentKey()
            isPaired = sharedKey != nil
            keyFingerprint = sharedKey.map(PairingService.fingerprint(of:))
        } catch {
            errorMessage = "Key load failed: \(error.localizedDescription)"
            return
        }

        // Start audio (permission prompt happens inside AudioPipeline).
        await pipeline.start()
        guard pipeline.isRunning else {
            errorMessage = pipeline.errorMessage ?? "Audio failed to start"
            return
        }

        // Spin up the transports for the user's selected range mode.
        let name = DeviceName.current
        let mode = RangeModeStore.current
        directory.selfName = name
        directory.isBrowsing = true

        var startedTransports: [PeerTransport: AudioTransport] = [:]
        do {
            if mode.includesWifi {
                let wifi = UDPTransport()
                wireTransport(wifi)
                try wifi.start(advertisingAs: name)
                startedTransports[.wifi] = wifi
            }
            if mode.includesNearby {
                let mpc = MPCTransport()
                wireTransport(mpc)
                try mpc.start(advertisingAs: name)
                startedTransports[.nearby] = mpc
            }
        } catch {
            errorMessage = "Network start failed: \(error.localizedDescription)"
            startedTransports.values.forEach { $0.stop() }
            pipeline.stop()
            directory.isBrowsing = false
            return
        }

        self.transports = startedTransports

        // Synth engine piggybacks on the already-active AVAudioSession;
        // starting it here means the first PTT press has no warm-up delay.
        sounds.start()
        isRunning = true
        log.info("PTT session running as \(name, privacy: .public) · mode=\(mode.rawValue, privacy: .public)")
    }

    func stop() {
        isTransmitting = false
        pipeline.stop()
        transports.values.forEach { $0.stop() }
        transports.removeAll()
        directory.clear()
        directory.isBrowsing = false
        sounds.stop()
        isRunning = false
    }

    /// Plays the "key up" click locally. Call on button press.
    func playPressSound() { sounds.playPress() }

    /// Plays the "roger beep" locally. Call on button release.
    func playReleaseSound() { sounds.playRelease() }

    // MARK: - PTT

    func beginTransmit() {
        guard isRunning, selectedPeer != nil, sharedKey != nil else { return }
        isTransmitting = true
    }

    func endTransmit() {
        isTransmitting = false
        outboundLevel = 0
    }

    // MARK: - Text (Morse + Chat)

    /// Send a Morse-keyed text message. Encrypts with the shared key and
    /// routes via the selected peer's transport. No-op if not running,
    /// not paired, or no peer selected.
    func sendMorse(_ text: String) {
        sendText(text, kind: .morse, packetType: .morseText)
    }

    /// Send a keyboard-typed chat message. Same wire format as `sendMorse`
    /// but a different packet type so the receiver knows not to replay
    /// it as beeps.
    func sendChat(_ text: String) {
        sendText(text, kind: .chat, packetType: .chatText)
    }

    private func sendText(_ text: String, kind: TextEntry.Kind, packetType: PacketType) {
        guard isRunning,
              let peer = selectedPeer,
              let key = sharedKey,
              let transport = transports[peer.transport] else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let bytes = Data(trimmed.utf8)
        do {
            let (ciphertext, nonce) = try crypto.seal(bytes, key: key)
            transport.sendText(packetType, payload: ciphertext, nonce: nonce, to: peer)
            packetsSent &+= 1
            appendText(TextEntry(text: trimmed, kind: kind, isIncoming: false))
        } catch {
            log.error("Text encrypt failed: \(String(describing: error))")
        }
    }

    private func appendText(_ entry: TextEntry) {
        textHistory.append(entry)
        if textHistory.count > Self.textHistoryLimit {
            textHistory.removeFirst(textHistory.count - Self.textHistoryLimit)
        }
    }

    /// Decrypt an inbound text packet and push it into the scrollback.
    /// `replayAsBeeps` fires the transient `incomingMorse` publisher
    /// (Chat messages are silent — no one wants their chat read as beeps).
    private func handleIncomingText(_ packet: Packet, kind: TextEntry.Kind, replayAsBeeps: Bool) {
        guard let key = sharedKey else { return }
        guard let plaintext = crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce),
              let text = String(data: plaintext, encoding: .utf8) else {
            packetsDropped &+= 1
            return
        }
        packetsReceived &+= 1
        appendText(TextEntry(text: text, kind: kind, isIncoming: true))
        if replayAsBeeps {
            // Pulse once — ChatView/MorseView observes this and re-plays
            // beeps/flash. Nil afterwards so an idempotent equal-text
            // message still fires on next receipt.
            incomingMorse = text
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                self?.incomingMorse = nil
            }
        }
    }

    /// Called by a display-link timer in the UI. Cheaply decays activity
    /// levels so the VU bars fall back to zero when audio stops flowing,
    /// without forcing a heavy per-packet UI update.
    func tickLevels() {
        if !isTransmitting, outboundLevel > 0 {
            outboundLevel = max(0, outboundLevel - 0.15)
        }
        inboundLevel = max(0, inboundLevel - 0.15)
    }

    // MARK: - Wiring

    private func wireAudioToTransport() {
        pipeline.onOutgoingFrame = { [weak self] opusFrame in
            Task { @MainActor in
                self?.handleOutgoingAudio(opusFrame)
            }
        }
    }

    /// Wire a single transport's receive + peer callbacks back to this
    /// session. Called for each transport brought up in `start()`.
    private func wireTransport(_ transport: AudioTransport) {
        transport.onReceive = { [weak self] packet in
            Task { @MainActor in
                self?.handleIncoming(packet)
            }
        }
        let kind = transport.kind
        transport.onPeersChanged = { [weak self] peers in
            Task { @MainActor in
                self?.directory.update(peers, from: kind)
            }
        }
    }

    private func handleOutgoingAudio(_ opusFrame: Data) {
        guard isTransmitting,
              let peer = selectedPeer,
              let key = sharedKey,
              let transport = transports[peer.transport] else { return }
        do {
            let (ciphertext, nonce) = try crypto.seal(opusFrame, key: key)
            transport.sendAudio(opusPayload: ciphertext, nonce: nonce, to: peer)
            packetsSent &+= 1
            // Use the encoded packet size as a crude proxy for input level —
            // Opus packets grow with signal complexity. Clamp to a reasonable
            // visual range; below ~20 bytes is effectively silence.
            outboundLevel = min(1.0, max(0, Double(opusFrame.count - 20) / 80.0))
        } catch {
            log.error("Encrypt failed: \(String(describing: error))")
        }
    }

    private func handleIncoming(_ packet: Packet) {
        switch packet.type {
        case .audio:
            guard let key = sharedKey else { return }
            guard let opusFrame = crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce) else {
                // Bad decrypt — silently drop. Tampering, key mismatch, or stray
                // packets all land here; we don't want to spam the UI.
                packetsDropped &+= 1
                return
            }
            if let last = lastIncomingSequence, packet.sequence > last &+ 1 {
                // Sequence jumped — infer packets lost in between.
                // Note: sequence numbers are per-transport, so switching
                // between peers on different transports will cause a false
                // "lost" spike. Acceptable for now (diagnostic only).
                packetsLost &+= packet.sequence - last - 1
            }
            lastIncomingSequence = packet.sequence
            packetsReceived &+= 1
            inboundLevel = min(1.0, max(0, Double(packet.payload.count - 20) / 80.0))
            pipeline.receive(opusFrame: opusFrame)
        case .morseText:
            handleIncomingText(packet, kind: .morse, replayAsBeeps: true)
        case .chatText:
            handleIncomingText(packet, kind: .chat, replayAsBeeps: false)
        case .ack:
            // Delivery ack — logged but not yet wired into a UI status.
            // Phase 3b will add per-message "sending/delivered" state that
            // reads this to flip indicators.
            log.info("Received ack for seq \(packet.payload.hexPrefix, privacy: .public)")
        case .ping:
            // Auto-respond with a pong so callers can use it for reachability checks.
            // No payload, no sequence coordination needed in M6.
            break
        case .pong:
            break
        }
    }
}

/// One entry in the Chat/Morse scrollback. `kind` drives the prefix glyph
/// (dit/dah for Morse, none for Chat) and `isIncoming` the arrow direction
/// in `ChatView`.
struct TextEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable, Codable {
        case morse
        case chat
    }

    let id = UUID()
    let text: String
    let kind: Kind
    let isIncoming: Bool
}

private extension Data {
    /// Short hex dump used for log lines where we want to identify a packet
    /// without spamming the whole payload.
    var hexPrefix: String {
        prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
