import Foundation
import os

/// `AudioTransport` implementation over a WebSocket relay server.
/// Connects to a Cloudflare Durable Object that broadcasts binary frames
/// to all other participants in the same channel room.
///
/// The relay is a dumb pipe — it forwards encrypted bytes without
/// inspecting content. End-to-end encryption via libsodium stays intact.
final class InternetTransport: AudioTransport, @unchecked Sendable {
    let kind: PeerTransport = .internet

    private let queue = DispatchQueue(label: "klick.internet", qos: .userInitiated)
    private let log = Logger(subsystem: "world.madhans.klick", category: "InternetTransport")

    private let channelKey: Data
    private let urlSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var selfName: String?
    private var outgoingSequence: UInt32 = 0
    private var isConnected = false
    private var reconnectDelay: TimeInterval = 1.0
    private var shouldReconnect = false

    // MARK: AudioTransport

    var onReceive: (@Sendable (Packet) -> Void)?
    var onPeersChanged: (@Sendable ([PeerInfo]) -> Void)?

    init(channelKey: Data) {
        self.channelKey = channelKey
        // Create URLSession on the calling thread (main) — not inside queue.async
        self.urlSession = URLSession(configuration: .default)
    }

    func start(advertisingAs serviceName: String) throws {
        queue.sync {
            self.selfName = serviceName
            self.shouldReconnect = true
        }
        connect()
    }

    func stop() {
        queue.sync {
            shouldReconnect = false
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            isConnected = false
            selfName = nil
        }
        onPeersChanged?([])
    }

    func setAdvertising(_ enabled: Bool) {
        if enabled {
            if !isConnected { connect() }
        } else {
            queue.sync {
                shouldReconnect = false
                webSocketTask?.cancel(with: .goingAway, reason: nil)
                webSocketTask = nil
                isConnected = false
            }
            onPeersChanged?([])
        }
    }

    func sendAudio(opusPayload: Data, nonce: Data, to peer: PeerInfo) {
        guard peer.transport == .internet else { return }
        queue.async { [weak self] in
            guard let self, self.isConnected else { return }
            let packet = Packet(
                type: .audio,
                sequence: self.nextSequence(),
                timestampMs: Packet.currentTimestampMs(),
                nonce: nonce,
                payload: opusPayload
            )
            self.sendBinary(packet.encode())
        }
    }

    @discardableResult
    func sendText(_ type: PacketType, payload: Data, nonce: Data, to peer: PeerInfo) -> UInt32? {
        guard peer.transport == .internet else { return nil }
        var seq: UInt32 = 0
        queue.sync {
            guard isConnected else { return }
            seq = nextSequence()
            let packet = Packet(
                type: type,
                sequence: seq,
                timestampMs: Packet.currentTimestampMs(),
                nonce: nonce,
                payload: payload
            )
            sendBinary(packet.encode())
        }
        return seq
    }

    // MARK: - WebSocket Connection

    private func connect() {
        queue.async { [weak self] in
            guard let self, self.shouldReconnect else { return }
            guard let name = self.selfName else { return }

            let roomId = RelayConfig.roomId(forKey: self.channelKey)
            let urlString = "\(RelayConfig.activeURL)/\(roomId)"
            guard let url = URL(string: urlString) else {
                self.log.error("Invalid relay URL: \(urlString, privacy: .public)")
                return
            }

            let task = self.urlSession.webSocketTask(with: url)
            self.webSocketTask = task
            task.resume()

            // Send join message
            let join = "{\"type\":\"join\",\"name\":\"\(name)\"}"
            task.send(.string(join)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.log.error("Join send failed: \(error.localizedDescription, privacy: .public)")
                    self.scheduleReconnect()
                    return
                }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.isConnected = true
                    self.reconnectDelay = 1.0
                }
                self.log.info("Connected to relay room \(roomId, privacy: .public)")
                self.receiveLoop()
            }

            // Keepalive ping every 30s
            self.schedulePing()
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleTextMessage(text)
                case .data(let data):
                    self.handleBinaryMessage(data)
                @unknown default:
                    break
                }
                self.receiveLoop() // Continue listening
            case .failure(let error):
                self.log.error("WebSocket receive error: \(error.localizedDescription, privacy: .public)")
                self.queue.async { self.isConnected = false }
                self.scheduleReconnect()
            }
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return }

        if type == "peers", let names = msg["names"] as? [String] {
            let peers = names
                .filter { $0 != selfName }
                .map { PeerInfo(name: $0, transport: .internet, endpoint: nil) }
            onPeersChanged?(peers)
        }
    }

    private func handleBinaryMessage(_ data: Data) {
        guard let packet = try? Packet.decode(data) else { return }
        onReceive?(packet)
    }

    private func sendBinary(_ data: Data) {
        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error {
                self?.log.error("Send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        queue.async { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.isConnected = false
            let delay = self.reconnectDelay
            self.reconnectDelay = min(self.reconnectDelay * 2, 30.0) // exponential backoff, max 30s

            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.connect()
            }
            self.log.info("Reconnecting in \(delay, privacy: .public)s")
        }
    }

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.isConnected else { return }
            self.webSocketTask?.sendPing { [weak self] error in
                if let error {
                    self?.log.error("Ping failed: \(error.localizedDescription, privacy: .public)")
                    self?.scheduleReconnect()
                    return
                }
                self?.schedulePing()
            }
        }
    }

    // MARK: - Helpers

    private func nextSequence() -> UInt32 {
        outgoingSequence &+= 1
        return outgoingSequence
    }
}
