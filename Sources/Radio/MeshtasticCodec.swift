import Foundation

/// Translates between Klick's `Packet` bytes and a protobuf-framed
/// Meshtastic payload suitable for the `ToRadio` / `FromRadio` BLE
/// characteristics.
///
/// The real codec (Phase 3b.2b) will wrap our `Packet.encode()` output
/// inside a Meshtastic `ToRadio { packet: MeshPacket { decoded: Data
/// { portnum: TEXT_MESSAGE_APP, payload: ... } } }` protobuf message
/// and unwrap on the way back. It's a thin layer — we use Meshtastic as
/// a byte pipe, keeping our own crypto + sequence numbers on top.
///
/// Phase 3b.1 ships this protocol + a passthrough stub so the rest of
/// the stack (LoRaBridge, PTTSession ack routing, duty-cycle) can be
/// built + tested today without guessing Meshtastic field numbers. The
/// stub is deliberately NOT wire-compatible with real Meshtastic
/// firmware — it logs a warning on every use.
protocol MeshtasticCodec: AnyObject, Sendable {
    /// Error produced when a decode step can't make sense of the bytes.
    /// Callers should drop such frames silently; the radio may be speaking
    /// a newer firmware version or this may just be noise.
    var codecError: Error.Type { get }

    /// Wrap a Klick `Packet.encode()` blob inside a Meshtastic `ToRadio`
    /// protobuf frame ready to write to the ToRadio characteristic.
    func encodeToRadio(_ klickFrame: Data) -> Data

    /// Unwrap a `FromRadio` frame read off the notify characteristic.
    /// Returns the inner Klick `Packet.encode()` bytes, or `nil` if the
    /// message isn't one we care about (position updates, routing, etc.).
    func decodeFromRadio(_ protobufFrame: Data) -> Data?
}

/// Phase 3b.1 placeholder. Pretends the Meshtastic envelope is absent.
/// **Not wire-compatible with real Meshtastic firmware** — the real
/// codec lands in Phase 3b.2b once we can pull in the `.proto` files
/// and verify against a physical radio. Using this stub with the real
/// radio will produce malformed `ToRadio` messages the firmware rejects.
///
/// The warning log on every call is intentional: if you see it in a
/// shipping build, something is very wrong.
final class StubMeshtasticCodec: MeshtasticCodec, @unchecked Sendable {
    enum StubError: Error, Equatable { case notImplemented }

    nonisolated let codecError: Error.Type = StubError.self

    private var warnedOnce = false

    func encodeToRadio(_ klickFrame: Data) -> Data {
        warnIfNeeded()
        return klickFrame
    }

    func decodeFromRadio(_ protobufFrame: Data) -> Data? {
        warnIfNeeded()
        return protobufFrame
    }

    private func warnIfNeeded() {
        // Once per instance is enough — real Meshtastic integration is a
        // code change, not a config.
        guard !warnedOnce else { return }
        warnedOnce = true
        NSLog("[klick] StubMeshtasticCodec in use — this build cannot interoperate with real Meshtastic firmware. Phase 3b.2b replaces this.")
    }
}
