import Foundation
import UIKit

/// User-facing name for this device when advertising on Bonjour and appearing
/// in another peer's list.
///
/// iOS 16+ returns a generic "iPhone" string from `UIDevice.current.name` unless
/// the app has special entitlements — so we let the user override it and
/// persist their choice. M7 will surface this in settings UI.
@MainActor
enum DeviceName {
    private static let key = "walkie.deviceName"

    static var current: String {
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        // Fall back to the system-provided name (iOS 16+ often returns "iPhone").
        return UIDevice.current.name
    }

    static func set(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: key)
    }
}
