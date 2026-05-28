import AVFoundation
import UIKit

/// Captures iPhone 16 Camera Control button press/release as PTT trigger.
/// Gracefully no-ops on devices without the button or iOS < 17.2.
///
/// AVCaptureEventInteraction is only available on physical devices with the
/// Camera Control hardware button. On simulators and older devices this
/// class is a harmless no-op.
@MainActor
final class CameraControlPTT {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    private var interaction: AnyObject?

    /// Whether the hardware Camera Control button is available on this device.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 17.2, *) {
            return AVCaptureEventInteraction.isEnabled
        }
        return false
        #endif
    }

    /// Attach the capture event interaction to a UIView. Call once after the
    /// view is added to the window hierarchy.
    func attach(to view: UIView) {
        #if !targetEnvironment(simulator)
        guard #available(iOS 17.2, *) else { return }

        let eventInteraction = AVCaptureEventInteraction { [weak self] event in
            Task { @MainActor in
                if event.phase == .began {
                    self?.onBegin?()
                }
                if event.phase == .ended || event.phase == .cancelled {
                    self?.onEnd?()
                }
            }
        } secondary: { _ in
            // Secondary (half-press) — unused for PTT.
        }

        view.addInteraction(eventInteraction)
        interaction = eventInteraction
        #endif
    }

    func detach(from view: UIView) {
        #if !targetEnvironment(simulator)
        guard #available(iOS 17.2, *),
              let interaction = interaction as? AVCaptureEventInteraction else { return }
        view.removeInteraction(interaction)
        self.interaction = nil
        #endif
    }
}
