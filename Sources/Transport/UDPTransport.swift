import Foundation
import Network
import os

/// `AudioTransport` implementation over Bonjour + UDP (infrastructure WiFi).
///
/// Owns three pieces of Network.framework state:
///   • `NWListener` — accepts inbound UDP datagrams from peers; advertises
///     ourselves under `_walkie._udp.` so other Klick instances can find us.
///   • `NWBrowser`  — discovers peers advertising the same Bonjour service.
///     Emits peer additions / removals through `onPeersChanged`.
///   • `NWConnection` map — one per peer we're actively sending to.
///
/// All state mutation happens on a single serial `DispatchQueue`. Callbacks
/// (`onReceive`, `onPeersChanged`) fire on that same queue; the owner hops
/// to the main actor before touching UI state (see `PTTSession`).
final class UDPTransport: AudioTransport, @unchecked Sendable {
    enum TransportError: Error, Sendable {
        case notStarted
        case listenerFailed(NWError)
        case bindFailed
    }

    let kind: PeerTransport = .wifi

    private let queue = DispatchQueue(label: "klick.udp", qos: .userInitiated)
    private let log = Logger(subsystem: "world.madhans.klick", category: "UDPTransport")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var sendConnections: [NWEndpoint: NWConnection] = [:]
    private var boundPort: UInt16?
    private var outgoingSequence: UInt32 = 0

    /// Name → endpoint, populated from Bonjour browse results so `sendAudio`
    /// can resolve a `PeerInfo` (which carries only the name) back to the
    /// live `NWEndpoint` the current discovery round produced.
    private var endpointsByName: [String: NWEndpoint] = [:]
    private var selfName: String?

    // MARK: AudioTransport

    var onReceive: (@Sendable (Packet) -> Void)?
    var onPeersChanged: (@Sendable ([PeerInfo]) -> Void)?

    /// The local UDP port we bound to. Available after `start()` succeeds.
    var localPort: UInt16? { queue.sync { boundPort } }

    func start(advertisingAs serviceName: String) throws {
        queue.sync { self.selfName = serviceName }

        // Listener: accept inbound UDP + advertise via Bonjour.
        let listenerParams = NWParameters.udp
        listenerParams.allowLocalEndpointReuse = true
        listenerParams.includePeerToPeer = true
        let listener = try NWListener(using: listenerParams)
        listener.service = NWListener.Service(name: serviceName, type: "_walkie._udp.")

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port {
                    self.boundPort = port.rawValue
                    self.log.info("UDP listener bound to port \(port.rawValue, privacy: .public)")
                }
            case let .failed(err):
                self.log.error("Listener failed: \(String(describing: err))")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptIncoming(connection)
        }

        listener.start(queue: queue)
        self.listener = listener

        // Browser: discover other Klick peers on the network.
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_walkie._udp.", domain: nil)
        let browserParams = NWParameters()
        browserParams.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: browserParams)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .failed(err):
                self.log.error("Bonjour browser failed: \(String(describing: err))")
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            browser?.cancel()
            browser = nil
            for (_, conn) in sendConnections { conn.cancel() }
            sendConnections.removeAll()
            endpointsByName.removeAll()
            boundPort = nil
            selfName = nil
        }
        // Clear peers in the directory. Keep this outside the queue.sync to
        // avoid re-entering the queue from the owner's callback implementation.
        onPeersChanged?([])
    }

    func sendAudio(opusPayload: Data, nonce: Data, to peer: PeerInfo) {
        guard peer.transport == .wifi else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // Prefer the endpoint carried on the PeerInfo (from browse
            // results); fall back to our internal map in case the caller
            // holds an older PeerInfo than the current discovery round.
            let endpoint = peer.endpoint ?? self.endpointsByName[peer.name]
            guard let endpoint else {
                self.log.error("sendAudio: no endpoint for peer \(peer.name, privacy: .public)")
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
            self.sendInternal(pkt, to: endpoint)
        }
    }

    func sendText(_ type: PacketType, payload: Data, nonce: Data, to peer: PeerInfo) {
        guard peer.transport == .wifi else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let endpoint = peer.endpoint ?? self.endpointsByName[peer.name]
            guard let endpoint else {
                self.log.error("sendText: no endpoint for peer \(peer.name, privacy: .public)")
                return
            }
            self.outgoingSequence &+= 1
            let pkt = Packet(
                type: type,
                sequence: self.outgoingSequence,
                timestampMs: Packet.currentTimestampMs(),
                nonce: nonce,
                payload: payload
            )
            self.sendInternal(pkt, to: endpoint)
        }
    }

    /// Back-door used by tests + Phase 0 diagnostics to send a raw Packet.
    func send(_ packet: Packet, to endpoint: NWEndpoint) {
        queue.async { [weak self] in
            self?.sendInternal(packet, to: endpoint)
        }
    }

    func sendPing(to endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self else { return }
            self.outgoingSequence &+= 1
            let pkt = Packet(
                type: .ping,
                sequence: self.outgoingSequence,
                timestampMs: Packet.currentTimestampMs(),
                nonce: Packet.zeroNonce(),
                payload: Data()
            )
            self.sendInternal(pkt, to: endpoint)
        }
    }

    // MARK: - Private

    private func sendInternal(_ packet: Packet, to endpoint: NWEndpoint) {
        let data = packet.encode()
        let conn = self.connection(to: endpoint)
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.error("UDP send failed: \(String(describing: error))") }
        })
    }

    private func connection(to endpoint: NWEndpoint) -> NWConnection {
        if let existing = sendConnections[endpoint], existing.state != .cancelled {
            return existing
        }
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let err):
                self.log.error("Send conn to \(String(describing: endpoint), privacy: .public) failed: \(String(describing: err))")
            case .cancelled:
                self.queue.async { self.sendConnections.removeValue(forKey: endpoint) }
            default: break
            }
        }
        conn.start(queue: queue)
        sendConnections[endpoint] = conn
        return conn
    }

    private func acceptIncoming(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        // `receiveMessage` on a UDP connection delivers one datagram per call.
        // Apple always sets `isComplete = true` on UDP (each datagram is its
        // own complete message) — that flag does NOT mean the listener should
        // close. We must re-arm the receive after every packet, stopping only
        // on a hard error, otherwise we stop hearing anything after packet #1.
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let pkt = try Packet.decode(data)
                    self.onReceive?(pkt)
                } catch {
                    self.log.error("Packet decode failed: \(String(describing: error))")
                }
            }
            if let error {
                self.log.error("Receive error: \(String(describing: error))")
                return
            }
            self.receiveNext(on: connection)
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var nextByName: [String: NWEndpoint] = [:]
        var peers: [PeerInfo] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if let selfName, name == selfName { continue }
            nextByName[name] = result.endpoint
            peers.append(PeerInfo(name: name, transport: .wifi, endpoint: result.endpoint))
        }
        self.endpointsByName = nextByName
        // Stable alphabetical ordering — matches what `BonjourBrowser` used
        // to produce, so the UI has consistent row positions.
        peers.sort { $0.name < $1.name }
        onPeersChanged?(peers)
    }
}
