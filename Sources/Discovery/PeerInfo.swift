import Foundation
import Network

/// A peer discovered on the local network via Bonjour.
///
/// We keep the raw `NWEndpoint` so `NWConnection` can be initialized from it
/// directly — Network.framework resolves the Bonjour service to IP/port for
/// us on connect. No manual `NetService.resolve` ceremony needed.
struct PeerInfo: Identifiable, Hashable, Sendable {
    let name: String
    let endpoint: NWEndpoint

    /// Stable identifier derived from the Bonjour service name. Two different
    /// instances of the same service from the same host will have the same id,
    /// which matches what we want (replace the older entry in the peer list).
    var id: String { name }
}
