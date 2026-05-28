import Foundation
import UIKit
import os

/// Top-level coordinator that owns every subsystem and exposes a small
/// surface to the UI: "start the app", "begin transmitting", "end transmitting",
/// "pick peers".
///
/// Responsibilities:
/// - Start the configured transports (WiFi/UDP, Nearby/MPC, or both —
///   driven by the user's RangeMode preference).
/// - Start audio capture + playback.
/// - On mic frame: encrypt → fan out to all selected peers.
/// - On transport receive: trial-decrypt across channel keys → playback.
/// - Merge per-transport peer lists into a single `PeerDirectory` for the UI.
///
/// Only transmits while `isTransmitting` is true (PTT button held).
@MainActor
final class PTTSession: ObservableObject {
    // Observable state for the UI
    @Published private(set) var isRunning = false
    @Published private(set) var isTransmitting = false
    @Published private(set) var isPaired = false
    /// Human-checkable fingerprint of the active channel's key.
    @Published private(set) var keyFingerprint: String?
    @Published var selectedPeers: Set<PeerInfo> = []
    /// Convenience for UI display — first selected peer name or summary.
    var selectedPeerSummary: String? {
        guard !selectedPeers.isEmpty else { return nil }
        let names = selectedPeers.map(\.name).sorted()
        if names.count == 1 { return names[0] }
        return "\(names[0]) + \(names.count - 1)"
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastIncomingSequence: UInt32?
    /// Pending channel invites from other peers (accept/decline in UI).
    @Published private(set) var pendingInvites: [ChannelInvite] = []

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

    // MARK: Text (Morse + Chat share this plumbing)
    /// Fires once per inbound morse message so `ChatView` can replay it
    /// as beeps / torch flashes. Transient — cleared immediately after
    /// each fire. Chat messages do NOT populate this (no replay needed).
    @Published private(set) var incomingMorse: String?
    /// Unified scrollback for the active channel. Swapped on channel switch.
    @Published private(set) var textHistory: [TextEntry] = []
    private static let textHistoryLimit = 50
    /// Per-channel chat history (keyed by channel ID).
    private var textHistoryByChannel: [String: [TextEntry]] = [:]

    /// Loss percentage clamped to a display-friendly 0…100.
    var lossPercent: Double {
        let total = Double(packetsReceived + packetsLost)
        guard total > 0 else { return 0 }
        return (Double(packetsLost) / total) * 100
    }

    // Sub-systems
    let pipeline = AudioPipeline()
    let directory = PeerDirectory()
    let channelStore = ChannelStore()
    /// LoRa radio pair + connection state.
    let radio = RadioState()
    /// Per-mesh-message delivery state. Observed by `ChatView` to render
    /// a ✓ / ⏲ / ✗ glyph next to outbound mesh rows.
    let deliveryTracker = MessageDeliveryTracker()
    /// Link used by `LoRaBridge`. Production uses the CoreBluetooth impl;
    /// tests can replace it with `FakeMeshtasticLink`.
    let meshLink: MeshtasticLink = CoreBluetoothMeshtasticLink()
    /// Codec used by `LoRaBridge`. Injected so tests can use the stub
    /// (passthrough) variant; production uses the real Meshtastic
    /// protobuf codec.
    let meshCodec: MeshtasticCodec = MeshtasticProtoCodec()
    let callManager = CallManager()
    let cameraControlPTT = CameraControlPTT()
    let liveActivity = LiveActivityManager()
    let pushManager = PushManager()
    private let crypto = CryptoService()
    private let pairing = PairingService()
    private let sounds = WalkieSoundSynth()
    private var meshRelay: MeshRelay?
    private let log = Logger(subsystem: "world.madhans.klick", category: "PTTSession")

    /// Transports spun up on start() based on `RangeModeStore.current`.
    /// Keyed by their `.kind` so outbound audio can route by peer transport
    /// without a linear scan.
    private var transports: [PeerTransport: AudioTransport] = [:]
    /// Active channel's encryption key (loaded from Keychain on channel switch).
    private var channelKey: Data?
    /// Legacy pairwise key used to encrypt channel invites.
    private var legacyKey: Data?

    init() {
        channelStore.load()
        let existingKey = try? pairing.currentKey()
        self.legacyKey = existingKey
        self.isPaired = channelStore.activeChannel != nil
        if let chId = channelStore.activeChannelId {
            self.channelKey = channelStore.key(for: chId)
        }
        self.keyFingerprint = channelKey.map(PairingService.fingerprint(of:))
        self.pipeline.loopback = false
        wireAudioToTransport()
        wireCameraControl()
        wireCallManager()
        wirePTTIntentObserver()
        wirePushToken()
    }

    private func wirePushToken() {
        NotificationCenter.default.addObserver(
            forName: .didReceiveAPNsToken,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let tokenData = notification.object as? Data else { return }
            self.pushManager.didRegisterToken(tokenData)
            // Register with relay for active channel
            if let key = self.channelKey {
                self.pushManager.registerWithRelay(channelKey: key, deviceName: DeviceName.current)
            }
        }
    }

    private func wireCameraControl() {
        cameraControlPTT.onBegin = { [weak self] in
            self?.playPressSound()
            self?.beginTransmit()
        }
        cameraControlPTT.onEnd = { [weak self] in
            self?.playReleaseSound()
            self?.endTransmit()
        }
    }

    private func wireCallManager() {
        callManager.onAnswered = { [weak self] in
            self?.log.info("Incoming call answered")
        }
        callManager.onEnded = { [weak self] in
            self?.log.info("Call ended")
        }
    }

    private func wirePTTIntentObserver() {
        // Observe toggle-PTT requests from the Live Activity widget button / Action Button.
        let defaults = UserDefaults(suiteName: "group.world.madhans.klick")
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let requested = defaults?.bool(forKey: "ptt.requested") ?? false
            if requested && !self.isTransmitting {
                self.playPressSound()
                self.beginTransmit()
            } else if !requested && self.isTransmitting {
                self.playReleaseSound()
                self.endTransmit()
            }
        }
    }

