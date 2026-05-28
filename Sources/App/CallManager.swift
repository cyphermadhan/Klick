import CallKit
import AVFoundation
import os

/// Manages incoming call presentation via CallKit so that voice
/// transmissions from peers can ring the device and bypass lock screen.
@MainActor
final class CallManager: NSObject, ObservableObject {
    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallUUID: UUID?
    private let log = Logger(subsystem: "world.madhans.klick", category: "CallManager")

    /// Called when the user answers the incoming call from the lock/notification screen.
    var onAnswered: (() -> Void)?
    /// Called when the call is ended (user hung up or we ended it).
    var onEnded: (() -> Void)?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.ringtoneSound = nil
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Report an incoming "call" from a peer. This rings the device
    /// and shows the call UI on the lock screen.
    func reportIncomingCall(from peerName: String) {
        guard activeCallUUID == nil else { return }
        let uuid = UUID()
        activeCallUUID = uuid

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: peerName)
        update.localizedCallerName = "\(peerName) · KLICK PTT"
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                self?.log.error("Failed to report incoming call: \(error.localizedDescription)")
                Task { @MainActor in self?.activeCallUUID = nil }
            }
        }
    }

    /// End the active call (e.g. when transmission stops).
    func endCall() {
        guard let uuid = activeCallUUID else { return }
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                self?.log.error("Failed to end call: \(error.localizedDescription)")
            }
            Task { @MainActor in self?.activeCallUUID = nil }
        }
    }

    var hasActiveCall: Bool { activeCallUUID != nil }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            activeCallUUID = nil
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // User answered the call — foreground the app and start listening.
        Task { @MainActor in
            onAnswered?()
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            activeCallUUID = nil
            onEnded?()
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit activated the audio session — our AudioPipeline should already be running.
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Audio session deactivated after call ends.
    }
}
