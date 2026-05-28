import Foundation
// @preconcurrency: MultipeerConnectivity's ObjC types (MCPeerID,
// MCNearbyServiceBrowser, MCSession) are not marked Sendable, but they're
// safe to capture in our @Sendable queue.async closures — we only touch
// them on our internal serial queue or through the session's send API
// which Apple documents as thread-safe. Downgrading these to warnings
// lets us build under Swift 6 strict concurrency.
@preconcurrency import MultipeerConnectivity
import os

/// `AudioTransport` implementation over MultipeerConnectivity — Bluetooth +
/// peer-to-peer WiFi (AWDL). Works with no router, no cell, no internet.
///
/// Architecture:
///   • `MCNearbyServiceAdvertiser` — publishes "I'm here", service type `klick-ptt`
///   • `MCNearbyServiceBrowser`   — finds other Klick instances
///   • `MCSession`                — the data pipe. Encryption OFF (we keep our
///                                   libsodium layer on top — see PTTSession)
///
/// Connection symmetry: when two peers find each other, both advertise AND
/// both browse. To avoid a double-invite race, only the peer with the
/// alphabetically-lower display name sends the invitation; the other side's
/// advertiser auto-accepts. MPC's internal state machine deduplicates the
/// rest.
///
/// Auto-accept invitations: any peer offering the service gets a session
/// immediately. This is safe because the real trust boundary is the
/// libsodium shared key — a peer that can't decrypt audio packets is
/// effectively invisible, MPC is just the pipe.
///
/// Threading: all state mutation flows through `queue`. Delegate callbacks
/// from MPC arrive on private queues (main for advertiser/browser, private
/// for session) — we immediately dispatch to `queue` before touching any
/// state so the owner sees a single consistent view.
final class MPCTransport: NSObject, AudioTransport, @unchecked Sendable {
    // MPC service type rules: ≤15 chars, lowercase ASCII letters/digits/hyphens,
    // may not start or end with a hyphen, may not contain consecutive hyphens.
    // Bumped to `klick-ptt-v1` to leave room for future protocol changes.
    private static let serviceType = "klick-ptt-v1"

    let kind: PeerTransport = .nearby

    private let queue = DispatchQueue(label: "klick.mpc", qos: .userInitiated)
    private let log = Logger(subsystem: "world.madhans.klick", category: "MPCTransport")

    private var selfPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// Display name → MCPeerID for outbound routing. Populated when a
    /// session transitions to `.connected`; cleared on `.notConnected`.
    private var peersByName: [String: MCPeerID] = [:]
    private var outgoingSequence: UInt32 = 0

    // MARK: AudioTransport

    var onReceive: (@Sendable (Packet) -> Void)?
    var onPeersChanged: (@Sendable ([PeerInfo]) -> Void)?

    func start(advertisingAs serviceName: String) throws {
        stop() // idempotent restart

        let peerID = MCPeerID(displayName: serviceName)
        let session = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .none
        )
        session.delegate = self

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: nil,
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()

        let browser = MCNearbyServiceBrowser(
            peer: peerID,
            serviceType: Self.serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()

        queue.sync {
            self.selfPeerID = peerID
            self.session = session
            self.advertiser = advertiser
            self.browser = browser
        }

        log.info("MPC transport started as \(serviceName, privacy: .public)")
    }

    func stop() {
        let (adv, br, sess): (MCNearbyServiceAdvertiser?, MCNearbyServiceBrowser?, MCSession?) = queue.sync {
            let a = self.advertiser; let b = self.browser; let s = self.session
            self.advertiser = nil
            self.browser = nil
            self.session = nil
            self.selfPeerID = nil
            self.peersByName.removeAll()
            return (a, b, s)
        }
        adv?.stopAdvertisingPeer()
        br?.stopBrowsingForPeers()
        sess?.disconnect()
        onPeersChanged?([])
    }

