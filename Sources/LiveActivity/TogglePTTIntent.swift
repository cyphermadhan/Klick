import AppIntents
import Foundation

/// App Intent that toggles PTT state. Used by:
/// - Live Activity lock screen button
/// - Action Button (via Shortcuts)
/// - Siri ("Toggle Klick PTT")
struct TogglePTTIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Klick PTT"
    static let description: IntentDescription = "Start or stop push-to-talk transmission."
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Toggle PTT state via app group UserDefaults.
        // PTTSession observes changes to this key and toggles transmit.
        let defaults = UserDefaults(suiteName: "group.world.madhans.klick")
        let current = defaults?.bool(forKey: "ptt.requested") ?? false
        defaults?.set(!current, forKey: "ptt.requested")

        return .result()
    }
}

/// Shortcuts provider so the intent appears in Shortcuts app / Action Button config.
struct KlickShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TogglePTTIntent(),
            phrases: [
                "Toggle \(.applicationName) PTT",
                "Talk on \(.applicationName)",
                "Start transmitting on \(.applicationName)"
            ],
            shortTitle: "Toggle PTT",
            systemImageName: "mic.fill"
        )
    }
}