    // MARK: - Lifecycle

    /// Start the full networking stack. Call once when the user is ready —
    /// typically on the main screen after pairing.
    func start() async {
        guard !isRunning else { return }
        errorMessage = nil

        // Refresh channel + key state.
        channelStore.load()
        legacyKey = try? pairing.currentKey()
        if let chId = channelStore.activeChannelId {
            channelKey = channelStore.key(for: chId)
        }
        isPaired = channelKey != nil
        keyFingerprint = channelKey.map(PairingService.fingerprint(of:))

        // Start audio (permission prompt happens inside AudioPipeline).
        await pipeline.start()
        guard pipeline.isRunning else {
            errorMessage = pipeline.errorMessage ?? "Audio failed to start"
            return
        }

        // Spin up the transports for the user's selected range mode.
        let name = DeviceName.current
        let mode = RangeModeStore.current
        directory.selfName = name
        directory.isBrowsing = true

        var startedTransports: [PeerTransport: AudioTransport] = [:]
        do {
            if mode.includesWifi {
                let wifi = UDPTransport()
                wireTransport(wifi)
                try wifi.start(advertisingAs: name)
                startedTransports[.wifi] = wifi
            }
            if mode.includesNearby {
                let mpc = MPCTransport()
                wireTransport(mpc)
                try mpc.start(advertisingAs: name)
                startedTransports[.nearby] = mpc
            }
            if mode.includesMesh {
                let mesh = LoRaBridge(link: meshLink, codec: meshCodec)
                wireTransport(mesh)
                // Mirror link connection-state changes into RadioState so
                // the Radio screen reflects reality. We don't populate a
                // full RadioInfo yet — that comes from the FromRadio
                // config-complete stream which Phase 3b.2b hooks up.
                meshLink.onConnectedChange = { [weak self] connected in
                    Task { @MainActor in
                        guard let self else { return }
                        if connected {
                            let info = self.radio.displayInfo ?? RadioInfo(
                                deviceName: "RADIO",
                                model: "MESHTASTIC",
                                firmwareVersion: "",
                                regionPreset: "",
                                batteryPercent: nil,
                                rssi: nil
                            )
                            self.radio.didConnect(deviceId: info.deviceName, info: info)
                        } else {
                            self.radio.didDisconnect()
                        }
                    }
                }
                try mesh.start(advertisingAs: name)
                startedTransports[.mesh] = mesh
            }
        } catch {
            errorMessage = "Network start failed: \(error.localizedDescription)"
            startedTransports.values.forEach { $0.stop() }
            pipeline.stop()
            directory.isBrowsing = false
            return
        }

        self.transports = startedTransports

        // Internet transport — always start if we have a channel key.
        // Runs alongside local transports for worldwide reach.
        if let key = channelKey {
            let internet = InternetTransport(channelKey: key)
            wireTransport(internet)
            try? internet.start(advertisingAs: name)
            startedTransports[.internet] = internet
        }

        // Apply discoverability preference. When hidden, we browse but don't advertise.
        if !DiscoverabilityStore.isDiscoverable {
            for transport in startedTransports.values {
                transport.setAdvertising(false)
            }
        }

        // Initialize mesh relay for multi-hop forwarding.
        if MeshRelayStore.isEnabled {
            meshRelay = MeshRelay(selfName: name)
        }

        // Synth engine piggybacks on the already-active AVAudioSession;
        // starting it here means the first PTT press has no warm-up delay.
        sounds.start()
        isRunning = true
        log.info("PTT session running as \(name, privacy: .public) · mode=\(mode.rawValue, privacy: .public)")

        // Start Live Activity on lock screen.
        let chName = channelStore.activeChannel?.displayName ?? "CH1"
        let peerList = directory.peers.isEmpty ? "NO PEERS" : directory.peers.prefix(3).map(\.name).joined(separator: " · ").uppercased()
        liveActivity.start(channelName: chName, peerNames: peerList, onlinePeerCount: directory.peers.count)
    }

