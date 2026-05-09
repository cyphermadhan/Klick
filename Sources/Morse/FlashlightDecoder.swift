@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import os

/// Decodes Morse code carried by a remote phone's flashlight.
///
/// Pipeline:
///
///   ┌──────────────────────────────┐
///   │ AVCaptureSession (back cam)  │
///   │ - locked exposure + focus    │     per-frame brightness sample
///   │ - 30 fps video data output   │  →  (user-selected region of the
///   └──────────────────────────────┘     Y plane — `sampleRect`)
///                    │
///                    ▼ threshold + hysteresis + debounce
///   ┌──────────────────────────────┐
///   │ on/off transition detector   │
///   └──────────────────────────────┘
///                    │
///                    ▼  signalDidGoOn/Off(at:)
///   ┌──────────────────────────────┐
///   │ MorseDemodulator             │  →  onCharacter → RX buffer
///   └──────────────────────────────┘
///
/// Exposure is locked because iOS's auto-exposure will happily turn the
/// gain down when it sees bright flashes, which defeats the whole point.
/// A single calibration frame at startup picks a dim baseline; the
/// threshold floats above that.
///
/// The `session` is exposed so the listen UI can feed it into an
/// `AVCaptureVideoPreviewLayer`; users drag a reticle on the preview
/// to point the detector at the other phone's flashlight, and that
/// rectangle is written back as `sampleRect`.
@MainActor
final class FlashlightDecoder: NSObject, ObservableObject {
    /// Live capture session. Shared with the UI so it can render a
    /// preview through `AVCaptureVideoPreviewLayer`. Do not call
    /// `startRunning` / `stopRunning` on this directly — use
    /// `FlashlightDecoder.start()` / `stop()`.
    let session = AVCaptureSession()

