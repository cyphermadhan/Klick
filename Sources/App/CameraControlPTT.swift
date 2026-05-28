import Foundation

/// Camera Control button PTT trigger.
///
/// AVCaptureEventInteraction (iOS 17.2–25) was removed from the iOS 26 SDK.
/// This class is a stub until Apple provides a replacement API.
/// The Camera Control hardware button will be re-enabled when the SDK
/// surface stabilizes.
@MainActor
final class CameraControlPTT {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    static var isAvailable: Bool { false }

    func attach(to view: Any) {}
    func detach(from view: Any) {}
}
