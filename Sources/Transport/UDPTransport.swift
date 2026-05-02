import Foundation
import Network
import os

/// Symmetric UDP transport for PTT.
///
/// Each app instance:
///   • Binds an `NWListener` on an ephemeral UDP port to *receive* from peers.
///     The chosen port is published to Bonjour in M5.
///   • Opens an `NWConnection` per peer endpoint to *send* audio frames.
///
/// At M2 we only expose basic send/receive with raw `Packet` framing. The
/// jitter buffer, re-ordering, and loss detection live in M6.
final class UDPTransport: @unchecked Sendable {
    enum TransportError: Error, Sendable {
        case notStarted
        case listenerFailed(NWError)
        case bindFailed
    }

    private let queue = DispatchQueue(label: "walkie.udp", qos: .userInitiated)
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "UDPTransport")

    private var listener: NWListener?
    private var sendConnections: [NWEndpoint: NWConnection] = [:]
    private var boundPort: UInt16?
    private var outgoingSequence: UInt32 = 0

    /// Called on the transport queue whenever a valid packet is received.
    /// Hop to the main actor before touching UI state.
    var onReceive: (@Sendable (Packet, NWEndpoint) -> Void)?

    /// The local UDP port we bound to. Available after `start()` succeeds.
    var localPort: UInt16? { queue.sync { boundPort } }

    /// Start listening for inbound UDP packets. Picks an ephemeral port.
    ///
    /// If `serviceName` is provided, the listener is also registered with
    /// Bonjour under `_walkie._udp.` so other devices' `BonjourBrowser`
    /// can find us. The name is typically the user's device name.
    func start(advertisingAs serviceName: String? = nil) throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        let listener = try NWListener(using: params)

        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: "_walkie._udp.")
        }

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
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for (_, conn) in sendConnections { conn.cancel() }
            sendConnections.removeAll()
            boundPort = nil
        }
    }

    /// Send a pre-built `Packet` to a peer. The caller owns sequence numbering
    /// when they build the packet; `sendAudio` / `sendPing` below do it for you.
    func send(_ packet: Packet, to endpoint: NWEndpoint) {
        let data = packet.encode()
        queue.async { [weak self] in
            guard let self else { return }
            let conn = self.connection(to: endpoint)
            conn.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error { self?.log.error("UDP send failed: \(String(describing: error))") }
            })
        }
    }

    func sendAudio(opusPayload: Data, nonce: Data, to endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self else { return }
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
                    self.onReceive?(pkt, connection.endpoint)
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
}