    func setAdvertising(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.advertiser?.startAdvertisingPeer()
            } else {
                self.advertiser?.stopAdvertisingPeer()
            }
        }
    }

    func sendAudio(opusPayload: Data, nonce: Data, to peer: PeerInfo) {
        guard peer.transport == .nearby else { return }
        queue.async { [weak self] in
            guard let self,
                  let session = self.session,
                  let mcPeer = self.peersByName[peer.name]
            else {
                return
            }
            guard session.connectedPeers.contains(mcPeer) else {
                // Peer visible but not yet fully connected. Drop silently —
                // voice is loss-tolerant, and the connection will complete
                // within a second or two of discovery.
                return
            }
            self.outgoingSequence &+= 1
            let pkt = Packet(
                type: .audio,
                sequence: self.outgoingSequence,
                timestampMs: Packet.currentTimestampMs(),
                nonce: nonce,
                payload: opusPayload
            )
            let data = pkt.encode()
            do {
                try session.send(data, toPeers: [mcPeer], with: .unreliable)
            } catch {
                self.log.error("MPC send failed: \(String(describing: error))")
            }
        }
    }

    @discardableResult
    func sendText(_ type: PacketType, payload: Data, nonce: Data, to peer: PeerInfo) -> UInt32? {
        guard peer.transport == .nearby else { return nil }
        // Pre-assign sequence synchronously so it's returned in time for
        // delivery-tracking bookkeeping in the caller.
        let seq: UInt32 = queue.sync {
            self.outgoingSequence &+= 1
            return self.outgoingSequence
        }
        queue.async { [weak self] in
            guard let self,
                  let session = self.session,
                  let mcPeer = self.peersByName[peer.name] else { return }
            guard session.connectedPeers.contains(mcPeer) else { return }
            let pkt = Packet(
                type: type,
                sequence: seq,
                timestampMs: Packet.currentTimestampMs(),
                nonce: nonce,
                payload: payload
            )
            let data = pkt.encode()
            do {
                // Text goes over reliable — it's tiny and we don't want
                // users typing something the other end never sees.
                try session.send(data, toPeers: [mcPeer], with: .reliable)
            } catch {
                self.log.error("MPC text send failed: \(String(describing: error))")
            }
        }
        return seq
    }

    // MARK: - Private

    private func publishPeersLocked() {
        let peers = peersByName.keys
            .sorted()
            .map { PeerInfo(name: $0, transport: .nearby, endpoint: nil) }
        onPeersChanged?(peers)
    }
}

// MARK: - MCSessionDelegate

extension MPCTransport: MCSessionDelegate {
    func session(_ session: MCSession,
                 peer peerID: MCPeerID,
                 didChange state: MCSessionState) {
        queue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.peersByName[peerID.displayName] = peerID
                self.log.info("MPC peer connected: \(peerID.displayName, privacy: .public)")
                self.publishPeersLocked()
            case .notConnected:
                if self.peersByName.removeValue(forKey: peerID.displayName) != nil {
                    self.log.info("MPC peer disconnected: \(peerID.displayName, privacy: .public)")
                    self.publishPeersLocked()
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession,
                 didReceive data: Data,
                 fromPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let packet = try Packet.decode(data)
                self.onReceive?(packet)
            } catch {
                self.log.error("MPC packet decode failed: \(String(describing: error))")
            }
        }
    }

    // Unused for audio PTT — MPC's stream/resource APIs carry file-style
    // payloads we don't need. Left as no-ops rather than removed because
    // MCSessionDelegate's method requirements are non-optional.
    func session(_ session: MCSession,
                 didReceive stream: InputStream,
                 withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession,
                 didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession,
                 didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID,
                 at localURL: URL?,
                 withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MPCTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept every invitation — the real access control is the
        // shared libsodium key one layer up. Without it, the peer can't
        // decode any audio we send, and any audio they send gets dropped
        // silently in PTTSession.handleIncoming.
        let session = queue.sync { self.session }
        invitationHandler(session != nil, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didNotStartAdvertisingPeer error: Error) {
        log.error("MPC advertiser failed: \(String(describing: error))")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MPCTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        queue.async { [weak self] in
            guard let self,
                  let selfID = self.selfPeerID,
                  let session = self.session
            else { return }

            // Symmetry breaker: both sides discover each other, but only the
            // alphabetically-lower display name initiates the invite. The
            // other side's advertiser auto-accepts. Prevents a double-invite
            // race that can produce two sessions for the same pair.
            guard selfID.displayName < peerID.displayName else {
                self.log.debug("MPC waiting for invite from \(peerID.displayName, privacy: .public)")
                return
            }

            self.log.info("MPC inviting \(peerID.displayName, privacy: .public)")
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.peersByName.removeValue(forKey: peerID.displayName) != nil {
                self.log.info("MPC lost peer: \(peerID.displayName, privacy: .public)")
                self.publishPeersLocked()
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser,
                 didNotStartBrowsingForPeers error: Error) {
        log.error("MPC browser failed: \(String(describing: error))")
    }
}
