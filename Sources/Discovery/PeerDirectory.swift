import Foundation
import SwiftUI

/// Unified peer list feeding the UI. Each `AudioTransport` publishes its
/// own peers via `onPeersChanged` — PTTSession forwards those updates into
/// this directory, which merges them into a single sorted list.
///
/// Merge strategy (Phase 1): concatenate, preserving transport order
/// (WiFi first, then Nearby) with alphabetical ordering inside each bucket.
/// Peers discovered on multiple transports appear as separate rows tagged
/// with their respective transport — the user picks which link to send on
/// by selecting the matching row. Collapsing same-name peers into a single
/// row with a "BOTH" tag is deferred to a later polish pass.
///
/// Runs on the main actor because the UI binds to `peers` and `isBrowsing`
/// directly via `@ObservedObject` / `@Published`.
@MainActor
final class PeerDirectory: ObservableObject {
    /// Merged peer list, rebuilt whenever any transport reports a change.
    @Published private(set) var peers: [PeerInfo] = []

    /// Mirrors `PTTSession.isRunning` — the UI uses this to render the
    /// empty state (scanning vs offline). Set by the session; no transport
    /// talks to it directly.
    @Published var isBrowsing = false

    /// Informational only. Transports do their own self-filtering when
    /// publishing peers, so the directory doesn't need to re-filter here.
    /// Stored so future features (e.g. a "this is me" indicator) can read it.
    var selfName: String?

    private var peersByTransport: [PeerTransport: [PeerInfo]] = [:]

    /// Called by PTTSession with the full current peer set from one
    /// transport. Always a full replace, never a diff — keeps merging
    /// trivial and avoids add/remove race bugs if callbacks interleave.
    func update(_ newPeers: [PeerInfo], from transport: PeerTransport) {
        peersByTransport[transport] = newPeers
        rebuild()
    }

    /// Drop all cached peers. Called on session stop so the list clears
    /// immediately instead of lingering through the next restart.
    func clear() {
        peersByTransport.removeAll()
        peers = []
    }

    /// Check if a device with this name is currently discoverable.
    func isOnline(_ memberName: String) -> Bool {
        peers.contains { $0.name == memberName }
    }

    /// Resolve a member name to the best available PeerInfo (WiFi > Nearby > Mesh).
    func resolve(_ memberName: String) -> PeerInfo? {
        peers.first { $0.name == memberName && $0.transport == .wifi }
        ?? peers.first { $0.name == memberName && $0.transport == .nearby }
        ?? peers.first { $0.name == memberName && $0.transport == .mesh }
    }

    private func rebuild() {
        var merged: [PeerInfo] = []
        for kind in [PeerTransport.wifi, .nearby, .mesh, .internet] {
            if let bucket = peersByTransport[kind] {
                merged.append(contentsOf: bucket)
            }
        }
        peers = merged
    }
}
