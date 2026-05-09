import Foundation
import SwiftUI

/// Metadata about a paired LoRa radio — everything we learn once a
/// Meshtastic device is connected over BLE. This is what the `RadioView`
/// shows in its status panel.
///
/// `region` is stored as the raw Meshtastic preset string (e.g. `"US"`,
/// `"EU_868"`, `"IN_865"`) rather than a Klick `Region`, because the
/// firmware is the source of truth for what the hardware was flashed for,
/// and Klick's `Region.fromMeshtasticPreset(_:)` is used to interpret it
/// when rendering. Keeping the raw string makes region-mismatch detection
/// (user preference vs hardware reality) possible.
struct RadioInfo: Codable, Equatable, Sendable {
    /// Human-readable name (Meshtastic's `long_name`).
    var deviceName: String
    /// Hardware model string reported by firmware (e.g. `HELTEC_V3`).
    var model: String
    /// Firmware version string (e.g. `2.3.14`).
    var firmwareVersion: String
    /// Region preset from Meshtastic (`US`, `EU_868`, `IN_865`, …). Used
    /// for region-mismatch detection against the user's `Region` setting.
    /// Empty string or `"UNSET"` means the radio has no region flashed.
    var regionPreset: String
    /// 0–100. `nil` means the radio hasn't reported battery yet.
    var batteryPercent: Int?
    /// Signal strength in dBm as last seen on BLE. Negative values;
    /// typical range −40 (close) to −100 (barely connected).
    var rssi: Int?
}

/// Observable connection + pairing state of the LoRa radio. One instance
/// lives on `PTTSession` (Phase 3b.2); the UI (`RadioView`) observes it.
///
/// Three states, mutually exclusive:
///   - `.disconnected` — no radio paired, or the paired radio isn't
///      currently reachable. `rememberedDeviceId` is populated if the user
///      has previously paired one — the BLE layer will try to reconnect.
///   - `.pairing` — mid-flight BLE pair + service-discovery + initial
///      config read. Transient; resolves to `.connected` or `.disconnected`.
///   - `.connected` — fully ready; `info` has everything the UI needs.
///
/// Persists `rememberedDeviceId` and the last-known `RadioInfo` across app
/// launches so the UI can show "last seen on HELTEC_V3, trying to
/// reconnect…" before the BLE layer actually re-establishes.
@MainActor
final class RadioState: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case pairing
        case connected(RadioInfo)
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var rememberedDeviceId: String?
    @Published private(set) var rememberedInfo: RadioInfo?

    private let defaults: UserDefaults
    private static let deviceIdKey = "klick.radio.deviceId"
    private static let infoKey = "klick.radio.info"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rememberedDeviceId = defaults.string(forKey: Self.deviceIdKey)
        if let data = defaults.data(forKey: Self.infoKey),
           let info = try? JSONDecoder().decode(RadioInfo.self, from: data) {
            self.rememberedInfo = info
        }
    }

    // MARK: - Transitions

    /// Called by the BLE layer when it starts a new pair or reconnect.
    func beginPairing() {
        phase = .pairing
    }

    /// Called when pairing completes successfully. Stashes the device id
    /// and info so we can show remembered state before the next connect.
    func didConnect(deviceId: String, info: RadioInfo) {
        rememberedDeviceId = deviceId
        rememberedInfo = info
        defaults.set(deviceId, forKey: Self.deviceIdKey)
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: Self.infoKey)
        }
        phase = .connected(info)
    }

    /// Update the live info on a connected radio (battery drops, RSSI
    /// wobble, firmware sends new config). No-op if not currently connected.
    func updateInfo(_ info: RadioInfo) {
        guard case .connected = phase else { return }
        rememberedInfo = info
        if let data = try? JSONEncoder().encode(info) {
            defaults.set(data, forKey: Self.infoKey)
        }
        phase = .connected(info)
    }

    /// BLE dropped; remembered values stay so the UI can show a "last
    /// seen" status. Call `forget()` to clear that too.
    func didDisconnect() {
        phase = .disconnected
    }

    /// User asked to un-pair the radio. Clears remembered values and
    /// removes the disk-persisted state.
    func forget() {
        rememberedDeviceId = nil
        rememberedInfo = nil
        defaults.removeObject(forKey: Self.deviceIdKey)
        defaults.removeObject(forKey: Self.infoKey)
        phase = .disconnected
    }

    // MARK: - Convenience

    /// The currently-connected radio's info, or the last-known info if
    /// disconnected. `RadioView` uses this to render a muted "remembered"
    /// card when the radio is offline.
    var displayInfo: RadioInfo? {
        if case .connected(let info) = phase { return info }
        return rememberedInfo
    }

    /// True while BLE is actively working on the pair.
    var isPairing: Bool {
        if case .pairing = phase { return true }
        return false
    }

    /// True when the radio is live and ready to carry traffic.
    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }
}
