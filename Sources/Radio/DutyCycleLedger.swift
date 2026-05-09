import Foundation

/// EU-only rolling airtime ledger.
///
/// ETSI EN 300 220 caps most 868 MHz sub-bands at 1 % duty cycle — about
/// 36 seconds of TX per rolling hour. Exceed it and you're illegally
/// stepping on other users' traffic, even on a license-exempt band.
///
/// Klick tracks this per-device. Every time the app hands a packet to the
/// LoRa transport, it records the estimated airtime (derived from
/// Meshtastic's reported SF + bandwidth + packet length); before each TX,
/// it asks the ledger whether the pending packet would exceed the cap.
///
/// The ledger persists across app launches so a user who closes Klick
/// mid-hour doesn't get a fresh 36-second allowance by relaunching.
/// Entries older than the window simply age out.
///
/// Callers are responsible for only invoking this when `region == .eu`.
/// In other regions the ledger is a no-op waste of bytes.
final class DutyCycleLedger {
    /// One recorded TX: when it happened and how long it was on air.
    struct Entry: Codable, Equatable {
        let at: Date
        let durationMs: Int
    }

    /// Rolling window — 1 hour per ETSI.
    private static let windowSeconds: TimeInterval = 3600

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var entries: [Entry]

    init(defaults: UserDefaults = .standard,
         storageKey: String = "klick.dutyCycle.ledger") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let loaded = try? JSONDecoder().decode([Entry].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = []
        }
        pruneOld(now: Date())
    }

    /// Total airtime (in ms) used within the rolling 1-hour window
    /// ending at `now`.
    func usedMs(now: Date = Date()) -> Int {
        pruneOld(now: now)
        return entries.reduce(0) { $0 + $1.durationMs }
    }

    /// Budget (ms) available in the rolling window. For EU 1 %:
    /// 3600 s × 1 % = 36 000 ms. Callers pass the duty-cycle fraction from
    /// their `Region` so this function stays region-agnostic.
    func remainingMs(dutyCycle: Double, now: Date = Date()) -> Int {
        let budget = Int(Self.windowSeconds * 1000 * dutyCycle)
        return max(0, budget - usedMs(now: now))
    }

    /// Fraction of the budget consumed, `0.0 … 1.0+` (can exceed 1 if
    /// something logged past the limit — the UI clamps for display).
    func fractionUsed(dutyCycle: Double, now: Date = Date()) -> Double {
        let budget = Self.windowSeconds * 1000 * dutyCycle
        guard budget > 0 else { return 0 }
        return Double(usedMs(now: now)) / budget
    }

    /// Would a pending TX of `durationMs` fit inside the remaining
    /// budget? Inclusive on equality: a packet exactly at the limit
    /// passes, since regulators round to whole milliseconds.
    func canTransmit(durationMs: Int, dutyCycle: Double, now: Date = Date()) -> Bool {
        remainingMs(dutyCycle: dutyCycle, now: now) >= durationMs
    }

    /// Append a TX. Callers invoke this synchronously right after the
    /// transport confirms the packet has been handed to the radio (not
    /// before — we don't want to bill the user for a send that failed).
    func record(durationMs: Int, at date: Date = Date()) {
        entries.append(Entry(at: date, durationMs: durationMs))
        pruneOld(now: date)
        persist()
    }

    /// Clear the ledger. For tests and a future "Reset" affordance.
    func reset() {
        entries.removeAll()
        defaults.removeObject(forKey: storageKey)
    }

    // MARK: - Private

    /// Drop entries that have aged out of the rolling window.
    private func pruneOld(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.windowSeconds)
        let before = entries.count
        entries.removeAll { $0.at < cutoff }
        if entries.count != before {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