    func stop() {
        isTransmitting = false
        pipeline.stop()
        transports.values.forEach { $0.stop() }
        transports.removeAll()
        directory.clear()
        directory.isBrowsing = false
        sounds.stop()
        deliveryTracker.reset()
        isRunning = false
        liveActivity.end()
    }

    /// Ping all offline members of the current channel via push notification.
    func pingOfflineMembers() {
        guard let key = channelKey else { return }
        pushManager.pingOfflineMembers(channelKey: key, senderName: DeviceName.current)
    }

    /// Toggle advertising on all active transports.
    func setDiscoverable(_ enabled: Bool) {
        DiscoverabilityStore.isDiscoverable = enabled
        for transport in transports.values {
            transport.setAdvertising(enabled)
        }
    }

    /// Plays the "key up" click locally. Call on button press.
    func playPressSound() { sounds.playPress() }

    /// Plays the "roger beep" locally. Call on button release.
    func playReleaseSound() { sounds.playRelease() }

    // MARK: - PTT

    func beginTransmit() {
        guard isRunning, !selectedPeers.isEmpty, channelKey != nil else { return }
        // Broadcast mode: only the channel creator can transmit.
        if let channel = channelStore.activeChannel,
           channel.isBroadcast,
           channel.creatorName != DeviceName.current {
            errorMessage = "BROADCAST MODE · ONLY CREATOR CAN TRANSMIT"
            return
        }
        isTransmitting = true
        updateLiveActivity()
    }

    func endTransmit() {
        isTransmitting = false
        outboundLevel = 0
        updateLiveActivity()
    }

    private func updateLiveActivity() {
        let chName = channelStore.activeChannel?.displayName ?? "CH1"
        let peerList = directory.peers.isEmpty ? "NO PEERS" : directory.peers.prefix(3).map(\.name).joined(separator: " · ").uppercased()
        liveActivity.update(
            channelName: chName,
            isTransmitting: isTransmitting,
            onlinePeerCount: directory.peers.count,
            peerNames: peerList,
            isRunning: isRunning
        )
    }

    // MARK: - Text (Morse + Chat)

    /// Send a Morse-keyed text message. Encrypts with the shared key and
    /// routes via the selected peer's transport. No-op if not running,
    /// not paired, or no peer selected.
    func sendMorse(_ text: String) {
        sendText(text, kind: .morse, packetType: .morseText)
    }

