import Foundation

/// State machine for an outgoing text message as it moves from "handed
/// to the transport" to "confirmed delivered" (or timed out).
///
/// Non-mesh transports skip the whole ordeal — they use `.sent`, which
/// is a terminal no-ack state suitable for UDP / MPC where delivery is
/// already observable by the peer typing back. The mesh-specific values
/// drive small glyphs in `ChatView` (`…` sending, `✓` delivered,
/// `✗` failed, `⏲` timed out).
enum DeliveryState: Equatable, Sendable {
    /// Local send path completed synchronously; no ack expected. Used by
    /// UDP + MPC where the transport has no delivery-confirmation
    /// semantic of its own.
    case sent
    /// Handed to the mesh transport; awaiting `.ack` from the peer.
    case sending
    /// `.ack` received within the timeout window.
    case delivered
    /// Transport reported a synchronous write failure.
    case failed
    /// No `.ack` within the configured window. The message may still
    /// have arrived — the transport just can't confirm.
    case timedOut
}

/// Tracks outbound mesh messages through their delivery lifecycle.
///
/// Owns a `[UInt32: Entry]` map keyed by the `Packet.sequence` used on
/// the wire. `PTTSession` calls `record(seq:entryId:)` right after a
/// mesh `sendText`, `acknowledge(seq:)` when an `.ack` packet arrives,
/// and reads `state(seq:)` when rendering rows.
///
/// Each entry gets a cancellable timeout task that flips the state to
/// `.timedOut` if no ack has shown up. Entries are removed from the map
/// on acknowledge / timeout so the table doesn't grow unbounded over a
/// session.
///
/// The `@Published stateVersion` counter increments on every change so
/// SwiftUI views can re-render without caring about the exact seq that
/// moved. Coarser than a per-entry publisher but cheap and adequate for
/// the handful of in-flight messages a user is likely to have open.
@MainActor
final class MessageDeliveryTracker: ObservableObject {
    struct Entry {
        let entryId: UUID
        var state: DeliveryState
    }

    @Published private(set) var stateVersion: Int = 0
    private var entries: [UInt32: Entry] = [:]
    private var timeoutTasks: [UInt32: Task<Void, Never>] = [:]

    /// Default wait for a mesh ack before giving up. LoRa packets take
    /// 1–2 seconds of airtime at SF10; 15 s accommodates one or two
    /// mesh hops plus the return trip.
    nonisolated static let defaultTimeout: Duration = .seconds(15)

    /// Register an outbound mesh message. Starts the timeout timer.
    /// `entryId` is the owning `TextEntry.id` so the UI can cross-reference.
    func record(seq: UInt32, entryId: UUID, timeout: Duration = defaultTimeout) {
        entries[seq] = Entry(entryId: entryId, state: .sending)
        timeoutTasks[seq]?.cancel()
        timeoutTasks[seq] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.timeout(seq: seq)
        }
        bumpVersion()
    }

    /// Move `seq` to `.delivered`. No-op if we don't know about it (ack
    /// arrived after timeout, or for a message that was sent before the
    /// app restarted — we don't persist in-flight state).
    func acknowledge(seq: UInt32) {
        guard var entry = entries[seq] else { return }
        entry.state = .delivered
        entries[seq] = entry
        timeoutTasks[seq]?.cancel()
        timeoutTasks.removeValue(forKey: seq)
        bumpVersion()
    }

    /// Synchronous send failure path. Marks `.failed` and cancels the
    /// timeout.
    func markFailed(seq: UInt32) {
        guard var entry = entries[seq] else { return }
        entry.state = .failed
        entries[seq] = entry
        timeoutTasks[seq]?.cancel()
        timeoutTasks.removeValue(forKey: seq)
        bumpVersion()
    }

    /// Current state for a given seq, or `nil` if untracked.
    func state(seq: UInt32) -> DeliveryState? {
        entries[seq]?.state
    }

    /// Current state for a given `TextEntry.id`. Slightly more expensive
    /// than the seq lookup (linear scan), but the UI binds to entry ids
    /// so this is what `ChatView` actually calls.
    func state(entryId: UUID) -> DeliveryState? {
        entries.values.first(where: { $0.entryId == entryId })?.state
    }

    /// Clear all tracking. Called when the session stops or the user
    /// unpairs. Cancels every pending timeout task.
    func reset() {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        entries.removeAll()
        bumpVersion()
    }

    // MARK: - Private

    private func timeout(seq: UInt32) {
        guard var entry = entries[seq], entry.state == .sending else { return }
        entry.state = .timedOut
        entries[seq] = entry
        timeoutTasks.removeValue(forKey: seq)
        bumpVersion()
    }

    private func bumpVersion() {
        // Wrap on overflow — value is only used to signal change, never
        // compared for magnitude.
        stateVersion &+= 1
    }
}
