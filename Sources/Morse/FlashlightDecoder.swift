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
///   │ - 30 fps video data output   │  →  (center 20% of the Y plane)
///   └──────────────────────────────┘
///                    │
///                    ▼ threshold + hysteresis
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
@MainActor
final class FlashlightDecoder: NSObject, ObservableObject {
    /// `0.0 … 1.0`-ish normalized brightness as of the last frame, useful
    /// for a live indicator bar in the UI. Not a perfect unit — it's the
    /// mean Y value divided by 255.
    @Published private(set) var currentLevel: Double = 0
    /// True while the signal is currently above threshold (light is on).
    /// Drives the targeting reticle's color.
    @Published private(set) var signalIsOn: Bool = false
    /// True after `start()` succeeds, until `stop()`.
    @Published private(set) var isRunning: Bool = false
    /// Fired every time the demodulator commits a character. Callers
    /// (the listen view) append to their RX buffer.
    var onCharacter: ((Character) -> Void)?

    private let session = AVCaptureSession()
    private let demod = MorseDemodulator()
    private let sampleQueue = DispatchQueue(label: "klick.flash.sample", qos: .userInteractive)
    private let log = Logger(subsystem: "world.madhans.klick", category: "FlashDecoder")

    /// Rolling baseline brightness, re-estimated every few seconds so a
    /// scene change (room lights on/off) doesn't desync the detector.
    private var baseline: Double = 0.1
    /// Threshold above baseline that counts as "signal on". Hysteresis
    /// keeps a slight gap between turn-on and turn-off thresholds so
    /// small flickers around the edge don't produce false transitions.
    private var turnOnThreshold: Double { baseline + 0.15 }
    private var turnOffThreshold: Double { baseline + 0.08 }
    /// Periodic tick that flushes trailing letters from the demodulator
    /// when transitions stop arriving.
    private var tickTimer: Timer?

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
        session.startRunning()
        startTick()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        session.stopRunning()
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
        tickTimer?.invalidate()
        // 100 ms tick — fine enough to flush a letter promptly when the
        // signal goes quiet, coarse enough to not thrash the main thread.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.demod.tick(at: Date().timeIntervalSince1970 * 1000)
            }
        }
    }

    // MARK: - Brightness → transition (called from sampleQueue)

    nonisolated fileprivate func processFrame(luma: Double, timestampMs: Double) {
        // Adapt baseline downward slowly during dark frames — gives the
        // detector some room to recalibrate if the user drifts the camera.
        Task { @MainActor in
            self.currentLevel = luma
            self.updateBaseline(luma: luma)
            let wasOn = self.signalIsOn
            if !wasOn && luma >= self.turnOnThreshold {
                self.signalIsOn = true
                self.demod.signalDidGoOn(at: timestampMs)
            } else if wasOn && luma <= self.turnOffThreshold {
                self.signalIsOn = false
                self.demod.signalDidGoOff(at: timestampMs)
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
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension FlashlightDecoder: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                    didOutput sampleBuffer: CMSampleBuffer,
                                    from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let luma = Self.averageCenterLuma(pixelBuffer)
        let timestampMs = Date().timeIntervalSince1970 * 1000
        processFrame(luma: luma, timestampMs: timestampMs)
    }

    /// Pull the Y plane from a 420 YCbCr buffer and mean the brightness
    /// of the center 20% × 20% rectangle. That's roughly where the user
    /// pointed at the other phone's flashlight; sampling the whole frame
    /// would wash the signal into background.
    nonisolated static func averageCenterLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Center 20% crop.
        let cropW = width / 5
        let cropH = height / 5
        let startX = (width - cropW) / 2
        let startY = (height - cropH) / 2

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum: UInt64 = 0
        var count: UInt64 = 0
        // Step by 2 in both axes — cheap subsample, plenty of pixels
        // for a stable mean at 30 fps.
        var y = startY
        while y < startY + cropH {
            let rowStart = y * bytesPerRow
            var x = startX
            while x < startX + cropW {
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