    /// Send a keyboard-typed chat message. Same wire format as `sendMorse`
    /// but a different packet type so the receiver knows not to replay
    /// it as beeps.
    func sendChat(_ text: String) {
        sendText(text, kind: .chat, packetType: .chatText)
    }

    private func sendText(_ text: String, kind: TextEntry.Kind, packetType: PacketType) {
        guard isRunning, let key = channelKey, !selectedPeers.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let bytes = Data(trimmed.utf8)
        var firstSeq: UInt32?
        var sentCount = 0

        for peer in selectedPeers {
            guard let transport = transports[peer.transport] else { continue }

            if peer.transport == .mesh {
                if let blocker = meshSendBlocker() {
                    errorMessage = blocker
                    log.error("Mesh send blocked: \(blocker, privacy: .public)")
                    continue
                }
            }

            do {
                let (ciphertext, nonce) = try crypto.seal(bytes, key: key)
                let seq = transport.sendText(packetType, payload: ciphertext, nonce: nonce, to: peer)
                packetsSent &+= 1
                sentCount += 1
                if firstSeq == nil { firstSeq = seq }
                if peer.transport == .mesh, let seq {
                    // Track per first mesh peer for delivery indicator
                    if firstSeq == seq {
                        // Will be linked to the entry below
                    }
                }
            } catch {
                log.error("Text encrypt failed: \(String(describing: error))")
            }
        }

        if sentCount > 0 {
            let entry = TextEntry(text: trimmed, kind: kind, isIncoming: false, sequence: firstSeq)
            appendText(entry)
            if let seq = firstSeq, selectedPeers.contains(where: { $0.transport == .mesh }) {
                deliveryTracker.record(seq: seq, entryId: entry.id)
            }
        }
    }

    /// Returns a non-nil blocker string when a mesh send shouldn't proceed.
    /// Covers three cases: no radio connected, region mismatch with the
    /// paired radio, or hardware region unset.
    private func meshSendBlocker() -> String? {
        guard radio.isConnected else {
            return "No radio connected. Open Settings → Radio to pair."
        }
        let hardwarePreset = radio.displayInfo?.regionPreset
        switch RegionStore.current.compareToHardware(preset: hardwarePreset) {
        case .ok:
            return nil
        case .hardwareUnset:
            return "Radio region is unset. Flash a region in the Meshtastic app before transmitting."
        case .mismatch(let user, let hw):
            return "Region mismatch: you selected \(user.displayName) but the radio is \(hw). TX blocked."
        }
    }

