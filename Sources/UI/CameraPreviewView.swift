@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around `AVCaptureVideoPreviewLayer` so the
/// listen screen can show the user what the camera is actually
/// looking at while the decoder samples it.
///
/// Uses `.resizeAspect` rather than `.resizeAspectFill` so the preview
/// bounds correspond 1:1 (with letterboxing) to the video frame's
/// coordinate space. That makes the reticle ↔ sample-rect mapping
/// straightforward: the normalized rect the user paints on screen is
/// the same normalized rect the decoder samples, no crop-correction
/// needed.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        // Session stays the same; nothing to update. The preview layer
        // follows frame changes automatically via layerClass.
    }
}

/// UIView whose backing `CALayer` is an `AVCaptureVideoPreviewLayer`.
/// Overriding `layerClass` is the supported way to let UIKit auto-size
/// the preview to the view's bounds.
final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}
