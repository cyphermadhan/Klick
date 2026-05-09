import Foundation

/// Regulatory region for the LoRa radio.
///
/// LoRa hardware and spectrum use are licensed per geography. A US 915 MHz
/// board cannot legally operate in India (865 MHz protected band); an India
/// 865 MHz board cannot legally operate on the US ISM band. Beyond the
/// frequency split, duty-cycle rules vary: the EU enforces a 1 % airtime
/// cap on most sub-bands; the US and India have no such cap.
///
/// Klick uses this enum for three things:
///   1. Default the user's region from `Locale.current.region` at first run.
///   2. Show the right band / max-power / duty-cycle copy in `RadioView`.
///   3. Compare the user's selected region against the region reported by
///      the paired Meshtastic firmware and block TX on mismatch (Phase 3b).
///
/// Cases are the ISO-style codes; `in_` has a trailing underscore because
/// `in` is a Swift keyword.
enum Region: String, CaseIterable, Sendable, Codable {
    case us
    case eu
    case in_
    case au
    case other

    /// Human-readable short label shown in the Settings picker and RadioView.
    var displayName: String {
        switch self {
        case .us:    return "US (915 MHz)"
        case .eu:    return "EU (868 MHz)"
        case .in_:   return "IN (865 MHz)"
        case .au:    return "AU (915 MHz)"
        case .other: return "OTHER"
        }
    }

    /// Meshtastic firmware region preset name. Used to validate the paired
    /// radio's region matches the user's selection.
    var meshtasticPreset: String {
        switch self {
        case .us:    return "US"
        case .eu:    return "EU_868"
        case .in_:   return "IN_865"
        case .au:    return "ANZ"
        case .other: return "UNSET"
        }
    }

    /// Max ERP allowed per regional regulator, in dBm.
    var maxPowerDbm: Int {
        switch self {
        case .us:    return 30   // FCC Part 15, 915 MHz ISM, 1 W
        case .eu:    return 14   // ETSI EN 300 220, 25 mW
        case .in_:   return 30   // WPC SRD, 865 MHz, 1 W ERP
        case .au:    return 30
        case .other: return 14   // conservative default
        }
    }

    /// Fractional duty-cycle cap, or `nil` if the region has none.
    /// Only EU imposes a hard cap (1 %). Everywhere else, transmit freely.
    var dutyCycle: Double? {
        switch self {
        case .eu:    return 0.01
        default:     return nil
        }
    }

    /// Map an ISO 3166 alpha-2 region code (as returned by `Locale`) to a
    /// Region. Falls back to `.other` for anything unmapped so the user
    /// can still pick manually without a crash.
    static func fromLocaleCode(_ code: String?) -> Region {
        guard let code else { return .other }
        switch code.uppercased() {
        case "US", "CA", "MX":
            return .us
        case "IN":
            return .in_
        case "AU", "NZ":
            return .au
        case "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR",
             "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL",
             "PL", "PT", "RO", "SK", "SI", "ES", "SE", "GB", "CH", "NO",
             "IS":
            return .eu
        default:
            return .other
        }
    }

    /// Region derived from the device's current locale. Stable call — the
    /// user's explicit selection in Settings takes precedence if present
    /// (see `RegionStore`).
    static var localeDefault: Region {
        if #available(iOS 16.0, *) {
            return fromLocaleCode(Locale.current.region?.identifier)
        } else {
            return fromLocaleCode(Locale.current.regionCode)
        }
    }
}

/// Result of comparing the user's selected `Region` against the region
/// preset reported by a paired Meshtastic radio's firmware.
///
/// A mismatch is a regulatory problem: US 915 MHz hardware used in India
/// is transmitting on a protected band; India 865 MHz hardware used in
/// the EU exceeds the 868 MHz sub-band boundary. In both cases, Klick's
/// `RadioView` shows a non-dismissable warning and blocks TX until the
/// user either reconfigures the radio or explicitly changes their region.
enum RegionMismatch: Equatable {
    /// User preference matches the hardware, good to transmit.
    case ok
    /// Hardware is unconfigured (`UNSET` / empty). User must flash a
    /// region on the radio before TX.
    case hardwareUnset
    /// Mismatch — pass both values so the UI can show "you selected X
    /// but the radio is Y".
    case mismatch(user: Region, hardwarePreset: String)
}

extension Region {
    /// Compare this (user-selected) region against the raw preset string
    /// reported by Meshtastic firmware. `"UNSET"` or empty → unset;
    /// otherwise matches when the presets are equal.
    func compareToHardware(preset: String?) -> RegionMismatch {
        let normalized = (preset ?? "").uppercased()
        if normalized.isEmpty || normalized == "UNSET" {
            return .hardwareUnset
        }
        if normalized == meshtasticPreset {
            return .ok
        }
        return .mismatch(user: self, hardwarePreset: normalized)
    }
}

/// Persistent store for the user's region preference.
///
/// Mirrors `RangeModeStore` in shape: a static `current` getter that
/// reads `UserDefaults`, falls back to the locale default on first run,
/// and a setter that writes-through. `isUserOverridden` tells the UI
/// whether to show an `[auto]` tag on the Settings row.
enum RegionStore {
    private static let key = "klick.region"
    private static let overrideKey = "klick.regionUserOverridden"

    /// Currently selected region — user override if set, else locale default.
    static var current: Region {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let region = Region(rawValue: raw) else {
                return Region.localeDefault
            }
            return region
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            UserDefaults.standard.set(true, forKey: overrideKey)
        }
    }

    /// True once the user has explicitly chosen a region. Used by the UI
    /// to show a small `[auto]` suffix when the value is still the
    /// locale-derived default.
    static var isUserOverridden: Bool {
        UserDefaults.standard.bool(forKey: overrideKey)
    }

    /// Clear the override — region goes back to the locale default.
    /// Mainly for tests and a future "Reset" button.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: overrideKey)
    }
}
