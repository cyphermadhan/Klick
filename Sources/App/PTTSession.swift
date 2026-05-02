import Foundation
import Network
import os

/// Top-level coordinator that owns every subsystem and exposes a small
/// surface to the UI: "start the app", "begin transmitting", "end transmitting",
/// "pick this peer".
///
/// Responsibilities:
/// - Start the UDP listener and advertise it via Bonjour.
/// - Start the Bonjour browser and publish peer changes.
/// - On mic frame: encrypt → send to selected peer.
/// - On UDP receive: decrypt → enqueue for playback.
///
/// Only transmits while `isTransmitting` is true (PTT button held).
@MainActor
final class PTTSession: ObservableObject {
    // Observable state for the UI
    @Published private(set) var isRunning = false
    @Published private(set) var isTransmitting = false
    @Published private(set) var isPaired = false
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

    /// Loss percentage clamped to a display-friendly 0…100.
    var lossPercent: Double {
        let total = Double(packetsReceived + packetsLost)
        guard total > 0 else { return 0 }
        return (Double(packetsLost) / total) * 100
    }

    // Sub-systems
    let pipeline = AudioPipeline()
    let transport = UDPTransport()
    let browser = BonjourBrowser()
    private let crypto = CryptoService()
    private let pairing = PairingService()
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "PTTSession")

    private var sharedKey: Data?

    init() {
        self.isPaired = (try? pairing.currentKey()) != nil
        self.pipeline.loopback = false
        wireAudioToTransport()
        wireTransportToAudio()
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

        // Start transport + Bonjour.
        do {
            let name = DeviceName.current
            try transport.start(advertisingAs: name)
            browser.selfName = name
            browser.start()
            isRunning = true
            log.info("PTT session running as \(name, privacy: .public)")
        } catch {
            errorMessage = "Network start failed: \(error.localizedDescription)"
            pipeline.stop()
            isRunning = false
        }
    }

    func stop() {
        isTransmitting = false
        pipeline.stop()
        transport.stop()
        browser.stop()
        isRunning = false
    }

    // MARK: - PTT

    func beginTransmit() {
        guard isRunning, selectedPeer != nil, sharedKey != nil else { return }
        isTransmitting = true
    }

    func endTransmit() {
        isTransmitting = false
        outboundLevel = 0
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

    private func wireTransportToAudio() {
        transport.onReceive = { [weak self] packet, _ in
            Task { @MainActor in
                self?.handleIncoming(packet)
            }
        }
    }

    private func handleOutgoingAudio(_ opusFrame: Data) {
        guard isTransmitting,
              let peer = selectedPeer,
              let key = sharedKey else { return }
        do {
            let (ciphertext, nonce) = try crypto.seal(opusFrame, key: key)
            transport.sendAudio(opusPayload: ciphertext, nonce: nonce, to: peer.endpoint)
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
                packetsLost &+= packet.sequence - last - 1
            }
            lastIncomingSequence = packet.sequence
            packetsReceived &+= 1
            inboundLevel = min(1.0, max(0, Double(packet.payload.count - 20) / 80.0))
            pipeline.receive(opusFrame: opusFrame)
        case .ping:
            // Auto-respond with a pong so callers can use it for reachability checks.
            // No payload, no sequence coordination needed in M6.
            break
        case .pong:
            break
        }
    }
}
