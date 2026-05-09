import Foundation
import Network

/// A peer discovered by one of the `AudioTransport` implementations.
///
/// `PeerInfo` is the transport-agnostic view model. The concrete endpoint
/// (Bonjour `NWEndpoint` for WiFi, `MCPeerID` for Nearby) is *not* stored
/// here — each transport keeps its own internal `name → handle` map so that
/// PeerInfo can stay free of MultipeerConnectivity / Network types in the
/// UI layer. The transport looks its handle up at send time using `id`.
///
/// Two peers with the same device name but different transports are
/// considered distinct rows (the `id` includes the transport tag), and both
/// appear in the merged peer list. This is rare in practice — most users
/// will have exactly one transport active — but when it happens the user
/// sees exactly what they can select, with no hidden routing magic.
struct PeerInfo: Identifiable, Hashable, Sendable {
    /// Display name (typically the user's device name).
    let name: String
    /// Which transport discovered this peer.
    let transport: PeerTransport
    /// Only populated for `.wifi` peers. `MPCTransport` resolves its own
    /// peers by name internally and leaves this nil.
    let endpoint: NWEndpoint?

    init(name: String, transport: PeerTransport, endpoint: NWEndpoint? = nil) {
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
    }

    /// Stable identifier scoped by transport. SwiftUI uses this for ForEach
    /// row identity; PeerDirectory uses it as a dictionary key.
    var id: String { "\(transport.rawValue):\(name)" }
}
