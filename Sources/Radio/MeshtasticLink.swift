import Foundation

/// Byte-level transport to a paired Meshtastic radio.
///
/// Phase 3b.1 ships this abstraction + a `FakeMeshtasticLink` that never
/// connects, so the rest of the LoRa stack (`LoRaBridge`, region/duty
/// guards, ack tracking) can be built, wired, and tested today. Phase
/// 3b.2b will add the real `CoreBluetoothMeshtasticLink` backed by
/// `CBCentralManager` talking to Meshtastic's GATT service.
///
/// The protocol intentionally knows nothing about Meshtastic's protobuf
/// envelope — that's the `MeshtasticCodec`'s job. This layer just ships
/// bytes in both directions.
///
/// Implementations are responsible for their own thread safety; calls
/// may come from any queue. Callbacks (`onFrame`, `onConnectedChange`)
/// fire on the implementation's internal queue — the Core Bluetooth
/// impl will hop to a known queue before invoking them.
protocol MeshtasticLink: AnyObject, Sendable {
    /// True while the link is connected and ready to carry traffic.
    /// Observed by `LoRaBridge` to gate outbound writes.
    var isConnected: Bool { get }

    /// Start (or resume) the BLE connection to the remembered radio.
    /// No-op if already connected.
    func start()

    /// Tear the link down. Safe to call repeatedly.
    func stop()

    /// Write one complete protobuf frame to the ToRadio characteristic.
    /// Returns `false` and logs if not connected — callers should treat
    /// this as a silent drop (duty-cycle and retry logic live above).
    @discardableResult
    func write(_ frame: Data) -> Bool

    /// Fired for each complete protobuf frame read from FromRadio.
    /// Mutable on purpose: the owner (`LoRaBridge`) sets this during
    /// `start()` and clears it on `stop()`.
    var onFrame: (@Sendable (Data) -> Void)? { get set }

    /// Fired on any connected-state change so the UI (via `RadioState`)
    /// can reflect it. Carries the new `isConnected` value.
    var onConnectedChange: (@Sendable (Bool) -> Void)? { get set }
}

/// Placeholder link for Phase 3b.1: reports disconnected forever, swallows
/// every write. Lets the rest of the stack wire up, and is the default
/// `MeshtasticLink` in production until the real CoreBluetooth impl
/// lands.
///
/// In tests, use the `.fixture` factory to drive inbound frames from
/// outside — simulates the radio echoing a payload back.
final class FakeMeshtasticLink: MeshtasticLink, @unchecked Sendable {
    private(set) var isConnected: Bool
    var onFrame: (@Sendable (Data) -> Void)?
    var onConnectedChange: (@Sendable (Bool) -> Void)?

    /// Frames passed to `write` are captured here so tests can assert on
    /// what would have gone out over BLE.
    private(set) var writtenFrames: [Data] = []

    init(startsConnected: Bool = false) {
        self.isConnected = startsConnected
    }

    func start() { /* no-op */ }

    func stop() {
        if isConnected {
            isConnected = false
            onConnectedChange?(false)
        }
    }

    @discardableResult
    func write(_ frame: Data) -> Bool {
        guard isConnected else { return false }
        writtenFrames.append(frame)
        return true
    }

    // MARK: - Test helpers

    /// Flip the connected bit and fire the callback. Used by tests or by
    /// a future manual-pair UI when BLE isn't available.
    func simulateConnectedChange(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
        onConnectedChange?(connected)
    }

    /// Deliver a frame as if the radio had just pushed it up the notify
    /// characteristic. Ignored if nobody has subscribed yet.
    func simulateInbound(_ frame: Data) {
        onFrame?(frame)
    }
}
