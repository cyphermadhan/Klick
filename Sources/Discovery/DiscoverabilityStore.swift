import Foundation

/// Persists whether this device advertises itself to nearby peers.
/// When OFF, the device can still browse (see others) but won't appear
/// on other devices' peer scans.
@MainActor
enum DiscoverabilityStore {
    private static let key = "klick.discoverable"

    static var isDiscoverable: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
