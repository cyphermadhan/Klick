@preconcurrency import AVFoundation
import os

/// Plays a `[MorseFrame]` schedule as sine-wave sidetone beeps.
///
/// Standalone `AVAudioEngine` — runs alongside the PTT pipeline's engine by
/// sharing the same `AVAudioSession`. We render each frame into its own PCM
/// buffer and hand them to an `AVAudioPlayerNode`, so cancellation is a
/// single `stop()` and the synth doesn't need to lock-step with a render
/// callback.
///
/// Timing follows PARIS-standard WPM: one unit = 1.2 / wpm seconds.
/// `MorseFrame` conventions from `MorseCode`:
///   - `.dit` pulse = 1 unit on, followed by 1 unit off (implicit intra-char gap)
///   - `.dah` pulse = 3 units on, followed by 1 unit off
///   - `.letterGap` = 2 additional units off (totals 3 with the trailing
///      intra-char unit from the preceding pulse)
///   - `.wordGap` = 6 additional units off (totals 7)
///
/// Tone is a 600 Hz sine (ham-radio CW sidetone standard) with a 5 ms
/// raised-cosine envelope at each end to kill click artefacts.
@MainActor
final class MorseTone: ObservableObject {
    /// Standard CW sidetone pitch.
    nonisolated static let defaultFrequency: Double = 600

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AudioFormats.pcm
    private let sampleRate = AudioFormats.sampleRate
    private let log = Logger(subsystem: "world.madhans.klick", category: "MorseTone")

    /// Raised-cosine ramp at the edges of each tone burst. 5 ms is short
    /// enough to be inaudible as a change in pitch/length but long enough
    /// to prevent the click that a hard square-wave envelope produces.
    private static let rampSeconds: Double = 0.005

    /// When a play call is in flight, the task that fires `completion` at
    /// the schedule's natural end. Cancelled by `stop()` and replaced on
    /// every new `play()`.
    private var completionTask: Task<Void, Never>?

    /// True while a schedule is either actively rendering or its completion
    /// task is still pending. UI can bind to this via `isPlaying` below.
    @Published private(set) var isPlaying = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Public API

    /// Play `frames` at `wpm` words per minute. If another schedule is
    /// playing it is stopped first. `completion` runs on the main actor
    /// when the schedule finishes naturally; it does NOT run if `stop()`
    /// is called, since callers that cancel are already driving their own
    /// follow-up.
    func play(
        _ frames: [MorseFrame],
        wpm: Int,
        frequency: Double = defaultFrequency,
        completion: (@MainActor () -> Void)? = nil
    ) {
        stop()
        guard !frames.isEmpty else {
            completion?()
            return
        }
        // 5 WPM is slow learner pace, 40 WPM is faster than most people
        // can copy — clamp rather than trust arbitrary callers.
        let clampedWpm = max(5, min(40, wpm))
        let unit = 1.2 / Double(clampedWpm)

        do {
            try startEngineIfNeeded()
        } catch {
            log.error("Engine start failed: \(String(describing: error))")
            completion?()
            return
        }

        let ditTone = makeTone(units: 1, unit: unit, frequency: frequency)
        let dahTone = makeTone(units: 3, unit: unit, frequency: frequency)
        let oneUnitSilence = makeSilence(units: 1, unit: unit)
        let twoUnitsSilence = makeSilence(units: 2, unit: unit)
        let sixUnitsSilence = makeSilence(units: 6, unit: unit)

        var totalSeconds: Double = 0
        for frame in frames {
            switch frame {
            case .dit:
                player.scheduleBuffer(ditTone, at: nil, options: [], completionHandler: nil)
                player.scheduleBuffer(oneUnitSilence, at: nil, options: [], completionHandler: nil)
                totalSeconds += unit * 2
            case .dah:
                player.scheduleBuffer(dahTone, at: nil, options: [], completionHandler: nil)
                player.scheduleBuffer(oneUnitSilence, at: nil, options: [], completionHandler: nil)
                totalSeconds += unit * 4
            case .letterGap:
                player.scheduleBuffer(twoUnitsSilence, at: nil, options: [], completionHandler: nil)
                totalSeconds += unit * 2
            case .wordGap:
                player.scheduleBuffer(sixUnitsSilence, at: nil, options: [], completionHandler: nil)
                totalSeconds += unit * 6
            }
        }

        player.play()
        isPlaying = true

        // Schedule-completion via wall clock is more reliable than
        // AVAudioPlayerNode's per-buffer completion handler, which fires
        // on both natural end and `stop()` — we only want the natural
        // case here.
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(totalSeconds))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isPlaying = false
            self.completionTask = nil
            completion?()
        }
    }

    /// Stop any in-flight schedule. Safe to call when nothing is playing.
    func stop() {
        completionTask?.cancel()
        completionTask = nil
        if player.isPlaying {
            player.stop()
        }
        isPlaying = false
    }

    // MARK: - Engine

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        try engine.start()
    }

    // MARK: - Buffer builders

    /// Build a sine-tone PCM buffer `units` dit-units long, with a short
    /// raised-cosine ramp at each edge.
    private func makeTone(units: Int, unit: Double, frequency: Double) -> AVAudioPCMBuffer {
        let totalSeconds = Double(units) * unit
        let frameCount = AVAudioFrameCount((totalSeconds * sampleRate).rounded())
        let buffer = makeBuffer(frameCount: frameCount)
        let samples = buffer.floatChannelData![0]

        let rampSamples = min(Int(Self.rampSeconds * sampleRate), Int(frameCount) / 2)
        let amplitude: Float = 0.25
        let twoPi = 2.0 * Double.pi

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope: Float
            if i < rampSamples {
                // Raised-cosine ramp-in: 0 → 1 over rampSamples.
                let x = Double(i) / Double(rampSamples)
                envelope = Float((1.0 - cos(Double.pi * x)) * 0.5)
            } else if i >= Int(frameCount) - rampSamples {
                // Mirror ramp-out.
                let x = Double(Int(frameCount) - 1 - i) / Double(rampSamples)
                envelope = Float((1.0 - cos(Double.pi * x)) * 0.5)
            } else {
                envelope = 1.0
            }
            samples[i] = amplitude * envelope * Float(sin(twoPi * frequency * t))
        }
        return buffer
    }

    /// Silent PCM buffer `units` dit-units long.
    private func makeSilence(units: Int, unit: Double) -> AVAudioPCMBuffer {
        let totalSeconds = Double(units) * unit
        let frameCount = AVAudioFrameCount((totalSeconds * sampleRate).rounded())
        let buffer = makeBuffer(frameCount: frameCount)
        // AVAudioPCMBuffer is not zero-initialised — we have to wipe it.
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            samples[i] = 0
        }
        return buffer
    }

    private func makeBuffer(frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            // Construction only fails if the format is invalid — which it isn't.
            fatalError("Failed to allocate MorseTone PCM buffer")
        }
        buffer.frameLength = frameCount
        return buffer
    }
}
