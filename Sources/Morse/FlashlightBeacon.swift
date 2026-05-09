@preconcurrency import AVFoundation
import os

/// Drives the rear-camera torch in time with a `[MorseFrame]` schedule so
/// the user can signal (or receive-by-flash) without audio — useful at a
/// concert, across a noisy room, or for silent TX.
///
/// Timing rules mirror `MorseTone`:
///   - `.dit` = 1 unit on, 1 unit off
///   - `.dah` = 3 units on, 1 unit off
///   - `.letterGap` = 2 units off
///   - `.wordGap` = 6 units off
///
/// We cap on/off switch rate at 15 Hz (iOS thermals + torch hardware don't
/// like faster). That means WPM > ~30 starts to silently merge pulses —
/// acceptable, since flash mode is a secondary signal anyway.
///
/// Gracefully no-ops on hardware without a torch (simulator, front-only
/// devices, or torch locked by another app).
@MainActor
final class FlashlightBeacon: ObservableObject {
    private let log = Logger(subsystem: "world.madhans.klick", category: "FlashlightBeacon")

    /// Hardware reference. Looked up lazily so constructing the beacon on
    /// a simulator doesn't crash on a missing device.
    private var device: AVCaptureDevice? {
        AVCaptureDevice.default(for: .video)
    }

    /// Active schedule task. Cancelled on `stop()` and replaced on each
    /// new `play()`.
    private var scheduleTask: Task<Void, Never>?

    /// Minimum gap between torch state changes. 15 Hz = 66 ms — faster than
    /// this risks driver drops and unnecessary heat.
    private static let minSwitchInterval: Duration = .milliseconds(66)

    /// Whether the device exposes a usable torch. Use to hide the FLASH
    /// toggle entirely on hardware that can't support it.
    var isAvailable: Bool {
        device?.hasTorch == true
    }

    /// Play `frames` at `wpm` words per minute. Stops any in-flight schedule.
    func play(_ frames: [MorseFrame], wpm: Int) {
        stop()
        guard !frames.isEmpty, let device, device.hasTorch else { return }
        let clampedWpm = max(5, min(40, wpm))
        let unit = 1.2 / Double(clampedWpm)

        scheduleTask = Task { @MainActor [weak self] in
            for frame in frames {
                if Task.isCancelled { break }
                await self?.runFrame(frame, unit: unit, device: device)
            }
            // Always end dark.
            self?.setTorch(on: false, device: device)
        }
    }

    /// Stop any in-flight schedule and turn the torch off.
    func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
        if let device, device.hasTorch {
            setTorch(on: false, device: device)
        }
    }

    // MARK: - Frame execution

    private func runFrame(_ frame: MorseFrame, unit: Double, device: AVCaptureDevice) async {
        switch frame {
        case .dit:
            setTorch(on: true, device: device)
            await sleep(unit)
            setTorch(on: false, device: device)
            await sleep(unit)
        case .dah:
            setTorch(on: true, device: device)
            await sleep(unit * 3)
            setTorch(on: false, device: device)
            await sleep(unit)
        case .letterGap:
            await sleep(unit * 2)
        case .wordGap:
            await sleep(unit * 6)
        }
    }

    /// Sleep `seconds`, respecting the 15 Hz cap. At ultra-fast WPMs the
    /// natural interval drops below 66 ms; we nudge up to the cap rather
    /// than letting the torch thrash.
    private func sleep(_ seconds: Double) async {
        let requested = Duration.milliseconds(Int((seconds * 1000).rounded()))
        let safe = max(requested, Self.minSwitchInterval)
        try? await Task.sleep(for: safe)
    }

    private func setTorch(on: Bool, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: 1.0)
            } else {
                device.torchMode = .off
            }
        } catch {
            log.error("Torch toggle failed: \(String(describing: error))")
        }
    }
}