    /// Push text decoded from the `ListenView` (camera or audio) into
    /// the RX scroll as an incoming Morse entry. Doesn't touch the
    /// network — it's purely a local receive from a sensor.
    func appendDecodedMorse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appendText(TextEntry(text: trimmed, kind: .morse, isIncoming: true))
    }

    private func appendText(_ entry: TextEntry) {
        textHistory.append(entry)
        if textHistory.count > Self.textHistoryLimit {
            textHistory.removeFirst(textHistory.count - Self.textHistoryLimit)
        }
    }

    /// Decrypt an inbound text packet and push it into the scrollback.
    /// `replayAsBeeps` fires the transient `incomingMorse` publisher
    /// (Chat messages are silent — no one wants their chat read as beeps).
    private func handleIncomingText(_ packet: Packet, kind: TextEntry.Kind, replayAsBeeps: Bool) {
        guard let key = resolveKey(for: packet) else {
            packetsDropped &+= 1
            return
        }
        guard let plaintext = crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce),
              let text = String(data: plaintext, encoding: .utf8) else {
            packetsDropped &+= 1
            return
        }
        packetsReceived &+= 1
        appendText(TextEntry(text: text, kind: kind, isIncoming: true))
        if replayAsBeeps {
            // Pulse once — ChatView/MorseView observes this and re-plays
            // beeps/flash. Nil afterwards so an idempotent equal-text
            // message still fires on next receipt.
            incomingMorse = text
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                self?.incomingMorse = nil
            }
        }
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

    /// Wire a single transport's receive + peer callbacks back to this
    /// session. Called for each transport brought up in `start()`.
    private func wireTransport(_ transport: AudioTransport) {
        transport.onReceive = { [weak self] packet in
            Task { @MainActor in
                self?.handleIncoming(packet)
            }
        }
        let kind = transport.kind
        transport.onPeersChanged = { [weak self] peers in
            Task { @MainActor in
                self?.directory.update(peers, from: kind)
            }
        }
    }

    private func handleOutgoingAudio(_ opusFrame: Data) {
        guard isTransmitting, let key = channelKey, !selectedPeers.isEmpty else { return }
        do {
            let (ciphertext, nonce) = try crypto.seal(opusFrame, key: key)
            for peer in selectedPeers {
                guard let transport = transports[peer.transport] else { continue }
                transport.sendAudio(opusPayload: ciphertext, nonce: nonce, to: peer)
            }
            packetsSent &+= 1
            outboundLevel = min(1.0, max(0, Double(opusFrame.count - 20) / 80.0))
        } catch {
            log.error("Encrypt failed: \(String(describing: error))")
        }
    }

    private func handleIncoming(_ packet: Packet) {
        switch packet.type {
        case .channelInvite:
            handleChannelInvite(packet)
        case .channelInviteResponse:
            handleChannelInviteResponse(packet)
        case .relay:
            handleRelay(packet)
        case .emergency:
            break // Reserved for future use
        case .broadcastInvite:
            handleBroadcastInvite(packet)
        case .audio:
            guard let key = resolveKey(for: packet) else {
                packetsDropped &+= 1
                return
            }
            guard let opusFrame = crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce) else {
                packetsDropped &+= 1
                return
            }
            if let last = lastIncomingSequence, packet.sequence > last &+ 1 {
                packetsLost &+= packet.sequence - last - 1
            }
            lastIncomingSequence = packet.sequence
            packetsReceived &+= 1
            inboundLevel = min(1.0, max(0, Double(packet.payload.count - 20) / 80.0))
            pipeline.receive(opusFrame: opusFrame)
            // Trigger CallKit ring when audio arrives and app is backgrounded.
            reportIncomingIfBackgrounded()
        case .morseText:
            handleIncomingText(packet, kind: .morse, replayAsBeeps: true)
        case .chatText:
            handleIncomingText(packet, kind: .chat, replayAsBeeps: false)
        case .ack:
            guard packet.payload.count == 4 else {
                packetsDropped &+= 1
                return
            }
            let ackedSeq: UInt32 = packet.payload.withUnsafeBytes { raw in
                UInt32(bigEndian: raw.load(as: UInt32.self))
            }
            deliveryTracker.acknowledge(seq: ackedSeq)
            packetsReceived &+= 1
        case .ping:
            break
        case .pong:
            break
        }
    }

    /// Try active channel key first, then iterate others. Returns the key
    /// that successfully decrypts, or nil if none match.
    private func resolveKey(for packet: Packet) -> Data? {
        if let key = channelKey,
           crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce) != nil {
            return key
        }
        for ch in channelStore.channels where ch.id != channelStore.activeChannelId {
            if let key = channelStore.key(for: ch.id),
               crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce) != nil {
                return key
            }
        }
        return nil
    }

    // MARK: - Mesh Relay

    private func handleRelay(_ packet: Packet) {
        guard let relay = meshRelay,
              let envelope = relay.unwrap(packet.payload) else {
            packetsDropped &+= 1
            return
        }

        // Try to decode the inner packet for ourselves.
        if let innerPacket = try? Packet.decode(envelope.innerData) {
            // Process locally (trial decryption will determine if it's for us).
            handleIncoming(innerPacket)
        }

        // Forward to other peers if relay is enabled and TTL allows.
        if relay.shouldForward(envelope),
           let forwarded = relay.rewrap(envelope) {
            // Build a relay packet and send to all connected peers.
            let relayPacket = Packet(
                type: .relay,
                sequence: 0,
                timestampMs: Packet.currentTimestampMs(),
                nonce: Packet.zeroNonce(),
                payload: forwarded
            )
            let wireData = relayPacket.encode()
            for (_, transport) in transports {
                for peer in directory.peers where peer.transport == transport.kind {
                    transport.sendText(.relay, payload: forwarded, nonce: Packet.zeroNonce(), to: peer)
                }
            }
            log.info("Relayed packet from \(envelope.origin, privacy: .public), TTL=\(envelope.ttl - 1)")
        }
        packetsReceived &+= 1
    }

    /// Wrap outgoing packets in a relay envelope when mesh relay is active.
    func wrapForRelay(_ packetData: Data) -> Data? {
        guard let relay = meshRelay else { return nil }
        return relay.wrap(innerPacketData: packetData, origin: DeviceName.current, ttl: 3)
    }

    // MARK: - CallKit Background Alert

    private func reportIncomingIfBackgrounded() {
        #if canImport(UIKit)
        guard !callManager.hasActiveCall else { return }
        // Only ring if app is not active (backgrounded or locked).
        let state = UIApplication.shared.applicationState
        if state != .active {
            let peerName = selectedPeers.first?.name ?? "PEER"
            callManager.reportIncomingCall(from: peerName)
        }
        #endif
    }

    // MARK: - Broadcast Invite (Virus-like Spread)

    /// Published list of broadcast invites received from nearby devices.
    @Published private(set) var receivedBroadcasts: [(channelName: String, passphrase: String)] = []

    /// Send a broadcast invite that spreads to all nearby devices.
    /// Anyone who receives it and enters the passphrase joins the channel.
    func sendBroadcastInvite(channelName: String, passphrase: String) {
        let payload = BroadcastInviteCodec.encode(channelName: channelName, passphrase: passphrase, ttl: 3)
        let packet = Packet(
            type: .broadcastInvite,
            sequence: 0,
            timestampMs: Packet.currentTimestampMs(),
            nonce: Packet.zeroNonce(),
            payload: payload
        )
        let wireData = packet.encode()
        // Send to ALL peers on ALL transports (broadcast to everyone nearby).
        for (_, transport) in transports {
            for peer in directory.peers where peer.transport == transport.kind {
                transport.sendText(.broadcastInvite, payload: payload, nonce: Packet.zeroNonce(), to: peer)
            }
        }
        packetsSent &+= 1
    }

    private func handleBroadcastInvite(_ packet: Packet) {
        // Broadcast invites are unencrypted — decode directly.
        guard let (ttl, channelName, passphrase) = try? BroadcastInviteCodec.decode(packet.payload) else {
            packetsDropped &+= 1
            return
        }

        // Add to received broadcasts (UI shows these as joinable invites).
        if !receivedBroadcasts.contains(where: { $0.channelName == channelName }) {
            receivedBroadcasts.append((channelName: channelName, passphrase: passphrase))
        }

        // Forward to all nearby peers if relay is enabled and TTL > 0.
        if MeshRelayStore.isEnabled, ttl > 0,
           let forwarded = BroadcastInviteCodec.forward(packet.payload) {
            for (_, transport) in transports {
                for peer in directory.peers where peer.transport == transport.kind {
                    transport.sendText(.broadcastInvite, payload: forwarded, nonce: Packet.zeroNonce(), to: peer)
                }
            }
        }
        packetsReceived &+= 1
    }

    /// Accept a received broadcast invite — join the channel using the passphrase.
    func acceptBroadcastInvite(at index: Int) {
        guard index < receivedBroadcasts.count else { return }
        let invite = receivedBroadcasts[index]
        if invite.passphrase.isEmpty {
            // Open channel (no passphrase) — generate name-based channel
            channelStore.joinByPassphrase(invite.channelName)
        } else {
            channelStore.joinByPassphrase(invite.passphrase)
        }
        receivedBroadcasts.remove(at: index)
    }

    // MARK: - Channel Invites

    private func handleChannelInvite(_ packet: Packet) {
        guard let key = legacyKey else { return }
        guard let plaintext = crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce) else {
            packetsDropped &+= 1
            return
        }
        do {
            let (channelId, channelName, channelKey) = try ChannelInviteCodec.decodeInvite(plaintext)
            let invite = ChannelInvite(
                id: UUID(),
                channelId: channelId,
                channelName: channelName,
                channelKey: channelKey,
                senderName: "PEER",
                receivedAt: .now
            )
            pendingInvites.append(invite)
            packetsReceived &+= 1
        } catch {
            packetsDropped &+= 1
        }
    }

    private func handleChannelInviteResponse(_ packet: Packet) {
        guard let key = legacyKey else { return }
        guard let plaintext = crypto.open(ciphertext: packet.payload, key: key, nonce: packet.nonce) else {
            packetsDropped &+= 1
            return
        }
        do {
            let (_, accepted) = try ChannelInviteCodec.decodeResponse(plaintext)
            packetsReceived &+= 1
            if accepted {
                log.info("Channel invite accepted by peer")
            } else {
                errorMessage = "INVITE DECLINED"
            }
        } catch {
            packetsDropped &+= 1
        }
    }

    func acceptInvite(_ invite: ChannelInvite) {
        let member = ChannelMember(name: DeviceName.current, addedAt: .now)
        channelStore.create(name: invite.channelName, key: invite.channelKey, members: [member])
        pendingInvites.removeAll { $0.id == invite.id }
        sendInviteResponse(channelId: invite.channelId, accepted: true)
    }

    func declineInvite(_ invite: ChannelInvite) {
        pendingInvites.removeAll { $0.id == invite.id }
        sendInviteResponse(channelId: invite.channelId, accepted: false)
    }

    private func sendInviteResponse(channelId: String, accepted: Bool) {
        guard let key = legacyKey, !selectedPeers.isEmpty else { return }
        guard let payload = try? ChannelInviteCodec.encodeResponse(channelId: channelId, accepted: accepted) else { return }
        guard let (ciphertext, nonce) = try? crypto.seal(payload, key: key) else { return }
        for peer in selectedPeers {
            guard let transport = transports[peer.transport] else { continue }
            transport.sendText(.channelInviteResponse, payload: ciphertext, nonce: nonce, to: peer)
        }
    }

    /// Send a channel invite to a specific peer over their transport.
    func sendChannelInvite(channel: Channel, to peer: PeerInfo) {
        guard let key = legacyKey,
              let chKey = channelStore.key(for: channel.id),
              let transport = transports[peer.transport] else { return }
        guard let payload = try? ChannelInviteCodec.encodeInvite(
            channelId: channel.id, channelName: channel.name, channelKey: chKey
        ) else { return }
        guard let (ciphertext, nonce) = try? crypto.seal(payload, key: key) else { return }
        transport.sendText(.channelInvite, payload: ciphertext, nonce: nonce, to: peer)
        packetsSent &+= 1
    }

    // MARK: - Channel Switching

    func switchChannel(to channelId: String) {
        guard channelStore.channels.contains(where: { $0.id == channelId }) else { return }

        // Save current text history
        if let currentId = channelStore.activeChannelId {
            textHistoryByChannel[currentId] = textHistory
        }

        channelStore.setActive(channelId)
        channelKey = channelStore.key(for: channelId)
        keyFingerprint = channelKey.map(PairingService.fingerprint(of:))
        isPaired = channelKey != nil

        // Restore target channel's text history
        textHistory = textHistoryByChannel[channelId] ?? []

        // Reset peer selection — user re-selects for the new channel
        selectedPeers.removeAll()
    }
}

/// One entry in the Chat/Morse scrollback. `kind` drives the prefix glyph
/// (dit/dah for Morse, none for Chat), `isIncoming` the arrow direction,
/// and `sequence` (outgoing-only) links back to `MessageDeliveryTracker`
/// so the UI can show a live ✓ / ⏲ / ✗ glyph per sent row.
struct TextEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable, Codable {
        case morse
        case chat
    }

    let id = UUID()
    let text: String
    let kind: Kind
    let isIncoming: Bool
    /// The wire `Packet.sequence` used when sending this entry. Only set
    /// for outgoing messages — incoming entries leave it `nil`.
    /// `ChatView` uses this to look up delivery state in the tracker.
    let sequence: UInt32?

    init(text: String, kind: Kind, isIncoming: Bool, sequence: UInt32? = nil) {
        self.text = text
        self.kind = kind
        self.isIncoming = isIncoming
        self.sequence = sequence
    }
}

