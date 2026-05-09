import Foundation
import os

/// `AudioTransport` implementation over a LoRa radio paired by BLE.
///
/// Only supports **text** packets (`.morseText`, `.chatText`, `.ack`).
/// Voice (`.audio`) is declined at this layer with a log line — LoRa's
/// kilobit-per-second ceiling + EU duty-cycle cap make voice a different
/// product (see plan-v2.md's "Why voice-over-LoRa is off the table").
///
/// Layering, innermost → outermost:
///
///   Klick `Packet` (libsodium-encrypted)
///     wrapped by
///   Meshtastic `ToRadio { packet: MeshPacket { decoded: Data { portnum:
///     TEXT_MESSAGE_APP, payload: ... } } }`  (Phase 3b.2b)
///     written to
///   `ToRadio` GATT characteristic
///     sent over
///   BLE → Meshtastic firmware → LoRa RF → peer's Meshtastic → peer's Klick
///
/// Klick's crypto and sequence numbers live in the innermost layer, so
/// other users sharing a Meshtastic channel can't read our traffic even
/// though they share the channel key.
///
/// Duty-cycle + region guards live at the `send` entry point: a TX that
/// would bust the EU 1 % cap is dropped with a log line, and a request
/// to a peer over mesh while the radio's hardware region disagrees with
/// the user's preference is refused (enforced by `PTTSession` upstream,
/// since that's where region state is visible).
final class LoRaBridge: AudioTransport, @unchecked Sendable {
    let kind: PeerTransport = .mesh

    /// Byte-level BLE link to the radio. Injected so tests can drive it
    /// with `FakeMeshtasticLink`; the production app will hand in a
    /// `CoreBluetoothMeshtasticLink` once Phase 3b.2b lands.
    private let link: MeshtasticLink
    /// Translates Klick `Packet` bytes ↔ Meshtastic protobuf frames.
    /// The Phase 3b.1 implementation is `StubMeshtasticCodec`, which is
    /// NOT wire-compatible with real Meshtastic firmware.
    private let codec: MeshtasticCodec
    /// EU-only airtime tracker. No-op outside `.eu`.
    private let ledger: DutyCycleLedger
    /// User's currently-selected region. Passed in at start time so the
    /// bridge can decide whether the ledger is active.
    private let region: Region
    private let log = Logger(subsystem: "world.madhans.klick", category: "LoRaBridge")

    /// Most recently announced peer, so the transport has something to
    /// return via `onPeersChanged`. The LoRa layer doesn't do per-peer
    /// addressing the way UDP / MPC do — every connected radio is on the
    /// same Meshtastic channel and messages are broadcast with an
    /// optional recipient id inside the `MeshPacket`. For Klick, the
    /// "peer" at this layer is just "the radio is up, so treat the
    /// paired key holder as reachable over mesh".
    private var advertisedPeer: PeerInfo?

    var onReceive: (@Sendable (Packet) -> Void)?
    var onPeersChanged: (@Sendable ([PeerInfo]) -> Void)?

    /// Outbound sequence counter — per-transport, like UDP and MPC.
    private var outgoingSequence: UInt32 = 0

    init(link: MeshtasticLink,
         codec: MeshtasticCodec = StubMeshtasticCodec(),
         ledger: DutyCycleLedger = DutyCycleLedger(),
         region: Region = RegionStore.current) {
        self.link = link
        self.codec = codec
        self.ledger = ledger
        self.region = region
    }

    // MARK: - AudioTransport

    func start(advertisingAs serviceName: String) throws {
        link.onFrame = { [weak self] frame in
            self?.handleInboundFrame(frame)
        }
        link.onConnectedChange = { [weak self] connected in
            self?.handleConnectedChange(connected, serviceName: serviceName)
        }
        link.start()
        // Surface immediately if the link is already connected — the
        // change callback only fires on transitions.
        if link.isConnected {
            handleConnectedChange(true, serviceName: serviceName)
        }
    }

    func stop() {
        link.stop()
        link.onFrame = nil
        link.onConnectedChange = nil
        advertisedPeer = nil
        onPeersChanged?([])
    }

    func sendAudio(opusPayload: Data, nonce: Data, to peer: PeerInfo) {
        // Voice over LoRa is out of scope (see plan-v2 appendix). The UI
        // also blocks the PTT button for mesh peers, so this path should
        // only trigger if that gate slips — log loudly.
        log.error("sendAudio over mesh is not supported; dropping frame")
    }

    @discardableResult
    func sendText(_ type: PacketType, payload: Data, nonce: Data, to peer: PeerInfo) -> UInt32? {
        guard peer.transport == .mesh else { return nil }
        guard link.isConnected else {
            log.error("sendText: mesh link not connected; dropping")
            return nil
        }
        // EU duty-cycle gate. We don't yet know the real airtime — the
        // Meshtastic firmware computes it from SF/BW/length on the other
        // side. Estimate conservatively at 1500 ms per packet for the
        // ledger until Phase 3b.2b plumbs the real figure back from the
        // radio.
        let estimatedAirtimeMs = 1_500
        if let dutyCycle = region.dutyCycle {
            guard ledger.canTransmit(durationMs: estimatedAirtimeMs, dutyCycle: dutyCycle) else {
                log.error("sendText: duty-cycle budget exhausted; dropping")
                return nil
            }
        }

        outgoingSequence &+= 1
        let seq = outgoingSequence
        let pkt = Packet(
            type: type,
            sequence: seq,
            timestampMs: Packet.currentTimestampMs(),
            nonce: nonce,
            payload: payload
        )
        let klickFrame = pkt.encode()
        let meshFrame = codec.encodeToRadio(klickFrame)
        let ok = link.write(meshFrame)
        if !ok {
            log.error("sendText: link write failed")
            return nil
        }
        // Only bill the ledger on successful write. A dropped write
        // doesn't consume spectrum.
        if region.dutyCycle != nil {
            ledger.record(durationMs: estimatedAirtimeMs)
        }
        return seq
    }

    // MARK: - Inbound

    private func handleInboundFrame(_ frame: Data) {
        guard let klickBytes = codec.decodeFromRadio(frame) else {
            // Frame was valid Meshtastic but not a Klick payload (e.g.
            // someone else's chat on the same channel, position updates,
            // routing). Drop quietly.
            return
        }
        do {
            let packet = try Packet.decode(klickBytes)
            onReceive?(packet)
        } catch {
            log.error("Inbound frame failed to decode as Klick Packet: \(String(describing: error))")
        }
    }

    private func handleConnectedChange(_ connected: Bool, serviceName: String) {
        if connected {
            let peer = PeerInfo(name: serviceName + " MESH", transport: .mesh, endpoint: nil)
            advertisedPeer = peer
            onPeersChanged?([peer])
        } else {
            advertisedPeer = nil
            onPeersChanged?([])
        }
    }
}
