import Foundation

/// User-selectable toggle for which transports Klick should bring up when
/// the session starts.
///
/// Default is `.both`: upgrading users from 1.0 should get the "works at a
/// concert" behavior without having to discover and flip a setting. The
/// plan-v2 draft originally suggested `.wifi` as the default for battery
/// conservatism, but PTT is foreground-only — MPC's cost during active use
/// is small enough that opting everyone in is the better tradeoff. Revisit
/// after field data from TestFlight 0.2.0.
enum RangeMode: String, CaseIterable, Sendable {
    /// Infrastructure WiFi only (Klick 1.0 behavior). Bonjour + UDP.
    case wifi
    /// MultipeerConnectivity only. Bluetooth + peer-to-peer WiFi.
    case nearby
    /// Advertise + browse on both paths simultaneously.
    case both

    /// Short terminal-style label for the Settings picker.
    var displayName: String {
        switch self {
        case .wifi:   return "WIFI"
        case .nearby: return "NEARBY"
        case .both:   return "BOTH"
        }
    }

    /// One-line explainer beneath each row in the Settings picker.
    var subtitle: String {
        switch self {
        case .wifi:   return "INFRA NETWORK · STANDARD RANGE"
        case .nearby: return "BLUETOOTH + P2P WIFI · NO ROUTER"
        case .both:   return "ADVERTISE ON BOTH · RECOMMENDED"
        }
    }

    var includesWifi: Bool { self == .wifi || self == .both }
    var includesNearby: Bool { self == .nearby || self == .both }
}

/// UserDefaults-backed accessor for the user's range-mode preference.
/// Mirrors the `DeviceName` pattern — simple, mainactor-bound, no injection.
@MainActor
enum RangeModeStore {
    private static let key = "klick.rangeMode"

    static var current: RangeMode {
        if let raw = UserDefaults.standard.string(forKey: key),
           let mode = RangeMode(rawValue: raw) {
            return mode
        }
        return .both
    }

    static func set(_ mode: RangeMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}
