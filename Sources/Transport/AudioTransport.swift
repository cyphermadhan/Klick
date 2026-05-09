import Foundation

/// Where a discovered peer came from. Each concrete transport tags the peers
/// it publishes with one of these; the UI reads the tag to show a small
/// "WIFI" / "NEAR" pill next to each row.
///
/// When Phase 3 adds LoRa, a `.mesh` case joins this enum — PeerInfo and the
/// directory then route sends through the matching transport automatically.
enum PeerTransport: String, Sendable, Hashable {
    /// Bonjour + UDP over infrastructure WiFi (Klick 1.0 path).
    case wifi
    /// MultipeerConnectivity over Bluetooth + peer-to-peer WiFi (AWDL).
    /// Works with no router / no cell.
    case nearby

    /// Short label shown on peer list rows.
    var tag: String {
        switch self {
        case .wifi:   return "WIFI"
        case .nearby: return "NEAR"
        }
    }
}

/// Network transport capable of carrying encrypted `Packet`s between peers.
///
/// Implementations:
///   • `UDPTransport`  — NWListener + NWConnection over UDP, Bonjour discovery
///   • `MPCTransport`  — MultipeerConnectivity (MCSession over BLE + AWDL)
///
/// Each transport owns its own peer discovery and internally maps
/// `PeerInfo.id` → the transport-specific handle (NWEndpoint or MCPeerID).
/// Callers see one uniform surface: start, send, receive, observe peers.
///
/// Callbacks (`onReceive`, `onPeersChanged`) fire on the transport's internal
/// queue. The owner (PTTSession) is responsible for hopping to the main actor
/// before touching observable state.
protocol AudioTransport: AnyObject {
    /// Which transport class this is. Used by the coordinator to tag peers
    /// and to route outbound audio to the right implementation.
    var kind: PeerTransport { get }

    /// Begin listening + advertising. `serviceName` is the user-facing device
    /// name other peers will see in their lists.
    func start(advertisingAs serviceName: String) throws

    /// Tear down. Safe to call repeatedly; no-op if not started.
    func stop()

    /// Send one encrypted audio frame to a specific peer. The transport is
    /// responsible for locating the right endpoint from `peer.id`. If the
    /// peer is not currently reachable, the packet is dropped silently
    /// (voice is loss-tolerant; no retry).
    func sendAudio(opusPayload: Data, nonce: Data, to peer: PeerInfo)

    /// Delivered for every inbound `Packet` the transport successfully
    /// decodes off the wire. Wire-level crypto lives one level up in
    /// `PTTSession.handleIncoming`.
    var onReceive: (@Sendable (Packet) -> Void)? { get set }

    /// Fired when the transport's view of the peer set changes. Always
    /// carries the full current list (not a diff) to keep merging simple
    /// in `PeerDirectory`.
    var onPeersChanged: (@Sendable ([PeerInfo]) -> Void)? { get set }
}