    /// `0.0 … 1.0`-ish normalized brightness as of the last frame, useful
    /// for a live indicator in the UI. Not a perfect unit — it's the
    /// mean Y value over `sampleRect` divided by 255.
    @Published private(set) var currentLevel: Double = 0
    /// True while the signal is currently above threshold (light is on).
    /// Drives the targeting reticle's color.
    @Published private(set) var signalIsOn: Bool = false
    /// True after `start()` succeeds, until `stop()`.
    @Published private(set) var isRunning: Bool = false
    /// Normalized rectangle (0…1 in both axes) that the sampler reads
    /// from each frame. Default is a small 20% × 20% patch centered on
    /// the frame. The listen UI updates this when the user drags the
    /// on-screen reticle.
    @Published var sampleRect: CGRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2) {
        didSet {
            rectLock.lock()
            unlockedSampleRect = sampleRect
            rectLock.unlock()
        }
    }
    /// Fired every time the demodulator commits a character. Callers
    /// (the listen view) append to their RX buffer.
    var onCharacter: ((Character) -> Void)?

    private let demod = MorseDemodulator()
    private let sampleQueue = DispatchQueue(label: "klick.flash.sample", qos: .userInteractive)
    private let log = Logger(subsystem: "world.madhans.klick", category: "FlashDecoder")

    /// Nonisolated mirror of `sampleRect` so the capture delegate (which
    /// runs on `sampleQueue`, not the main actor) can read it without
    /// hopping or risking torn reads.
    private let rectLock = NSLock()
    nonisolated(unsafe) private var unlockedSampleRect =
        CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    /// Rolling baseline brightness, re-estimated every few seconds so a
    /// scene change (room lights on/off) doesn't desync the detector.
    private var baseline: Double = 0.1
    /// Threshold above baseline to count as "signal on". Tightened from
    /// the earlier 0.15 because real-world camera noise and ambient
    /// flicker was tripping spurious ons; 0.30 needs a clear light
    /// source to register.
    private var turnOnThreshold: Double { baseline + 0.30 }
    /// Off-threshold lower to keep a 10-point hysteresis gap. Below
    /// 0.15 above baseline the signal is definitely gone.
    private var turnOffThreshold: Double { baseline + 0.15 }

    /// Debounce: require this many consecutive frames matching the
    /// target state before we actually flip. At 30 fps a 2-frame
    /// debounce is ~66 ms, below the shortest dit at 30 WPM (40 ms)
    /// but above typical one-frame noise spikes.
    private static let debounceFrames = 2
    private var pendingState: Bool = false
    private var pendingCount: Int = 0

    /// Periodic tick that flushes trailing letters from the demodulator
    /// when transitions stop arriving.
    private var tickTask: Task<Void, Never>?

    override init() {
        super.init()
        demod.onCharacter = { [weak self] char in
            self?.onCharacter?(char)
        }
    }

    func start() async {
        guard !isRunning else { return }
        // Camera authorization — the app's existing QR flow already
        // primes this, so in most cases we sail through.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { return }
        } else if status != .authorized {
            log.error("Camera not authorized (\(String(describing: status)))")
            return
        }

        do {
            try configureSession()
        } catch {
            log.error("Camera configure failed: \(String(describing: error))")
            return
        }

        demod.reset()
        pendingState = false
        pendingCount = 0
        // Session start is slow (hundreds of ms) and blocks if called on
        // the main thread — hop to a background queue.
        let session = self.session
        await withCheckedContinuation { cont in
            sampleQueue.async {
                session.startRunning()
                cont.resume()
            }
        }
        startTick()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        tickTask?.cancel()
        tickTask = nil
        let session = self.session
        sampleQueue.async {
            session.stopRunning()
        }
        isRunning = false
        signalIsOn = false
        currentLevel = 0
    }

    // MARK: - Setup

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Reset if we're reconfiguring after a stop.
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw NSError(domain: "FlashlightDecoder", code: 1)
        }

        try device.lockForConfiguration()
        if device.isExposureModeSupported(.locked) {
            // Pick a medium exposure that won't blow out a bright
            // flashlight pulse but will still show the off-state.
            device.exposureMode = .locked
        }
        if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        // YUV is cheapest for brightness — we only need the Y plane.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        // 30 fps is plenty — a dit at 12 WPM is 100 ms, which is
        // 3 frames. Plenty of resolution to spot transitions.
        session.sessionPreset = .high
    }

    private func startTick() {
        tickTask?.cancel()
        // Same pattern as AudioToneDecoder — Task with @MainActor
        // inheritance guarantees the body runs on the main executor
        // regardless of where startTick was called from.
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                guard let self else { return }
                self.demod.tick(at: Date().timeIntervalSince1970 * 1000)
            }
        }
    }

    // MARK: - Brightness → transition (called from sampleQueue)

    nonisolated fileprivate func processFrame(luma: Double, timestampMs: Double) {
        Task { @MainActor in
            self.currentLevel = luma
            self.updateBaseline(luma: luma)

            // Desired state: above on-threshold → on, below off-threshold → off,
            // otherwise hold current state (hysteresis zone).
            let desired: Bool
            if luma >= self.turnOnThreshold {
                desired = true
            } else if luma <= self.turnOffThreshold {
                desired = false
            } else {
                desired = self.signalIsOn
                return // inside hysteresis zone, no change
            }

            // Already in the desired state — nothing to do.
            guard desired != self.signalIsOn else {
                self.pendingCount = 0
                return
            }

            // Debounce: require N consecutive frames wanting the same
            // new state before we actually flip. One stray bright
            // frame shouldn't trip us.
            if desired == self.pendingState {
                self.pendingCount += 1
            } else {
                self.pendingState = desired
                self.pendingCount = 1
            }

            if self.pendingCount >= Self.debounceFrames {
                self.signalIsOn = desired
                self.pendingCount = 0
                if desired {
                    self.demod.signalDidGoOn(at: timestampMs)
                } else {
                    self.demod.signalDidGoOff(at: timestampMs)
                }
            }
        }
    }

    /// Very gentle EMA toward the dimmest observation — keeps the
    /// baseline tracking ambient light without swallowing the signal.
    private func updateBaseline(luma: Double) {
        if luma < baseline {
            baseline = 0.95 * baseline + 0.05 * luma
        } else {
            // Creep upward very slowly; off-state dominates.
            baseline = 0.99 * baseline + 0.01 * min(luma, baseline + 0.05)
        }
    }

    /// Thread-safe snapshot of the sample rect for the nonisolated
    /// capture delegate.
    nonisolated fileprivate func currentSampleRect() -> CGRect {
        rectLock.lock()
        defer { rectLock.unlock() }
        return unlockedSampleRect
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FlashlightDecoder: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sampleBuffer: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rect = currentSampleRect()
        let luma = Self.averageLuma(pixelBuffer, sampleRect: rect)
        let timestampMs = Date().timeIntervalSince1970 * 1000
        processFrame(luma: luma, timestampMs: timestampMs)
    }

    /// Pull the Y plane from a 420 YCbCr buffer and mean the brightness
    /// of the rectangle defined by `sampleRect` (normalized 0-1 coords).
    /// Sampling the whole frame would wash the signal into background —
    /// the user points their reticle at the sender's flashlight, and
    /// we sample only there.
    nonisolated static func averageLuma(_ pixelBuffer: CVPixelBuffer,
                                        sampleRect: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Normalize + clamp the sample rect into pixel coords.
        let clamped = CGRect(
            x: max(0, min(1, sampleRect.origin.x)),
            y: max(0, min(1, sampleRect.origin.y)),
            width: max(0.01, min(1, sampleRect.width)),
            height: max(0.01, min(1, sampleRect.height))
        )
        let startX = Int(clamped.origin.x * CGFloat(width))
        let startY = Int(clamped.origin.y * CGFloat(height))
        let cropW = max(1, Int(clamped.width * CGFloat(width)))
        let cropH = max(1, Int(clamped.height * CGFloat(height)))
        let endX = min(width, startX + cropW)
        let endY = min(height, startY + cropH)

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum: UInt64 = 0
        var count: UInt64 = 0
        // Step by 2 in both axes — cheap subsample, plenty of pixels
        // for a stable mean at 30 fps.
        var y = startY
        while y < endY {
            let rowStart = y * bytesPerRow
            var x = startX
            while x < endX {
                sum &+= UInt64(bytes[rowStart + x])
                count &+= 1
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return 0 }
        return Double(sum) / Double(count) / 255.0
    }
}
