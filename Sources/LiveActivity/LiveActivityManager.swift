import ActivityKit
import Foundation

/// Manages the Klick Live Activity lifecycle — start, update, end.
/// Called by PTTSession whenever state changes that should be reflected
/// on the lock screen / Dynamic Island.
@MainActor
final class LiveActivityManager {
    private var currentActivity: Any?  // Activity<KlickActivityAttributes> stored type-erased for iOS 16.0 compat

    var isActive: Bool { currentActivity != nil }

    /// Start a Live Activity when the session goes live.
    func start(channelName: String, peerNames: String, onlinePeerCount: Int) {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard currentActivity == nil else { return }

        let state = KlickActivityAttributes.ContentState(
            channelName: channelName,
            isTransmitting: false,
            onlinePeerCount: onlinePeerCount,
            peerNames: peerNames,
            isRunning: true
        )

        let content = ActivityContent(state: state, staleDate: nil)

        do {
            let activity = try Activity.request(
                attributes: KlickActivityAttributes(),
                content: content,
                pushType: nil
            )
            currentActivity = activity
        } catch {
            // Live Activities not available — silently degrade.
        }
    }

    /// Update the Live Activity with new state.
    func update(
        channelName: String,
        isTransmitting: Bool,
        onlinePeerCount: Int,
        peerNames: String,
        isRunning: Bool
    ) {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = currentActivity as? Activity<KlickActivityAttributes> else { return }

        let state = KlickActivityAttributes.ContentState(
            channelName: channelName,
            isTransmitting: isTransmitting,
            onlinePeerCount: onlinePeerCount,
            peerNames: peerNames,
            isRunning: isRunning
        )

        let content = ActivityContent(state: state, staleDate: nil)
        Task {
            await activity.update(content)
        }
    }

    /// End the Live Activity when the session stops.
    func end() {
        guard #available(iOS 16.2, *) else { return }
        guard let activity = currentActivity as? Activity<KlickActivityAttributes> else { return }

        let finalState = KlickActivityAttributes.ContentState(
            channelName: "---",
            isTransmitting: false,
            onlinePeerCount: 0,
            peerNames: "SESSION ENDED",
            isRunning: false
        )

        let content = ActivityContent(state: finalState, staleDate: nil)
        Task {
            await activity.end(content, dismissalPolicy: .after(.now + 5))
        }
        currentActivity = nil
    }
}
